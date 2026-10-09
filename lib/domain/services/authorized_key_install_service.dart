/// Installs a saved public key in a remote `~/.ssh/authorized_keys` over an
/// open SSH session, then proves key-only login works before the host stops
/// using its saved password.
///
/// Nothing here logs key material, usernames, hostnames, or command text.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/known_hosts_repository.dart';
import 'diagnostics_log_service.dart';
import 'host_key_prompt_handler_provider.dart';
import 'remote_file_service.dart' show shellEscapePosix;
import 'ssh_exec_queue.dart';
import 'ssh_service.dart';

/// Marker printed by the install script so login banners cannot confuse the
/// result parser.
const authorizedKeyInstallMarker = 'MONKEYSSH_KEY_INSTALL';

const _installTimeout = Duration(seconds: 20);
const _verifyCommandTimeout = Duration(seconds: 15);

/// Printed by the fixed command run after a key-only login, to prove the key
/// opens a normal shell rather than a forced command.
const keyLoginVerifiedMarker = 'MONKEYSSH_KEY_LOGIN_OK';

/// Most jump hosts followed when comparing a session with a saved host;
/// matches what a connection follows.
const _maxSavedJumpChain = 8;

const _supportedKeyTypes = <String>{
  'ssh-ed25519',
  'ssh-rsa',
  'ssh-dss',
  'ecdsa-sha2-nistp256',
  'ecdsa-sha2-nistp384',
  'ecdsa-sha2-nistp521',
  'sk-ssh-ed25519@openssh.com',
  'sk-ecdsa-sha2-nistp256@openssh.com',
};

final _base64Pattern = RegExp(r'^[A-Za-z0-9+/]+={0,2}$');
final _commentUnsafe = RegExp('[^A-Za-z0-9._@+-]+');
final _edgeDashes = RegExp(r'^-+|-+$');

/// Builds the single `authorized_keys` line for [publicKey].
///
/// The stored public key is `type base64`. The type must be a known OpenSSH
/// key type that matches the algorithm inside the blob, and [comment] is
/// reduced to `[A-Za-z0-9._@+-]` so the line can never carry shell syntax or
/// a second line. Throws [FormatException] for anything else.
String buildAuthorizedKeyLine(String publicKey, {String? comment}) {
  final parts = publicKey.trim().split(RegExp(r'\s+'));
  if (parts.length < 2) {
    throw const FormatException('Not an OpenSSH public key');
  }
  final type = parts[0];
  final blob = parts[1];
  if (!_supportedKeyTypes.contains(type)) {
    throw const FormatException('Unsupported key type');
  }
  if (!_base64Pattern.hasMatch(blob)) {
    throw const FormatException('Public key is not base64');
  }
  final List<int> bytes;
  try {
    bytes = base64Decode(blob);
  } on FormatException {
    throw const FormatException('Public key is not base64');
  }
  if (bytes.length < 4) {
    throw const FormatException('Public key is too short');
  }
  final length =
      (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
  if (length <= 0 ||
      4 + length > bytes.length ||
      ascii.decode(bytes.sublist(4, 4 + length), allowInvalid: true) != type) {
    throw const FormatException('Public key type does not match its data');
  }
  final safeComment = (comment ?? '')
      .replaceAll(_commentUnsafe, '-')
      .replaceAll(_edgeDashes, '');
  final trimmedComment = safeComment.length > 64
      ? safeComment.substring(0, 64)
      : safeComment;
  return trimmedComment.isEmpty
      ? '$type $blob monkeyssh'
      : '$type $blob $trimmedComment';
}

/// The only command line sent to the server for an install.
///
/// sshd hands the exec command to the account's login shell, which may be
/// fish or csh and would misread POSIX quoting. So the command line is this
/// fixed string with no user-controlled bytes, and the script (including the
/// key) goes to `/bin/sh` on the channel's stdin.
const authorizedKeyInstallCommand = 'exec /bin/sh -s';

/// The POSIX script body that appends the key line held in `$key`.
///
/// It only appends: an existing file is never rewritten. `~/.ssh` is created
/// with mode 700 and a new `authorized_keys` with 600 (umask 077); existing
/// group or world write bits are removed, which `sshd` StrictModes requires.
/// A plain line for the same key (type then blob, whatever the comment) is
/// left alone. A copy behind options (`command=`, `from=`, `restrict`,
/// `cert-authority` ...) is reported as `restricted` instead, because sshd
/// would apply those options to MonkeySSH's logins. Comment lines are
/// ignored. No command in it reads stdin, so `sh -s` keeps reading the
/// script.
const authorizedKeyInstallScriptBody =
    'm=$authorizedKeyInstallMarker\n'
    r"""
if [ -z "$HOME" ] || [ ! -d "$HOME" ]; then echo "$m=no_home"; exit 0; fi
umask 077
d="$HOME/.ssh"
f="$d/authorized_keys"
if [ ! -d "$d" ]; then
  mkdir -p "$d" && chmod 700 "$d" || { echo "$m=mkdir_failed"; exit 0; }
fi
t=${key%% *}
b=${key#* }
b=${b%% *}
st=absent
if [ -f "$f" ]; then
  st=$(awk -v t="$t" -v b="$b" '
    /^[[:space:]]*#/ { next }
    {
      for (i = 1; i <= NF; i++) {
        if ($i != b) continue
        if (i == 2 && $1 == t) u = 1; else r = 1
      }
    }
    END { if (r) print "restricted"; else if (u) print "present"; else print "absent" }
  ' "$f") || { echo "$m=read_failed"; exit 0; }
fi
case "$st" in
  present) s=present ;;
  restricted) echo "$m=restricted"; exit 0 ;;
  *)
    if [ -s "$f" ] && [ -n "$(tail -c 1 "$f")" ]; then
      echo >> "$f" || { echo "$m=write_failed"; exit 0; }
    fi
    printf '%s\n' "$key" >> "$f" || { echo "$m=write_failed"; exit 0; }
    s=added
    ;;
esac
chmod go-w "$d" "$f" 2>/dev/null
if command -v restorecon >/dev/null 2>&1; then
  restorecon -F "$d" "$f" >/dev/null 2>&1
fi
echo "$m=$s"
exit 0
""";

/// The full script written to stdin for [keyLine].
///
/// Only `/bin/sh` parses it, so POSIX single quoting of the key is reliable.
/// [keyLine] must come from [buildAuthorizedKeyLine].
String buildAuthorizedKeyInstallScript(String keyLine) =>
    'key=${shellEscapePosix(keyLine)}\n$authorizedKeyInstallScriptBody';

/// A short command a person can paste into a terminal on the server to
/// authorize [keyLine] by hand.
///
/// It sticks to `&&`, `||`, `~`, single quotes and `printf` so bash, zsh,
/// fish and csh all run it. It appends only when no line starts with the key
/// type and blob (comment lines start with `#`, so they don't count), and the
/// leading newline keeps the key off a last line that lacks one.
/// [keyLine] must come from [buildAuthorizedKeyLine].
String buildManualAuthorizedKeyCommand(String keyLine) {
  final parts = keyLine.split(' ');
  return 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && '
      'touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && '
      "grep -q '^${parts[0]} ${parts[1]}' ~/.ssh/authorized_keys || "
      "printf '\\n%s\\n' '$keyLine' >> ~/.ssh/authorized_keys";
}

/// What happened to `authorized_keys`.
enum AuthorizedKeyInstallOutcome {
  /// The key line was appended.
  added,

  /// The key was already authorized; nothing was written.
  alreadyPresent,

  /// The key is listed only behind options such as `command=`, `from=`,
  /// `restrict` or `cert-authority`, so it isn't a plain login key.
  restrictedCopy,

  /// `$HOME` is unset or missing on the server.
  noHomeDirectory,

  /// `~/.ssh` could not be created.
  directoryNotWritable,

  /// `authorized_keys` could not be appended to.
  fileNotWritable,

  /// The host is Windows; its authorized keys live elsewhere.
  unsupportedPlatform,

  /// The script did not report a result (for example a restricted shell).
  unexpectedOutput,
}

/// Parses the marker line printed by [authorizedKeyInstallScriptBody].
AuthorizedKeyInstallOutcome parseAuthorizedKeyInstallOutput(String output) {
  final match = RegExp(
    '^$authorizedKeyInstallMarker=([a-z_]+)\\s*\$',
    multiLine: true,
  ).allMatches(output).lastOrNull;
  return switch (match?.group(1)) {
    'added' => AuthorizedKeyInstallOutcome.added,
    'present' => AuthorizedKeyInstallOutcome.alreadyPresent,
    'restricted' => AuthorizedKeyInstallOutcome.restrictedCopy,
    'no_home' => AuthorizedKeyInstallOutcome.noHomeDirectory,
    'mkdir_failed' => AuthorizedKeyInstallOutcome.directoryNotWritable,
    'write_failed' ||
    'read_failed' => AuthorizedKeyInstallOutcome.fileNotWritable,
    _ => AuthorizedKeyInstallOutcome.unexpectedOutput,
  };
}

/// User-facing text for an install outcome.
String describeAuthorizedKeyInstallOutcome(
  AuthorizedKeyInstallOutcome outcome,
) => switch (outcome) {
  AuthorizedKeyInstallOutcome.added => 'Key added to ~/.ssh/authorized_keys.',
  AuthorizedKeyInstallOutcome.alreadyPresent =>
    'The key was already in ~/.ssh/authorized_keys.',
  AuthorizedKeyInstallOutcome.restrictedCopy =>
    'This key is already in ~/.ssh/authorized_keys with restrictions (such '
        'as command=, from= or restrict), so it can’t be used for a normal '
        'login. Generate a new key for MonkeySSH instead.',
  AuthorizedKeyInstallOutcome.noHomeDirectory =>
    'The server account has no home directory to hold authorized_keys.',
  AuthorizedKeyInstallOutcome.directoryNotWritable =>
    'Couldn’t create ~/.ssh on the server.',
  AuthorizedKeyInstallOutcome.fileNotWritable =>
    'Couldn’t write ~/.ssh/authorized_keys on the server.',
  AuthorizedKeyInstallOutcome.unsupportedPlatform =>
    'Windows servers keep authorized keys elsewhere. Copy the public key '
        'and add it there by hand.',
  AuthorizedKeyInstallOutcome.unexpectedOutput =>
    'The server didn’t run the install script. Its login shell may be '
        'restricted.',
};

/// Whether [outcome] means the key is now authorized.
bool authorizedKeyInstallSucceeded(AuthorizedKeyInstallOutcome outcome) =>
    outcome == AuthorizedKeyInstallOutcome.added ||
    outcome == AuthorizedKeyInstallOutcome.alreadyPresent;

/// Result of reconnecting with only the key.
class KeyLoginVerification {
  /// Creates a verification result.
  const KeyLoginVerification({required this.success, this.error});

  /// Whether the server accepted the key with no password.
  final bool success;

  /// User-facing failure text.
  final String? error;
}

/// Opens a connection for verification. Must not prompt for passwords.
typedef KeyLoginConnector = Future<SshConnectionResult> Function(
  SshConnectionConfig config,
);

/// Moves a host from password login to key login.
class AuthorizedKeyInstallService {
  /// Creates the service.
  AuthorizedKeyInstallService({
    required HostRepository hostRepository,
    required KeyLoginConnector connectKeyOnly,
    DiagnosticsLogger? diagnostics,
  }) : _hostRepository = hostRepository,
       _connectKeyOnly = connectKeyOnly,
       _diagnostics = diagnostics ?? DiagnosticsLogService.instance;

  final HostRepository _hostRepository;
  final KeyLoginConnector _connectKeyOnly;
  final DiagnosticsLogger _diagnostics;

  /// Appends [key]'s public key to `~/.ssh/authorized_keys` over [session].
  Future<AuthorizedKeyInstallOutcome> installKey(
    SshSession session,
    SshKey key,
  ) async {
    if (session.remoteIsWindows) {
      _logOutcome(session, AuthorizedKeyInstallOutcome.unsupportedPlatform);
      return AuthorizedKeyInstallOutcome.unsupportedPlatform;
    }
    final script = buildAuthorizedKeyInstallScript(
      buildAuthorizedKeyLine(key.publicKey, comment: key.name),
    );
    final output = await session.runQueuedExec(() async {
      final exec = await openSshExec(
        session.execute(authorizedKeyInstallCommand),
        _installTimeout,
      );
      var finished = false;
      try {
        final stdout = StringBuffer();
        final reading = Future.wait<void>([
          exec.stdout
              .cast<List<int>>()
              .transform(utf8.decoder)
              .forEach(stdout.write),
          exec.stderr.drain<void>(),
        ]);
        exec.stdin.add(Uint8List.fromList(utf8.encode(script)));
        await Future.wait<void>([reading, exec.stdin.close(), exec.done])
            .timeout(_installTimeout);
        finished = true;
        return stdout.toString();
      } finally {
        if (finished) {
          exec.close();
        } else {
          await closeAbandonedSshExec(exec);
        }
      }
    });
    final outcome = parseAuthorizedKeyInstallOutput(output);
    _logOutcome(session, outcome);
    return outcome;
  }

  void _logOutcome(SshSession session, AuthorizedKeyInstallOutcome outcome) =>
      _diagnostics.info(
        'onboarding.key',
        'install_finished',
        fields: {
          'hostId': session.hostId,
          'connectionId': session.connectionId,
          'outcome': outcome.name,
        },
      );

  /// The `user@host:port` endpoints a connection to [host] dials, target
  /// first, following saved jump hosts the way a connection does. Returns
  /// null when the chain is longer than a connection follows.
  Future<List<String>?> savedEndpointChain(Host host) async {
    final chain = [_endpoint(host.username, host.hostname, host.port)];
    final visited = {host.id};
    for (var jumpId = host.jumpHostId; jumpId != null;) {
      if (visited.contains(jumpId)) {
        // A saved loop connects through the first jump host only.
        return chain.take(2).toList();
      }
      if (visited.length > _maxSavedJumpChain) return null;
      final jump = await _hostRepository.getById(jumpId);
      if (jump == null) break;
      chain.add(_endpoint(jump.username, jump.hostname, jump.port));
      visited.add(jumpId);
      jumpId = jump.jumpHostId;
    }
    return chain;
  }

  /// Whether [session] is connected to the account [host] is saved with now,
  /// through the same jump hosts. A host edited since the session opened
  /// doesn't match, so the key is never installed into another account.
  Future<bool> sessionMatchesSavedHost(SshSession session, Host host) async {
    final saved = await savedEndpointChain(host);
    if (saved == null) return false;
    final live = <String>[];
    SshConnectionConfig? config = session.config;
    while (config != null) {
      live.add(_endpoint(config.username, config.hostname, config.port));
      config = config.jumpHost;
    }
    return listEquals(saved, live);
  }

  /// The first of [sessions] that [sessionMatchesSavedHost] accepts for
  /// [savedHost], or null when the flow must open a fresh connection.
  Future<SshSession?> reusableSessionFor(
    Host savedHost,
    Iterable<SshSession> sessions,
  ) async {
    for (final session in sessions) {
      if (await sessionMatchesSavedHost(session, savedHost)) return session;
    }
    return null;
  }

  static String _endpoint(String username, String hostname, int port) =>
      '$username@${hostname.toLowerCase()}:$port';

  /// Opens a new connection to [savedHost] as it is saved now, with only
  /// [key] and no password, through [session]'s jump hosts. The login must
  /// also run a fixed `echo` and print [keyLoginVerifiedMarker], which a key
  /// limited by `command=` or `restrict` can't do.
  Future<KeyLoginVerification> verifyKeyOnlyLogin(
    SshSession session,
    SshKey key, {
    required Host savedHost,
  }) async {
    final base = session.config;
    final config = SshConnectionConfig(
      hostname: savedHost.hostname,
      port: savedHost.port,
      username: savedHost.username,
      privateKey: key.privateKey,
      passphrase: key.passphrase,
      jumpHost: base.jumpHost,
      keepAliveInterval: base.keepAliveInterval,
      connectionTimeout: base.connectionTimeout,
    );
    SshConnectionResult result;
    try {
      result = await _connectKeyOnly(config);
    } on Exception catch (error) {
      _diagnostics.warning(
        'onboarding.key',
        'verify_failed',
        fields: {'hostId': session.hostId, 'errorType': error.runtimeType},
      );
      return const KeyLoginVerification(
        success: false,
        error: 'The key-only connection failed to start.',
      );
    }
    final client = result.client;
    final authenticated = result.success && client != null;
    var shellWorks = false;
    if (authenticated) {
      try {
        final output = await client
            .run('echo $keyLoginVerifiedMarker', stderr: false)
            .timeout(_verifyCommandTimeout);
        shellWorks = const LineSplitter()
            .convert(utf8.decode(output, allowMalformed: true))
            .any((line) => line.trim() == keyLoginVerifiedMarker);
      } on Object catch (error) {
        _diagnostics.debug(
          'onboarding.key',
          'verify_command_failed',
          fields: {'errorType': error.runtimeType},
        );
      }
    }
    try {
      await result.closeAll();
    } on Object catch (error) {
      _diagnostics.debug(
        'onboarding.key',
        'verify_close_failed',
        fields: {'errorType': error.runtimeType},
      );
    }
    final success = authenticated && shellWorks;
    _diagnostics.info(
      'onboarding.key',
      'verify_finished',
      fields: {
        'hostId': session.hostId,
        'authenticated': authenticated,
        'success': success,
        'usesJumpHost': base.jumpHost != null,
      },
    );
    if (success) return const KeyLoginVerification(success: true);
    if (authenticated) {
      return const KeyLoginVerification(
        success: false,
        error:
            'The server accepted the key but didn’t give it a normal shell. '
            'A forced command or other restriction may apply to it.',
      );
    }
    return KeyLoginVerification(
      success: false,
      error: result.error ?? 'Key login failed.',
    );
  }

  /// Points [hostId] at [keyId] and, when [removePassword] is set, deletes
  /// its saved password.
  Future<void> switchHostToKey(
    int hostId,
    int keyId, {
    required bool removePassword,
  }) async {
    await _hostRepository.updateFields(
      hostId,
      HostsCompanion(keyId: Value(keyId), updatedAt: Value(DateTime.now())),
    );
    if (removePassword) {
      final host = await _hostRepository.getById(hostId);
      if (host != null && host.password != null) {
        await _hostRepository.update(
          host.copyWith(password: const Value(null)),
        );
      }
    }
    _diagnostics.info(
      'onboarding.key',
      'host_switched',
      fields: {'hostId': hostId, 'passwordRemoved': removePassword},
    );
  }
}

/// The [SshService] used for key-only verification.
///
/// It is built without an interactive password handler, so when the server
/// rejects the key the connection fails instead of asking for (and
/// succeeding with) the password.
final keyOnlyVerifierSshServiceProvider = Provider<SshService>(
  (ref) => SshService(
    knownHostsRepository: ref.watch(knownHostsRepositoryProvider),
    hostKeyPromptHandler: ref.watch(hostKeyPromptHandlerProvider),
  ),
);

/// Provider for [AuthorizedKeyInstallService].
final authorizedKeyInstallServiceProvider =
    Provider<AuthorizedKeyInstallService>(
      (ref) => AuthorizedKeyInstallService(
        hostRepository: ref.watch(hostRepositoryProvider),
        connectKeyOnly: ref.watch(keyOnlyVerifierSshServiceProvider).connect,
      ),
    );

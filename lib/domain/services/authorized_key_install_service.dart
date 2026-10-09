/// Installs a saved public key in a remote `~/.ssh/authorized_keys` over an
/// open SSH session, then proves key-only login works before the host stops
/// using its saved password.
///
/// Nothing here logs key material, usernames, hostnames, or command text.
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
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

/// The POSIX script that appends one key line passed as `$1`.
///
/// It is one line with no single quotes or backslashes, so it survives
/// whichever login shell (sh, bash, zsh, fish, csh) passes it to `/bin/sh`.
/// It only appends: an existing file is never rewritten. `~/.ssh` is created
/// with mode 700 and a new `authorized_keys` with 600 (umask 077); existing
/// group or world write bits are removed, which `sshd` StrictModes requires.
/// A line already holding the same key blob (ignoring comments) is left
/// alone.
const authorizedKeyInstallScript =
    r'key="$1"; '
    'm=$authorizedKeyInstallMarker; '
    r'if [ -z "$HOME" ] || [ ! -d "$HOME" ]; then echo "$m=no_home"; '
    'exit 0; fi; '
    r'umask 077; d="$HOME/.ssh"; f="$d/authorized_keys"; '
    r'if [ ! -d "$d" ]; then mkdir -p "$d" && chmod 700 "$d" || '
    r'{ echo "$m=mkdir_failed"; exit 0; }; fi; '
    r'b=${key#* }; b=${b%% *}; '
    r'if [ -f "$f" ] && grep -v "^[[:space:]]*#" "$f" | grep -F -q -e "$b"; '
    'then s=present; else '
    r'if [ -s "$f" ] && [ -n "$(tail -c 1 "$f")" ]; then '
    r'echo >> "$f" || { echo "$m=write_failed"; exit 0; }; fi; '
    r'echo "$key" >> "$f" || { echo "$m=write_failed"; exit 0; }; '
    's=added; fi; '
    r'chmod go-w "$d" "$f" 2>/dev/null; '
    'if command -v restorecon >/dev/null 2>&1; then '
    r'restorecon -F "$d" "$f" >/dev/null 2>&1; fi; '
    r'echo "$m=$s"';

/// The exec command that runs [authorizedKeyInstallScript] for [keyLine].
///
/// [keyLine] must come from [buildAuthorizedKeyLine]; it is still quoted.
String buildAuthorizedKeyInstallCommand(String keyLine) =>
    '/bin/sh -c ${shellEscapePosix(authorizedKeyInstallScript)} '
    'monkeyssh-key-install ${shellEscapePosix(keyLine)}';

/// What happened to `authorized_keys`.
enum AuthorizedKeyInstallOutcome {
  /// The key line was appended.
  added,

  /// The key was already authorized; nothing was written.
  alreadyPresent,

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

/// Parses the marker line printed by [authorizedKeyInstallScript].
AuthorizedKeyInstallOutcome parseAuthorizedKeyInstallOutput(String output) {
  final match = RegExp(
    '^$authorizedKeyInstallMarker=([a-z_]+)\\s*\$',
    multiLine: true,
  ).allMatches(output).lastOrNull;
  return switch (match?.group(1)) {
    'added' => AuthorizedKeyInstallOutcome.added,
    'present' => AuthorizedKeyInstallOutcome.alreadyPresent,
    'no_home' => AuthorizedKeyInstallOutcome.noHomeDirectory,
    'mkdir_failed' => AuthorizedKeyInstallOutcome.directoryNotWritable,
    'write_failed' => AuthorizedKeyInstallOutcome.fileNotWritable,
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
    final command = buildAuthorizedKeyInstallCommand(
      buildAuthorizedKeyLine(key.publicKey, comment: key.name),
    );
    final output = await session.runQueuedExec(() async {
      final exec = await openSshExec(session.execute(command), _installTimeout);
      var finished = false;
      try {
        final stdout = StringBuffer();
        await Future.wait<void>([
          exec.stdout
              .cast<List<int>>()
              .transform(utf8.decoder)
              .forEach(stdout.write),
          exec.stderr.drain<void>(),
          exec.done,
        ]).timeout(_installTimeout);
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

  /// Opens a new connection to the same endpoint with only [key] and no
  /// password, then closes it.
  Future<KeyLoginVerification> verifyKeyOnlyLogin(
    SshSession session,
    SshKey key,
  ) async {
    final base = session.config;
    final config = SshConnectionConfig(
      hostname: base.hostname,
      port: base.port,
      username: base.username,
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
    final success = result.success && result.client != null;
    try {
      await result.closeAll();
    } on Object catch (error) {
      _diagnostics.debug(
        'onboarding.key',
        'verify_close_failed',
        fields: {'errorType': error.runtimeType},
      );
    }
    _diagnostics.info(
      'onboarding.key',
      'verify_finished',
      fields: {
        'hostId': session.hostId,
        'success': success,
        'usesJumpHost': base.jumpHost != null,
      },
    );
    return KeyLoginVerification(
      success: success,
      error: success ? null : result.error ?? 'Key login failed.',
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

/// Provider for [AuthorizedKeyInstallService].
///
/// Verification uses its own [SshService] with no interactive password
/// handler, so a rejected key fails instead of asking for the password.
final authorizedKeyInstallServiceProvider =
    Provider<AuthorizedKeyInstallService>((ref) {
      final verifier = SshService(
        knownHostsRepository: ref.watch(knownHostsRepositoryProvider),
        hostKeyPromptHandler: ref.watch(hostKeyPromptHandlerProvider),
      );
      return AuthorizedKeyInstallService(
        hostRepository: ref.watch(hostRepositoryProvider),
        connectKeyOnly: verifier.connect,
      );
    });

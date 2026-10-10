import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart' as pc;

import '../../data/database/database.dart';
import 'diagnostics_log_service.dart';
import 'ssh_wire.dart';

/// One key the forwarded agent offers to a host.
///
/// The signer is an [SSHIdentity], so an in-memory [SSHKeyPair] and an
/// asynchronous signer (for example a hardware-backed key) plug in the same
/// way.
class SshAgentKey {
  /// Creates an [SshAgentKey].
  SshAgentKey({required this.label, required this.identity});

  /// The app's name for the key. Shown in the confirmation prompt and sent as
  /// the identity comment; never logged.
  final String label;

  /// Signs on the agent's behalf.
  final SSHIdentity identity;

  /// SSH wire-format public key, as sent in the identities answer.
  late final Uint8List publicKeyBlob = identity.toPublicKey().encode();

  /// The key's wire type, such as `ssh-ed25519` or `ssh-rsa`.
  late final String? keyType = readSshHostKeyType(publicKeyBlob);
}

/// What a forwarded agent may do at the moment.
///
/// Read again for every request (see [SshAgentForwarding.policyLifetime]), so
/// turning forwarding off, turning confirmation on, or changing the keys
/// applies to connections that are already open.
@immutable
class SshAgentForwardingPolicy {
  /// Creates an [SshAgentForwardingPolicy].
  const SshAgentForwardingPolicy({
    required this.enabled,
    this.confirmEachSignature = false,
    this.keys = const [],
  });

  /// Forwarding is off: every request is refused.
  static const off = SshAgentForwardingPolicy(enabled: false);

  /// Whether the host may use the agent at all.
  final bool enabled;

  /// Whether each signature needs the user's approval first.
  final bool confirmEachSignature;

  /// The keys the host may list and use, in the order they are offered.
  final List<SshAgentKey> keys;
}

/// Loads the current [SshAgentForwardingPolicy] for a connection.
typedef SshAgentPolicyLoader = Future<SshAgentForwardingPolicy> Function();

/// A signature the host asked for while confirm-per-signature is on.
@immutable
class SshAgentSignatureRequest {
  /// Creates an [SshAgentSignatureRequest].
  const SshAgentSignatureRequest({
    required this.hostLabel,
    required this.keyLabel,
    required this.username,
    required this.connectionClosed,
    required this.isConnectionClosed,
  });

  /// The app's label for the host the request came through.
  final String hostLabel;

  /// The app's name for the key being asked for.
  final String keyLabel;

  /// The user name the signature would sign in as, read from the signed data.
  final String username;

  /// Completes when the connection that asked closes.
  final Future<void> connectionClosed;

  /// Whether [connectionClosed] has already completed.
  final bool Function() isConnectionClosed;
}

/// How a confirmation request ended.
enum SshAgentSignatureDecision {
  /// The user allowed the signature.
  approved,

  /// The user refused, dismissed, or let the prompt time out.
  declined,

  /// The user refused and turned forwarding off for the host.
  stopForwarding,

  /// No prompt could be shown: the app was in the background or locked, no
  /// prompt UI was available, or the connection closed first.
  unavailable,
}

/// Asks the user whether to allow one signature.
typedef SshAgentSignatureConfirmer = Future<SshAgentSignatureDecision> Function(
  SshAgentSignatureRequest,
);

/// What the terminal shows about a forwarding connection.
@immutable
class SshAgentForwardingStatus {
  /// Creates an [SshAgentForwardingStatus].
  const SshAgentForwardingStatus({
    required this.serving,
    required this.confirmEachSignature,
    this.signatureCount = 0,
    this.stoppedByUser = false,
  });

  /// Whether the host can currently use the agent.
  final bool serving;

  /// Whether each signature asks first.
  final bool confirmEachSignature;

  /// Signatures made on this connection.
  final int signatureCount;

  /// Whether the user stopped forwarding on this connection from a prompt.
  final bool stoppedByUser;

  /// Returns a copy with the given fields replaced.
  SshAgentForwardingStatus copyWith({
    bool? serving,
    bool? confirmEachSignature,
    int? signatureCount,
    bool? stoppedByUser,
  }) => SshAgentForwardingStatus(
    serving: serving ?? this.serving,
    confirmEachSignature: confirmEachSignature ?? this.confirmEachSignature,
    signatureCount: signatureCount ?? this.signatureCount,
    stoppedByUser: stoppedByUser ?? this.stoppedByUser,
  );

  @override
  bool operator ==(Object other) =>
      other is SshAgentForwardingStatus &&
      other.serving == serving &&
      other.confirmEachSignature == confirmEachSignature &&
      other.signatureCount == signatureCount &&
      other.stoppedByUser == stoppedByUser;

  @override
  int get hashCode =>
      Object.hash(serving, confirmEachSignature, signatureCount, stoppedByUser);
}

/// Creates an [SSHClient] that serves [agentHandler] for agent forwarding.
typedef SshAgentForwardingClientFactory = SSHClient Function(
  SSHSocket socket, {
  required String username,
  required SSHAgentHandler agentHandler,
  SSHHostkeyVerifyHandler? onVerifyHostKey,
  SSHPasswordRequestHandler? onPasswordRequest,
  SSHUserInfoRequestHandler? onUserInfoRequest,
  List<SSHKeyPair>? identities,
  Duration? keepAliveInterval,
});

/// Builds the agent forwarding handler for [host], or returns null to leave
/// forwarding off.
typedef SshAgentForwardingResolver = Future<SshAgentForwarding?> Function(
  Host host,
);

/// Default [SshAgentForwardingClientFactory].
///
/// The vendored dartssh2 sends the agent request without waiting for a reply,
/// as `ssh(1)` does, because OpenSSH's sshd refuses every agent request after
/// the first on a connection while still giving later sessions
/// `SSH_AUTH_SOCK`.
SSHClient createAgentForwardingSshClient(
  SSHSocket socket, {
  required String username,
  required SSHAgentHandler agentHandler,
  SSHHostkeyVerifyHandler? onVerifyHostKey,
  SSHPasswordRequestHandler? onPasswordRequest,
  SSHUserInfoRequestHandler? onUserInfoRequest,
  List<SSHKeyPair>? identities,
  Duration? keepAliveInterval,
}) => SSHClient(
  socket,
  username: username,
  onVerifyHostKey: onVerifyHostKey,
  onPasswordRequest: onPasswordRequest,
  onUserInfoRequest: onUserInfoRequest,
  identities: identities,
  keepAliveInterval: keepAliveInterval,
  agentHandler: agentHandler,
);

/// Serves the app's keys to one host connection over SSH agent forwarding.
///
/// Implements the subset of the SSH agent protocol a remote `ssh` or `git`
/// needs: listing identities and signing. Everything else, including adding,
/// removing and locking keys and every extension, is refused. Only SSH
/// user-authentication requests are signed, so a host cannot use the agent to
/// sign arbitrary data such as commits.
///
/// With confirmation on, a connection has at most one prompt open; requests
/// that arrive meanwhile, and for [declineCooldown] after a refusal, are
/// refused without asking, so a host cannot bury the user in prompts.
///
/// Every signature is checked against the newest settings right before it is
/// made and again before it is sent, so a change saved while a request waits
/// on a prompt or on the settings themselves applies to that request too. At
/// most [signatureBurst] signatures are made at once and
/// [signaturesPerSecond] after that, so a host cannot keep the app busy
/// signing.
class SshAgentForwarding implements SSHAgentHandler {
  /// Creates an [SshAgentForwarding].
  SshAgentForwarding({
    required this.hostId,
    required this.hostLabel,
    required SshAgentPolicyLoader loadPolicy,
    bool initiallyConfirmEachSignature = false,
    Stream<void>? policyChanges,
    SshAgentSignatureConfirmer? confirm,
    DiagnosticsLogger? diagnostics,
    this.policyLifetime = const Duration(seconds: 2),
    this.declineCooldown = const Duration(seconds: 10),
    this.signatureBurst = 20,
    this.signaturesPerSecond = 10,
    void Function()? onStop,
    DateTime Function() clock = DateTime.now,
  }) : _loadPolicy = loadPolicy,
       _policyChanges = policyChanges,
       _confirm = confirm,
       _onStop = onStop,
       _signatureTokens = signatureBurst.toDouble(),
       _diagnostics = diagnostics ?? DiagnosticsLogService.instance,
       _clock = clock,
       _status = ValueNotifier(
         SshAgentForwardingStatus(
           serving: true,
           confirmEachSignature: initiallyConfirmEachSignature,
         ),
       );

  static const _userauthRequestMessage = 50;
  static const _connectionService = 'ssh-connection';
  static const _publicKeyMethods = {
    'publickey',
    'publickey-hostbound-v00@openssh.com',
  };
  static const _hostboundMethod = 'publickey-hostbound-v00@openssh.com';
  static const _rsaSha1 = 'ssh-rsa';
  static const _rsaSha256 = 'rsa-sha2-256';
  static const _rsaSha512 = 'rsa-sha2-512';

  // A host can send requests as fast as it likes; only this many per
  // connection reach the diagnostics log, so a flood cannot wash it out.
  static const _maxLoggedRequests = 32;

  /// The host this forwarding serves.
  final int hostId;

  /// The app's label for the host, shown in confirmation prompts.
  final String hostLabel;

  /// How long a loaded policy is reused before it is read again.
  final Duration policyLifetime;

  /// How long requests are refused without asking after a refused prompt.
  final Duration declineCooldown;

  /// Signatures that can be made back to back on this connection.
  final int signatureBurst;

  /// Signatures per second on this connection once the burst is used up.
  final int signaturesPerSecond;

  final SshAgentPolicyLoader _loadPolicy;
  final void Function()? _onStop;
  final Stream<void>? _policyChanges;
  final SshAgentSignatureConfirmer? _confirm;
  final DiagnosticsLogger _diagnostics;
  final DateTime Function() _clock;
  final ValueNotifier<SshAgentForwardingStatus> _status;
  Future<SshAgentForwardingPolicy>? _policy;
  DateTime? _policyLoadedAt;
  Completer<void> _connectionClosed = Completer<void>();
  StreamSubscription<void>? _policySubscription;
  bool _stopped = false;
  bool _promptOpen = false;
  DateTime? _refuseUntil;
  int _loggedRequests = 0;
  int _policyGeneration = 0;
  double _signatureTokens;
  DateTime? _signatureTokensAt;

  /// What the terminal shows for this connection; updated as requests arrive
  /// and when the host's settings change.
  ValueListenable<SshAgentForwardingStatus> get status => _status;

  /// Whether each signature needs the user's approval, as last read.
  bool get confirmEachSignature => _status.value.confirmEachSignature;

  /// Ties forwarding to [client]: pending prompts end when it closes, and the
  /// host's settings are followed while it is open.
  ///
  /// A connection attempt can create more than one client, for example after
  /// a changed host key; the latest one wins.
  void attachClient(SSHClient client) {
    final closed = Completer<void>();
    _connectionClosed = closed;
    unawaited(_policySubscription?.cancel());
    _policySubscription = _policyChanges?.listen((_) => refreshPolicy());
    unawaited(
      client.done
          .then<void>((_) {}, onError: (Object _, StackTrace _) {})
          .whenComplete(() {
            if (!closed.isCompleted) {
              closed.complete();
            }
            if (identical(closed, _connectionClosed)) {
              unawaited(_policySubscription?.cancel());
              _policySubscription = null;
              _status.value = _status.value.copyWith(serving: false);
            }
          }),
    );
  }

  /// Reads the host's settings again now, for example after they changed.
  void refreshPolicy() {
    _policy = null;
    unawaited(_currentPolicy());
  }

  /// Refuses every further request on this connection, and reports it so the
  /// stop can outlast the connection.
  void stop() {
    if (_stopped) {
      return;
    }
    _stopped = true;
    _status.value = _status.value.copyWith(serving: false, stoppedByUser: true);
    _onStop?.call();
  }

  @override
  Future<Uint8List> handleRequest(Uint8List request) async {
    if (request.isEmpty || _stopped || _connectionClosed.isCompleted) {
      return _failure();
    }
    final messageType = request[0];
    final body = Uint8List.sublistView(request, 1);
    switch (messageType) {
      case SSHAgentProtocol.requestIdentities:
        return _answerIdentities();
      case SSHAgentProtocol.signRequest:
        return _answerSignRequest(body);
      default:
        _log('request_refused', {'messageType': messageType});
        return _failure();
    }
  }

  Future<SshAgentForwardingPolicy> _currentPolicy() {
    final loadedAt = _policyLoadedAt;
    final cached = _policy;
    if (cached != null &&
        loadedAt != null &&
        _clock().difference(loadedAt) < policyLifetime) {
      return cached;
    }
    _policyLoadedAt = _clock();
    _policyGeneration++;
    late final Future<SshAgentForwardingPolicy> loading;
    loading = _loadPolicy()
        .then((policy) {
          final keys = _dedupeKeys(policy.keys);
          return SshAgentForwardingPolicy(
            enabled: policy.enabled,
            confirmEachSignature: policy.confirmEachSignature,
            keys: keys,
          );
        })
        .catchError((Object error) {
          // Refuse this request, and read the settings again for the next.
          if (identical(_policy, loading)) {
            _policy = null;
          }
          _log('policy_load_failed', {'errorType': error.runtimeType});
          return SshAgentForwardingPolicy.off;
        });
    _policy = loading;
    unawaited(
      loading.then((policy) {
        if (!identical(_policy, loading)) {
          return;
        }
        _status.value = _status.value.copyWith(
          serving:
              policy.enabled && !_stopped && !_connectionClosed.isCompleted,
          confirmEachSignature: policy.confirmEachSignature,
        );
      }),
    );
    return loading;
  }

  /// The newest policy: if the settings change while a load is pending, the
  /// newer load is awaited instead, until none is newer.
  Future<SshAgentForwardingPolicy> _latestPolicy() async {
    while (true) {
      final pending = _currentPolicy();
      final generation = _policyGeneration;
      final policy = await pending;
      if (generation == _policyGeneration) {
        return policy;
      }
    }
  }

  static List<SshAgentKey> _dedupeKeys(List<SshAgentKey> keys) {
    final unique = <SshAgentKey>[];
    for (final key in keys) {
      if (!unique.any(
        (other) => const ListEquality<int>().equals(
          other.publicKeyBlob,
          key.publicKeyBlob,
        ),
      )) {
        unique.add(key);
      }
    }
    return unique;
  }

  Future<Uint8List> _answerIdentities() async {
    final policy = await _latestPolicy();
    if (!policy.enabled || _stopped) {
      _log('identities_refused', const {});
      return _failure();
    }
    final keys = policy.keys;
    _log('identities_requested', {'keyCount': keys.length});
    final writer = BytesBuilder(copy: false)
      ..addByte(SSHAgentProtocol.identitiesAnswer)
      ..add(_uint32(keys.length));
    for (final key in keys) {
      writer
        ..add(_sshString(key.publicKeyBlob))
        ..add(_sshString(utf8.encode(key.label)));
    }
    return writer.takeBytes();
  }

  Future<Uint8List> _answerSignRequest(Uint8List body) async {
    final request = _parseSignRequest(body);
    if (request == null) {
      _logSignOutcome('malformed');
      return _failure();
    }
    var confirmed = false;
    while (true) {
      final policy = await _latestPolicy();
      final key = _authorizedKey(policy, request.keyBlob);
      if (key == null) {
        _logSignOutcome(
          policy.enabled && !_stopped ? 'unknown_key' : 'forwarding_off',
        );
        return _failure();
      }
      final username = parseSshUserauthSignedData(
        request.data,
        keyBlob: key.publicKeyBlob,
      );
      if (username == null) {
        _logSignOutcome('not_user_auth', keyType: key.keyType);
        return _failure();
      }
      if (policy.confirmEachSignature && !confirmed) {
        final decision = await _askToSign(key, username);
        if (decision != SshAgentSignatureDecision.approved) {
          _logSignOutcome(decision.name, keyType: key.keyType);
          return _failure();
        }
        confirmed = true;
        // The settings may have changed while the prompt was open.
        continue;
      }
      if (!_takeSignatureToken()) {
        _logSignOutcome('rate_limited', keyType: key.keyType);
        return _failure();
      }
      final SSHSignature signature;
      try {
        signature = await _sign(key, request.data, request.flags);
      } on Object catch (error) {
        // Programming errors still surface; dartssh2 answers them with a
        // failure too.
        if (error is! Exception && error is! SSHError) {
          rethrow;
        }
        _logSignOutcome(
          'sign_failed',
          keyType: key.keyType,
          errorType: error.runtimeType,
        );
        return _failure();
      }
      // Signing can be asynchronous (a hardware key, say): check once more
      // that the newest settings still allow it before sending it.
      final after = await _latestPolicy();
      if (_authorizedKey(after, request.keyBlob) == null ||
          (after.confirmEachSignature && !confirmed)) {
        _logSignOutcome('settings_changed', keyType: key.keyType);
        return _failure();
      }
      _status.value = _status.value.copyWith(
        signatureCount: _status.value.signatureCount + 1,
      );
      _logSignOutcome('signed', keyType: key.keyType);
      return (BytesBuilder(copy: false)
            ..addByte(SSHAgentProtocol.signResponse)
            ..add(_sshString(signature.encode())))
          .takeBytes();
    }
  }

  /// The key [policy] offers with [keyBlob], or null when forwarding is off,
  /// stopped or closed, or the key is not offered.
  SshAgentKey? _authorizedKey(
    SshAgentForwardingPolicy policy,
    Uint8List keyBlob,
  ) {
    if (!policy.enabled || _stopped || _connectionClosed.isCompleted) {
      return null;
    }
    return policy.keys.firstWhereOrNull(
      (candidate) =>
          const ListEquality<int>().equals(candidate.publicKeyBlob, keyBlob),
    );
  }

  bool _takeSignatureToken() {
    final now = _clock();
    final last = _signatureTokensAt;
    if (last != null) {
      final elapsed = now.difference(last).inMicroseconds / 1e6;
      if (elapsed > 0) {
        _signatureTokens = math.min(
          signatureBurst.toDouble(),
          _signatureTokens + elapsed * signaturesPerSecond,
        );
      }
    }
    _signatureTokensAt = now;
    if (_signatureTokens < 1) {
      return false;
    }
    _signatureTokens -= 1;
    return true;
  }

  Future<SshAgentSignatureDecision> _askToSign(
    SshAgentKey key,
    String username,
  ) async {
    final confirm = _confirm;
    final closed = _connectionClosed;
    if (confirm == null || closed.isCompleted) {
      return SshAgentSignatureDecision.unavailable;
    }
    final refuseUntil = _refuseUntil;
    if (_promptOpen ||
        (refuseUntil != null && _clock().isBefore(refuseUntil))) {
      return SshAgentSignatureDecision.declined;
    }
    _promptOpen = true;
    SshAgentSignatureDecision decision;
    try {
      decision = await confirm(
        SshAgentSignatureRequest(
          hostLabel: hostLabel,
          keyLabel: key.label,
          username: username,
          connectionClosed: closed.future,
          isConnectionClosed: () => closed.isCompleted,
        ),
      );
    } on Exception {
      decision = SshAgentSignatureDecision.unavailable;
    } finally {
      _promptOpen = false;
    }
    switch (decision) {
      case SshAgentSignatureDecision.declined:
        _refuseUntil = _clock().add(declineCooldown);
      case SshAgentSignatureDecision.stopForwarding:
        stop();
      case SshAgentSignatureDecision.approved:
      case SshAgentSignatureDecision.unavailable:
        break;
    }
    return decision;
  }

  void _logSignOutcome(String outcome, {String? keyType, Type? errorType}) {
    _log('sign_request', {
      'outcome': outcome,
      'keyType': ?keyType,
      'confirm': confirmEachSignature,
      'errorType': ?errorType,
    });
  }

  void _log(String event, Map<String, Object?> fields) {
    if (_loggedRequests > _maxLoggedRequests) {
      return;
    }
    _loggedRequests++;
    if (_loggedRequests > _maxLoggedRequests) {
      _diagnostics.info(
        'ssh.agent',
        'log_limit_reached',
        fields: {'hostId': hostId, 'limit': _maxLoggedRequests},
      );
      return;
    }
    _diagnostics.info(
      'ssh.agent',
      event,
      fields: {'hostId': hostId, ...fields},
    );
  }

  static Future<SSHSignature> _sign(
    SshAgentKey key,
    Uint8List data,
    int flags,
  ) async {
    if (key.keyType != 'ssh-rsa') {
      return key.identity.sign(data);
    }
    final algorithm = _rsaAlgorithmForFlags(flags);
    final privateKey = _rsaPrivateKeyOf(key.identity);
    if (privateKey != null) {
      final signer = _rsaSignerFor(algorithm)
        ..init(true, pc.PrivateKeyParameter<pc.RSAPrivateKey>(privateKey));
      return _RsaSignature(algorithm, signer.generateSignature(data).bytes);
    }
    final signature = await key.identity.sign(data);
    if (readSshHostKeyType(signature.encode()) == algorithm) {
      return signature;
    }
    throw const _UnsupportedSignatureAlgorithm();
  }

  static String _rsaAlgorithmForFlags(int flags) {
    if (flags & SSHAgentProtocol.rsaSha2_512 != 0) {
      return _rsaSha512;
    }
    if (flags & SSHAgentProtocol.rsaSha2_256 != 0) {
      return _rsaSha256;
    }
    return _rsaSha1;
  }

  static pc.RSAPrivateKey? _rsaPrivateKeyOf(SSHIdentity identity) =>
      switch (identity) {
        final OpenSSHRsaKeyPair key => pc.RSAPrivateKey(
          key.n,
          key.d,
          key.p,
          key.q,
        ),
        final RsaPrivateKey key => pc.RSAPrivateKey(key.n, key.d, key.p, key.q),
        _ => null,
      };

  // DER-encoded digest algorithm identifiers for PKCS#1 v1.5 signatures.
  static pc.RSASigner _rsaSignerFor(String signatureType) =>
      switch (signatureType) {
        _rsaSha512 => pc.RSASigner(pc.SHA512Digest(), '0609608648016503040203'),
        _rsaSha256 => pc.RSASigner(pc.SHA256Digest(), '0609608648016503040201'),
        _ => pc.RSASigner(pc.SHA1Digest(), '06052b0e03021a'),
      };

  static ({Uint8List keyBlob, Uint8List data, int flags})? _parseSignRequest(
    Uint8List body,
  ) {
    final keyBlob = readSshString(body, 0);
    if (keyBlob == null) {
      return null;
    }
    var offset = 4 + keyBlob.length;
    final data = readSshString(body, offset);
    if (data == null) {
      return null;
    }
    offset += 4 + data.length;
    if (body.length - offset != 4) {
      return null;
    }
    return (keyBlob: keyBlob, data: data, flags: readSshUint32(body, offset));
  }

  static Uint8List _failure() =>
      Uint8List.fromList(const [SSHAgentProtocol.failure]);

  static Uint8List _uint32(int value) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, value);

  static Uint8List _sshString(List<int> bytes) =>
      (BytesBuilder(copy: false)
            ..add(_uint32(bytes.length))
            ..add(bytes))
          .takeBytes();
}

/// An RSA signature in SSH wire format (RFC 8332).
class _RsaSignature implements SSHSignature {
  const _RsaSignature(this.algorithm, this.signature);

  final String algorithm;
  final Uint8List signature;

  @override
  Uint8List encode() =>
      (BytesBuilder(copy: false)
            ..add(SshAgentForwarding._sshString(utf8.encode(algorithm)))
            ..add(SshAgentForwarding._sshString(signature)))
          .takeBytes();
}

/// An RSA signer that cannot produce the signature algorithm a host asked
/// for, such as a hardware key fixed to one hash.
class _UnsupportedSignatureAlgorithm implements Exception {
  const _UnsupportedSignatureAlgorithm();
}

/// Returns the user name a publickey user-authentication request signs in
/// as, or null when [data] is not such a request for [keyBlob].
///
/// This is the data `ssh(1)` asks an agent to sign (RFC 4252 §7), with the
/// OpenSSH host-bound variant. Anything else, such as an `SSHSIG` blob for a
/// git commit signature, returns null.
@visibleForTesting
String? parseSshUserauthSignedData(
  Uint8List data, {
  required Uint8List keyBlob,
}) {
  var offset = 0;
  Uint8List? readString() {
    final value = readSshString(data, offset);
    if (value != null) {
      offset += 4 + value.length;
    }
    return value;
  }

  String? readText() {
    final value = readString();
    if (value == null) {
      return null;
    }
    try {
      return utf8.decode(value);
    } on FormatException {
      return null;
    }
  }

  bool readByte(int expected) {
    if (offset >= data.length || data[offset] != expected) {
      return false;
    }
    offset += 1;
    return true;
  }

  final sessionId = readString();
  if (sessionId == null || sessionId.isEmpty) {
    return null;
  }
  if (!readByte(SshAgentForwarding._userauthRequestMessage)) {
    return null;
  }
  final username = readText();
  if (username == null || readText() != SshAgentForwarding._connectionService) {
    return null;
  }
  final method = readText();
  if (method == null ||
      !SshAgentForwarding._publicKeyMethods.contains(method)) {
    return null;
  }
  // The "has signature" boolean must be TRUE.
  if (!readByte(1)) {
    return null;
  }
  final algorithm = readText();
  final requestKey = readString();
  if (algorithm == null ||
      algorithm.isEmpty ||
      requestKey == null ||
      !const ListEquality<int>().equals(requestKey, keyBlob)) {
    return null;
  }
  if (method == SshAgentForwarding._hostboundMethod) {
    final serverHostKey = readString();
    if (serverHostKey == null || serverHostKey.isEmpty) {
      return null;
    }
  }
  return offset == data.length ? username : null;
}

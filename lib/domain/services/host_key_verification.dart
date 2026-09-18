import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../data/database/database.dart';
import '../../data/repositories/known_hosts_repository.dart';

/// The user decision for a presented SSH host key.
enum HostKeyTrustDecision {
  /// Trust an unknown host key.
  trust,

  /// Replace an existing trusted host key with the presented key.
  replace,

  /// Reject the presented host key.
  reject,
}

/// Callback used to collect a host-key trust decision from the UI.
typedef HostKeyPromptHandler = Future<HostKeyTrustDecision> Function(
  HostKeyVerificationRequest request,
);

/// An SSH host key presented during connection setup.
class VerifiedHostKey {
  /// Creates a [VerifiedHostKey].
  VerifiedHostKey({
    required this.hostname,
    required this.port,
    required this.keyType,
    required Uint8List hostKeyBytes,
  }) : hostKeyBytes = Uint8List.fromList(hostKeyBytes),
       trustedKeyType = canonicalizeSshHostKeyType(
         keyType,
         hostKeyBytes: hostKeyBytes,
       ),
       fingerprint = formatSshHostKeyFingerprint(hostKeyBytes),
       md5Fingerprint = formatLegacySshHostKeyFingerprint(hostKeyBytes),
       encodedHostKey = base64.encode(hostKeyBytes);

  /// The host name being verified.
  final String hostname;

  /// The SSH port being verified.
  final int port;

  /// The SSH host-key algorithm reported during negotiation.
  final String keyType;

  /// The canonical host-key algorithm persisted for trust records.
  final String trustedKeyType;

  /// The raw SSH wire-format host key bytes.
  final Uint8List hostKeyBytes;

  /// The SHA-256 fingerprint shown to the user and persisted.
  final String fingerprint;

  /// The legacy MD5 fingerprint accepted for imported entries.
  final String md5Fingerprint;

  /// The base64-encoded raw host key persisted in the database.
  final String encodedHostKey;

  /// Human-readable host label used in prompts and errors.
  String get hostLabel => '$hostname:$port';

  /// Whether this key matches an existing trusted host entry.
  bool matches(KnownHost knownHost) => sshHostTrustMatches(
    firstFingerprint: knownHost.fingerprint,
    firstEncodedHostKey: knownHost.hostKey,
    secondFingerprint: fingerprint,
    secondEncodedHostKey: encodedHostKey,
  );
}

/// A host-key verification request shown to the user.
class HostKeyVerificationRequest {
  /// Creates a [HostKeyVerificationRequest].
  const HostKeyVerificationRequest({
    required this.presentedHostKey,
    required this.existingKnownHost,
  });

  /// The host key the server just presented.
  final VerifiedHostKey presentedHostKey;

  /// The trusted entry already stored for the host, if any.
  final KnownHost? existingKnownHost;

  /// Whether the host already has a stored trust record.
  bool get isReplacement => existingKnownHost != null;

  /// Human-readable host label used in prompts and errors.
  String get hostLabel => presentedHostKey.hostLabel;
}

enum _TrustedHostUpdateMode { touch, upsert }

/// A deferred persistence action to apply after authentication succeeds.
class PendingHostTrustUpdate {
  PendingHostTrustUpdate._({
    required this._presentedHostKey,
    required this._mode,
    this._resetFirstSeen = false,
    this._persistBeforeAuthentication = false,
  });

  /// Creates an update that refreshes the stored host key metadata.
  factory PendingHostTrustUpdate.touch(VerifiedHostKey presentedHostKey) =>
      PendingHostTrustUpdate._(
        presentedHostKey: presentedHostKey,
        mode: _TrustedHostUpdateMode.touch,
      );

  /// Creates an update that stores or replaces the trusted host key.
  factory PendingHostTrustUpdate.upsert(
    VerifiedHostKey presentedHostKey, {
    required bool resetFirstSeen,
    required bool persistBeforeAuthentication,
  }) => PendingHostTrustUpdate._(
    presentedHostKey: presentedHostKey,
    mode: _TrustedHostUpdateMode.upsert,
    resetFirstSeen: resetFirstSeen,
    persistBeforeAuthentication: persistBeforeAuthentication,
  );

  final VerifiedHostKey _presentedHostKey;
  final _TrustedHostUpdateMode _mode;
  final bool _resetFirstSeen;
  final bool _persistBeforeAuthentication;

  /// Persists a newly accepted TOFU trust decision immediately.
  Future<void> persistTrustDecision(KnownHostsRepository repository) async {
    if (_mode != _TrustedHostUpdateMode.upsert ||
        !_persistBeforeAuthentication) {
      return;
    }

    await repository.upsertTrustedHost(
      hostname: _presentedHostKey.hostname,
      port: _presentedHostKey.port,
      keyType: _presentedHostKey.trustedKeyType,
      fingerprint: _presentedHostKey.fingerprint,
      encodedHostKey: _presentedHostKey.encodedHostKey,
      resetFirstSeen: _resetFirstSeen,
    );
  }

  /// Applies the remaining trusted-host update after authentication succeeds.
  Future<void> commitAfterAuthentication(
    KnownHostsRepository repository,
  ) async {
    if (_mode == _TrustedHostUpdateMode.touch) {
      await repository.markTrustedHostSeen(
        hostname: _presentedHostKey.hostname,
        port: _presentedHostKey.port,
        keyType: _presentedHostKey.trustedKeyType,
        fingerprint: _presentedHostKey.fingerprint,
        encodedHostKey: _presentedHostKey.encodedHostKey,
      );
      return;
    }

    if (_mode != _TrustedHostUpdateMode.upsert ||
        _persistBeforeAuthentication) {
      return;
    }

    await repository.upsertTrustedHost(
      hostname: _presentedHostKey.hostname,
      port: _presentedHostKey.port,
      keyType: _presentedHostKey.trustedKeyType,
      fingerprint: _presentedHostKey.fingerprint,
      encodedHostKey: _presentedHostKey.encodedHostKey,
      resetFirstSeen: _resetFirstSeen,
    );
  }
}

/// Error thrown when SSH host-key verification fails.
class HostKeyVerificationException implements Exception {
  /// Creates a [HostKeyVerificationException].
  const HostKeyVerificationException(this.message);

  /// Human-readable reason for the failure.
  final String message;

  @override
  String toString() => message;
}

/// Verifies SSH host keys against the persisted known-hosts trust store.
class HostKeyVerificationService {
  /// Creates a [HostKeyVerificationService].
  const HostKeyVerificationService({
    required this._knownHostsRepository,
    this.promptHandler,
  });

  final KnownHostsRepository _knownHostsRepository;

  /// UI callback used for TOFU and changed-key prompts.
  final HostKeyPromptHandler? promptHandler;

  /// Verifies [presentedHostKey] and returns a deferred persistence update.
  Future<PendingHostTrustUpdate> verify(
    VerifiedHostKey presentedHostKey,
  ) async {
    final existingKnownHost = await _knownHostsRepository.getByHost(
      presentedHostKey.hostname,
      presentedHostKey.port,
    );

    if (existingKnownHost == null) {
      await _promptUnknownHost(presentedHostKey);
      return PendingHostTrustUpdate.upsert(
        presentedHostKey,
        resetFirstSeen: true,
        persistBeforeAuthentication: true,
      );
    }

    if (presentedHostKey.matches(existingKnownHost)) {
      return PendingHostTrustUpdate.touch(presentedHostKey);
    }

    await _promptChangedHost(presentedHostKey, existingKnownHost);
    return PendingHostTrustUpdate.upsert(
      presentedHostKey,
      resetFirstSeen: true,
      persistBeforeAuthentication: false,
    );
  }

  Future<void> _promptUnknownHost(VerifiedHostKey presentedHostKey) async {
    final handler = promptHandler;
    if (handler == null) {
      throw HostKeyVerificationException(
        'Host key verification is required for '
        '${presentedHostKey.hostLabel}, but no trust prompt is available.',
      );
    }

    final decision = await handler(
      HostKeyVerificationRequest(
        presentedHostKey: presentedHostKey,
        existingKnownHost: null,
      ),
    );
    if (decision != HostKeyTrustDecision.trust) {
      throw HostKeyVerificationException(
        'Connection cancelled because ${presentedHostKey.hostLabel} is not '
        'trusted yet.',
      );
    }
  }

  Future<void> _promptChangedHost(
    VerifiedHostKey presentedHostKey,
    KnownHost existingKnownHost,
  ) async {
    final handler = promptHandler;
    if (handler == null) {
      throw HostKeyVerificationException(
        'The trusted host key for ${presentedHostKey.hostLabel} changed, but '
        'the replacement prompt is not available.',
      );
    }

    final decision = await handler(
      HostKeyVerificationRequest(
        presentedHostKey: presentedHostKey,
        existingKnownHost: existingKnownHost,
      ),
    );
    if (decision != HostKeyTrustDecision.replace) {
      throw HostKeyVerificationException(
        'Connection cancelled because the trusted host key for '
        '${presentedHostKey.hostLabel} changed.',
      );
    }
  }
}

/// Returns the canonical SSH host-key algorithm for persisted trust records.
String canonicalizeSshHostKeyType(
  String keyType, {
  Uint8List? hostKeyBytes,
  String? encodedHostKey,
}) {
  final decodedKeyType =
      _tryReadSshHostKeyType(hostKeyBytes) ??
      _tryReadSshHostKeyTypeFromEncodedKey(encodedHostKey);
  if (decodedKeyType != null && decodedKeyType.isNotEmpty) {
    return decodedKeyType;
  }

  return switch (keyType) {
    'rsa-sha2-256' || 'rsa-sha2-512' => 'ssh-rsa',
    _ => keyType,
  };
}

/// Returns whether two SSH host-key trust records represent the same key.
bool sshHostTrustMatches({
  required String firstFingerprint,
  required String firstEncodedHostKey,
  required String secondFingerprint,
  required String secondEncodedHostKey,
}) {
  final first = _HostTrustMaterial.fromRecord(
    fingerprint: firstFingerprint,
    encodedHostKey: firstEncodedHostKey,
  );
  final second = _HostTrustMaterial.fromRecord(
    fingerprint: secondFingerprint,
    encodedHostKey: secondEncodedHostKey,
  );
  return first.matches(second);
}

class _HostTrustMaterial {
  _HostTrustMaterial({
    required this.encodedHostKey,
    required this._fingerprints,
  });

  factory _HostTrustMaterial.fromRecord({
    required String fingerprint,
    required String encodedHostKey,
  }) {
    final fingerprints = <String>{};
    if (fingerprint.isNotEmpty) {
      fingerprints.add(fingerprint);
    }

    final hostKeyBytes = _decodeHostKey(encodedHostKey);
    if (hostKeyBytes != null) {
      fingerprints
        ..add(formatSshHostKeyFingerprint(hostKeyBytes))
        ..add(formatLegacySshHostKeyFingerprint(hostKeyBytes));
    }

    return _HostTrustMaterial(
      encodedHostKey: encodedHostKey,
      fingerprints: fingerprints,
    );
  }

  final String encodedHostKey;
  final Set<String> _fingerprints;

  bool matches(_HostTrustMaterial other) {
    if (encodedHostKey.isNotEmpty && other.encodedHostKey.isNotEmpty) {
      return encodedHostKey == other.encodedHostKey;
    }

    return _fingerprints.any(other._fingerprints.contains);
  }
}

/// Formats the preferred SHA-256 SSH host-key fingerprint.
String formatSshHostKeyFingerprint(List<int> hostKeyBytes) {
  final digest = sha256.convert(hostKeyBytes).bytes;
  final encoded = base64.encode(digest).replaceAll('=', '');
  return 'SHA256:$encoded';
}

/// Formats the legacy MD5 SSH host-key fingerprint.
String formatLegacySshHostKeyFingerprint(List<int> hostKeyBytes) {
  final digest = md5.convert(hostKeyBytes).bytes;
  final buffer = StringBuffer();
  for (var i = 0; i < digest.length; i++) {
    if (i > 0) {
      buffer.write(':');
    }
    buffer.write(digest[i].toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

String? _tryReadSshHostKeyType(Uint8List? hostKeyBytes) {
  if (hostKeyBytes == null || hostKeyBytes.length < 4) {
    return null;
  }

  final typeLength = _readUint32(hostKeyBytes);
  const typeStart = 4;
  final typeEnd = typeStart + typeLength;
  if (typeLength <= 0 || typeEnd > hostKeyBytes.length) {
    return null;
  }

  try {
    return utf8.decode(hostKeyBytes.sublist(typeStart, typeEnd));
  } on FormatException {
    return null;
  }
}

String? _tryReadSshHostKeyTypeFromEncodedKey(String? encodedHostKey) {
  final hostKeyBytes = _decodeHostKey(encodedHostKey);
  if (hostKeyBytes == null) {
    return null;
  }
  return _tryReadSshHostKeyType(hostKeyBytes);
}

Uint8List? _decodeHostKey(String? encodedHostKey) {
  if (encodedHostKey == null || encodedHostKey.isEmpty) {
    return null;
  }

  try {
    return Uint8List.fromList(base64.decode(encodedHostKey));
  } on FormatException {
    return null;
  }
}

int _readUint32(Uint8List bytes, [int offset = 0]) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

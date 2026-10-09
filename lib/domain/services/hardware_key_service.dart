import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/database.dart';
import '../models/hardware_key.dart';
import 'diagnostics_log_service.dart';
import 'ssh_wire.dart';

/// SSH algorithm name of every hardware-backed key.
const hardwareKeyAlgorithm = 'ecdsa-sha2-nistp256';

const _curveName = 'nistp256';
const _uncompressedPointLength = 65;
const _maxScalarBytes = 32;

/// Why a hardware key operation failed.
enum HardwareKeyErrorCode {
  /// The user dismissed the biometric or passcode prompt.
  cancelled('cancelled'),

  /// Biometric or passcode confirmation failed or is locked out.
  authenticationFailed('auth_failed'),

  /// Confirmation needs the app on screen, e.g. during a background reconnect.
  interactionRequired('interaction_required'),

  /// The key is not in this device's secure hardware.
  keyNotFound('key_not_found'),

  /// The OS invalidated the key, e.g. after biometric enrollment changed.
  keyInvalidated('key_invalidated'),

  /// No biometrics or screen lock is set up for per-use confirmation.
  userPresenceUnavailable('user_presence_unavailable'),

  /// The keystore produced a software key instead of a hardware one.
  notHardwareBacked('not_hardware_backed'),

  /// Secure hardware is unavailable on this device or platform.
  unavailable('unavailable'),

  /// Any other failure.
  failed('failed');

  const HardwareKeyErrorCode(this.wireName);

  /// Error code used on the platform channel.
  final String wireName;

  /// Parses a platform error [code], defaulting to [failed].
  static HardwareKeyErrorCode fromWireName(String? code) {
    for (final value in values) {
      if (value.wireName == code) {
        return value;
      }
    }
    return failed;
  }
}

/// Failure reported by secure hardware.
///
/// Carries only a code: platform messages can name the alias or other
/// details that must not reach logs.
class HardwareKeyException implements Exception {
  /// Creates a [HardwareKeyException].
  const HardwareKeyException(this.code);

  /// What went wrong.
  final HardwareKeyErrorCode code;

  /// User-facing explanation.
  String get message => switch (code) {
    HardwareKeyErrorCode.cancelled =>
      'Hardware key confirmation was cancelled.',
    HardwareKeyErrorCode.authenticationFailed =>
      'Hardware key confirmation failed. Try again.',
    HardwareKeyErrorCode.interactionRequired =>
      'This hardware key needs confirmation on screen, so it can’t sign in '
          'from the background. Open the app and reconnect.',
    HardwareKeyErrorCode.keyNotFound =>
      'This hardware key is no longer on this device. Generate a new key and '
          'add its public key to the server.',
    HardwareKeyErrorCode.keyInvalidated =>
      'The device invalidated this hardware key after its biometrics or '
          'screen lock changed. Generate a new key.',
    HardwareKeyErrorCode.userPresenceUnavailable =>
      'Set up biometrics or a screen lock to use per-use confirmation.',
    HardwareKeyErrorCode.notHardwareBacked =>
      HardwareKeyUnavailableReason.softwareKeystoreOnly.message,
    HardwareKeyErrorCode.unavailable =>
      'Secure hardware isn’t available on this device.',
    HardwareKeyErrorCode.failed => 'The hardware key operation failed.',
  };

  @override
  String toString() => 'HardwareKeyException(${code.wireName})';
}

/// Public half of a freshly generated hardware key.
typedef HardwareKeyGenerationResult = ({
  Uint8List publicKey,
  HardwareKeyBacking backing,
  bool isEmulated,
});

/// Native secure-hardware operations.
abstract interface class HardwareKeyPlatform {
  /// Reports what the device's secure hardware supports.
  Future<Map<Object?, Object?>> getCapabilities();

  /// Generates a P-256 key under [alias] and returns its uncompressed point.
  Future<HardwareKeyGenerationResult> generateKey({
    required String alias,
    required bool requireUserPresence,
  });

  /// Signs [data] with SHA-256 ECDSA, returning an X9.62 DER signature.
  Future<Uint8List> sign({
    required String alias,
    required Uint8List data,
    required String reason,
    required String requestId,
  });

  /// Dismisses the confirmation prompt of a pending [sign] call.
  Future<void> cancelSign(String requestId);

  /// Deletes the key under [alias]; succeeds when it is already gone.
  Future<void> deleteKey(String alias);
}

/// [HardwareKeyPlatform] backed by the app's native method channel.
class MethodChannelHardwareKeyPlatform implements HardwareKeyPlatform {
  /// Creates a [MethodChannelHardwareKeyPlatform].
  const MethodChannelHardwareKeyPlatform([
    this._channel = const MethodChannel(hardwareKeyChannelName),
  ]);

  /// Name of the native method channel.
  static const hardwareKeyChannelName =
      'xyz.depollsoft.monkeyssh/hardware_keys';

  final MethodChannel _channel;

  Future<T?> _invoke<T>(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      throw HardwareKeyException(HardwareKeyErrorCode.fromWireName(error.code));
    } on MissingPluginException {
      throw const HardwareKeyException(HardwareKeyErrorCode.unavailable);
    }
  }

  @override
  Future<Map<Object?, Object?>> getCapabilities() async =>
      await _invoke<Map<Object?, Object?>>('getCapabilities') ?? const {};

  @override
  Future<HardwareKeyGenerationResult> generateKey({
    required String alias,
    required bool requireUserPresence,
  }) async {
    final result = await _invoke<Map<Object?, Object?>>('generateKey', {
      'alias': alias,
      'requireUserPresence': requireUserPresence,
    });
    final publicKey = result?['publicKey'];
    final backing = HardwareKeyBacking.fromWireName(result?['backing']);
    if (publicKey is! Uint8List || backing == null) {
      throw const HardwareKeyException(HardwareKeyErrorCode.failed);
    }
    return (
      publicKey: publicKey,
      backing: backing,
      isEmulated: result?['isEmulator'] == true,
    );
  }

  @override
  Future<Uint8List> sign({
    required String alias,
    required Uint8List data,
    required String reason,
    required String requestId,
  }) async {
    final signature = await _invoke<Uint8List>('sign', {
      'alias': alias,
      'data': data,
      'reason': reason,
      'requestId': requestId,
    });
    if (signature == null) {
      throw const HardwareKeyException(HardwareKeyErrorCode.failed);
    }
    return signature;
  }

  @override
  Future<void> cancelSign(String requestId) =>
      _invoke<void>('cancelSign', {'requestId': requestId});

  @override
  Future<void> deleteKey(String alias) =>
      _invoke<void>('deleteKey', {'alias': alias});
}

/// Encodes an uncompressed P-256 point as an OpenSSH public-key blob.
///
/// The blob is `string "ecdsa-sha2-nistp256"`, `string "nistp256"`, and
/// `string Q` (RFC 5656 section 3.1).
Uint8List encodeEcdsaP256PublicKeyBlob(Uint8List uncompressedPoint) {
  if (uncompressedPoint.length != _uncompressedPointLength ||
      uncompressedPoint.first != 0x04) {
    throw const FormatException('Expected an uncompressed P-256 point');
  }
  final builder = BytesBuilder(copy: false);
  _writeSshString(builder, ascii.encode(hardwareKeyAlgorithm));
  _writeSshString(builder, ascii.encode(_curveName));
  _writeSshString(builder, uncompressedPoint);
  return builder.toBytes();
}

/// Converts an X9.62 DER ECDSA P-256 signature to the SSH wire form.
///
/// Secure Enclave and Android Keystore both return
/// `SEQUENCE { INTEGER r, INTEGER s }`; SSH wants `string algorithm` and
/// `string (mpint r || mpint s)` (RFC 5656 section 3.1.2).
EcdsaP256SshSignature ecdsaP256SignatureFromDer(Uint8List der) {
  final reader = _DerReader(der);
  final sequence = reader.readElement(0x30);
  if (!reader.isDone) {
    throw const FormatException('Trailing bytes after ECDSA signature');
  }
  final values = _DerReader(sequence);
  final r = _readPositiveInteger(values);
  final s = _readPositiveInteger(values);
  if (!values.isDone) {
    throw const FormatException('Unexpected ECDSA signature fields');
  }
  return EcdsaP256SshSignature(r, s);
}

BigInt _readPositiveInteger(_DerReader reader) {
  final bytes = reader.readElement(0x02);
  if (bytes.isEmpty || bytes.first & 0x80 != 0) {
    throw const FormatException('ECDSA scalar must be positive');
  }
  var start = 0;
  while (start < bytes.length - 1 && bytes[start] == 0) {
    start++;
  }
  if (bytes.length - start > _maxScalarBytes) {
    throw const FormatException('ECDSA scalar is too large for P-256');
  }
  var value = BigInt.zero;
  for (final byte in bytes.skip(start)) {
    value = (value << 8) | BigInt.from(byte);
  }
  if (value == BigInt.zero) {
    throw const FormatException('ECDSA scalar must be positive');
  }
  return value;
}

class _DerReader {
  _DerReader(this._bytes);

  final Uint8List _bytes;
  int _offset = 0;

  bool get isDone => _offset == _bytes.length;

  Uint8List readElement(int tag) {
    if (_bytes.length - _offset < 2 || _bytes[_offset] != tag) {
      throw const FormatException('Malformed DER element');
    }
    _offset++;
    var length = _bytes[_offset++];
    if (length & 0x80 != 0) {
      final lengthBytes = length & 0x7f;
      if (lengthBytes == 0 ||
          lengthBytes > 2 ||
          _bytes.length - _offset < lengthBytes) {
        throw const FormatException('Malformed DER length');
      }
      length = 0;
      for (var i = 0; i < lengthBytes; i++) {
        length = (length << 8) | _bytes[_offset++];
      }
    }
    if (_bytes.length - _offset < length) {
      throw const FormatException('Truncated DER element');
    }
    final element = Uint8List.sublistView(_bytes, _offset, _offset + length);
    _offset += length;
    return element;
  }
}

void _writeSshString(BytesBuilder builder, List<int> value) {
  final length = ByteData(4)..setUint32(0, value.length);
  builder
    ..add(length.buffer.asUint8List())
    ..add(value);
}

Uint8List _encodeMpint(BigInt value) {
  if (value == BigInt.zero) {
    return Uint8List(0);
  }
  final bytes = <int>[];
  var remaining = value;
  while (remaining > BigInt.zero) {
    bytes.insert(0, (remaining & BigInt.from(0xff)).toInt());
    remaining >>= 8;
  }
  if (bytes.first & 0x80 != 0) {
    bytes.insert(0, 0);
  }
  return Uint8List.fromList(bytes);
}

/// OpenSSH `ecdsa-sha2-nistp256` signature.
class EcdsaP256SshSignature implements SSHSignature {
  /// Creates a signature from its scalars.
  EcdsaP256SshSignature(this.r, this.s);

  /// The `r` scalar.
  final BigInt r;

  /// The `s` scalar.
  final BigInt s;

  @override
  Uint8List encode() {
    final blob = BytesBuilder(copy: false);
    _writeSshString(blob, _encodeMpint(r));
    _writeSshString(blob, _encodeMpint(s));
    final builder = BytesBuilder(copy: false);
    _writeSshString(builder, ascii.encode(hardwareKeyAlgorithm));
    _writeSshString(builder, blob.toBytes());
    return builder.toBytes();
  }

  // Never print the scalars.
  @override
  String toString() => 'EcdsaP256SshSignature';
}

class _EncodedPublicKey implements SSHHostKey {
  const _EncodedPublicKey(this._blob);

  final Uint8List _blob;

  @override
  Uint8List encode() => _blob;
}

/// Runs a hardware signature, e.g. while pausing an authentication timeout.
typedef HardwareKeySignGuard = Future<SSHSignature> Function(
  Future<SSHSignature> Function() sign,
);

class _PendingSigns {
  final ids = <String>{};
}

int _nextSignRequest = 0;

/// SSH identity whose private key never leaves secure hardware.
///
/// Probes the server before signing, so a key the server would reject never
/// raises a biometric prompt.
class HardwareKeyIdentity extends SSHIdentity {
  HardwareKeyIdentity._({
    required HardwareKeyPlatform platform,
    required this.reference,
    required String signReason,
    _PendingSigns? pending,
    HardwareKeySignGuard? signGuard,
  }) : _platform = platform,
       _publicKey = _EncodedPublicKey(reference.publicKeyBlob),
       _signReason = signReason,
       _pending = pending ?? _PendingSigns(),
       _signGuard = signGuard;

  final HardwareKeyPlatform _platform;
  final _EncodedPublicKey _publicKey;
  final String _signReason;
  final _PendingSigns _pending;
  final HardwareKeySignGuard? _signGuard;

  /// Where the private key lives.
  final HardwareKeyReference reference;

  /// Whether each signature raises a biometric or passcode prompt.
  bool get requiresUserPresence => reference.requiresUserPresence;

  /// Whether a signature request is waiting on the hardware.
  bool get hasPendingSign => _pending.ids.isNotEmpty;

  @override
  String get type => hardwareKeyAlgorithm;

  @override
  bool get shouldProbe => true;

  @override
  SSHHostKey toPublicKey() => _publicKey;

  @override
  Future<SSHSignature> sign(Uint8List data) {
    final guard = _signGuard;
    return guard == null ? _sign(data) : guard(() => _sign(data));
  }

  Future<SSHSignature> _sign(Uint8List data) async {
    final requestId = 'sign-${_nextSignRequest++}';
    _pending.ids.add(requestId);
    try {
      final der = await _platform.sign(
        alias: reference.alias,
        data: data,
        reason: _signReason,
        requestId: requestId,
      );
      return ecdsaP256SignatureFromDer(der);
    } on HardwareKeyException catch (error) {
      DiagnosticsLogService.instance.warning(
        'hardware_key',
        'sign_failed',
        fields: {
          'code': error.code.wireName,
          'backing': reference.backing.wireName,
          'requiresUserPresence': requiresUserPresence,
        },
      );
      rethrow;
    } finally {
      _pending.ids.remove(requestId);
    }
  }

  /// Returns this identity with every signature run through [guard].
  ///
  /// The copy shares pending requests with this identity, so
  /// [cancelPendingSigns] on either dismisses prompts raised by both.
  HardwareKeyIdentity guardedBy(HardwareKeySignGuard guard) =>
      HardwareKeyIdentity._(
        platform: _platform,
        reference: reference,
        signReason: _signReason,
        pending: _pending,
        signGuard: guard,
      );

  /// Dismisses any confirmation prompt still waiting for the user.
  void cancelPendingSigns() {
    for (final requestId in _pending.ids.toList(growable: false)) {
      unawaited(
        _platform.cancelSign(requestId).catchError((Object error) {
          DiagnosticsLogService.instance.debug(
            'hardware_key',
            'cancel_sign_failed',
            fields: {'errorType': error.runtimeType},
          );
        }),
      );
    }
  }
}

/// A newly generated hardware key, ready to store.
typedef GeneratedHardwareKey = ({
  HardwareKeyReference reference,
  Uint8List publicKeyBlob,
});

/// Generates, uses and deletes SSH keys held in secure hardware.
class HardwareKeyService {
  /// Creates a [HardwareKeyService].
  HardwareKeyService({
    HardwareKeyPlatform? platform,
    bool? isPlatformSupported,
    Random? random,
  }) : _platform = platform ?? const MethodChannelHardwareKeyPlatform(),
       _isPlatformSupported =
           isPlatformSupported ??
           (!kIsWeb && (Platform.isIOS || Platform.isAndroid)),
       _random = random ?? Random.secure();

  final HardwareKeyPlatform _platform;
  final bool _isPlatformSupported;
  final Random _random;

  /// Reports whether, and where, this device can hold a hardware key.
  Future<HardwareKeyCapabilities> getCapabilities() async {
    if (!_isPlatformSupported) {
      return const HardwareKeyCapabilities.unavailable(
        HardwareKeyUnavailableReason.unsupportedPlatform,
      );
    }
    try {
      return HardwareKeyCapabilities.fromMap(await _platform.getCapabilities());
    } on HardwareKeyException catch (error) {
      DiagnosticsLogService.instance.warning(
        'hardware_key',
        'capabilities_failed',
        fields: {'code': error.code.wireName},
      );
      return HardwareKeyCapabilities.unavailable(
        error.code == HardwareKeyErrorCode.unavailable
            ? HardwareKeyUnavailableReason.unsupportedPlatform
            : HardwareKeyUnavailableReason.checkFailed,
      );
    }
  }

  /// Generates a P-256 key in secure hardware.
  Future<GeneratedHardwareKey> generate({
    required bool requireUserPresence,
  }) async {
    if (!_isPlatformSupported) {
      throw const HardwareKeyException(HardwareKeyErrorCode.unavailable);
    }
    final alias = _newAlias();
    final HardwareKeyGenerationResult result;
    try {
      result = await _platform.generateKey(
        alias: alias,
        requireUserPresence: requireUserPresence,
      );
    } on HardwareKeyException catch (error) {
      DiagnosticsLogService.instance.warning(
        'hardware_key',
        'generate_failed',
        fields: {
          'code': error.code.wireName,
          'requiresUserPresence': requireUserPresence,
        },
      );
      rethrow;
    }
    final Uint8List publicKeyBlob;
    try {
      publicKeyBlob = encodeEcdsaP256PublicKeyBlob(result.publicKey);
    } on FormatException {
      await _deleteQuietly(alias);
      throw const HardwareKeyException(HardwareKeyErrorCode.failed);
    }
    final reference = HardwareKeyReference(
      alias: alias,
      backing: result.backing,
      publicKeyBlob: publicKeyBlob,
      requiresUserPresence: requireUserPresence,
      isEmulated: result.isEmulated,
    );
    DiagnosticsLogService.instance.info(
      'hardware_key',
      'generated',
      fields: {
        'backing': result.backing.wireName,
        'requiresUserPresence': requireUserPresence,
        'isEmulated': result.isEmulated,
      },
    );
    return (reference: reference, publicKeyBlob: publicKeyBlob);
  }

  /// Builds the SSH identity for a stored hardware key [reference].
  HardwareKeyIdentity identityFor(HardwareKeyReference reference) =>
      HardwareKeyIdentity._(
        platform: _platform,
        reference: reference,
        signReason: 'Sign in with your hardware-backed SSH key',
      );

  /// Deletes the private key from secure hardware.
  Future<void> delete(HardwareKeyReference reference) =>
      _platform.deleteKey(reference.alias);

  Future<void> _deleteQuietly(String alias) async {
    try {
      await _platform.deleteKey(alias);
    } on HardwareKeyException catch (error) {
      DiagnosticsLogService.instance.warning(
        'hardware_key',
        'delete_failed',
        fields: {'code': error.code.wireName},
      );
    }
  }

  String _newAlias() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return 'xyz.depollsoft.monkeyssh.sshkey.$hex';
  }
}

/// Parses a stored hardware key reference whose public key is a valid
/// `ecdsa-sha2-nistp256` blob, or returns `null`.
HardwareKeyReference? parseHardwareKeyReference(String? value) {
  final reference = HardwareKeyReference.tryParse(value);
  if (reference == null ||
      readSshHostKeyType(reference.publicKeyBlob) != hardwareKeyAlgorithm) {
    return null;
  }
  return reference;
}

/// Hardware-backed key details for stored SSH keys.
extension SshKeyHardwareBacking on SshKey {
  /// Whether this key's private half lives in secure hardware.
  ///
  /// True even for a damaged reference, so export paths still refuse it.
  bool get isHardwareBacked =>
      HardwareKeyReference.looksLikeReference(privateKey);

  /// The parsed hardware reference, or `null` for software keys and
  /// damaged references.
  HardwareKeyReference? get hardwareKeyReference =>
      parseHardwareKeyReference(privateKey);
}

/// Provider for [HardwareKeyService].
final hardwareKeyServiceProvider = Provider<HardwareKeyService>(
  (ref) => HardwareKeyService(),
);

/// What this device's secure hardware supports, checked on demand.
final hardwareKeyCapabilitiesProvider =
    FutureProvider.autoDispose<HardwareKeyCapabilities>(
      (ref) => ref.watch(hardwareKeyServiceProvider).getCapabilities(),
    );

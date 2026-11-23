import 'package:dartssh2/src/ssh_algorithm.dart';

/// Compression algorithms supported by the SSH transport layer.
class SSHCompressionType extends SSHAlgorithm {
  /// No compression (RFC 4253 §6.2).
  static const none = SSHCompressionType._(
    name: 'none',
    isDelayed: false,
  );

  /// OpenSSH delayed zlib compression (`zlib@openssh.com`).
  ///
  /// Compression begins only after `SSH_MSG_USERAUTH_SUCCESS` so pre-auth
  /// traffic is never exposed to compression side channels.
  static const zlibDelayed = SSHCompressionType._(
    name: 'zlib@openssh.com',
    isDelayed: true,
  );

  @override
  final String name;

  /// Whether compression activates only after `SSH_MSG_USERAUTH_SUCCESS`.
  final bool isDelayed;

  const SSHCompressionType._({
    required this.name,
    required this.isDelayed,
  });
}

import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/widgets/connection_attempt_logic.dart';

void main() {
  for (final failure in <String, Object>{
    'cancelled': const SshConnectionCancelledException(),
    'auth abort': SSHAuthAbortError('Authentication timed out'),
    'auth failure': SSHAuthFailError('Authentication failed'),
    'SSH state': SSHStateError('Transport closed'),
    'SSH socket': SSHSocketError(const SocketException('Disconnected')),
    'socket': const SocketException('Disconnected'),
    'TLS handshake': const HandshakeException('Handshake failed'),
    'TLS': const TlsException('TLS connection failed'),
    'OS': const OSError('Connection refused', 61),
    'unexpected state': StateError('Unexpected connection state'),
  }.entries) {
    test('${failure.key} classification without an SSH stack frame', () {
      expect(
        isExpectedConnectionAttemptFailure(failure.value, StackTrace.current),
        failure.value is! StateError,
      );
    });
  }
}

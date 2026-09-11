import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/domain/services/ssh_error_policy.dart';

void main() {
  group('SSH socket failures', () {
    final errors = <Object>[
      const SocketException('connection reset'),
      const HandshakeException('handshake failed'),
      const TlsException('TLS failed'),
      const OSError('socket closed', 54),
    ];
    for (final error in errors) {
      test('recognizes ${error.runtimeType} only with SSH evidence', () {
        for (final location in [
          'package:dartssh2/src/socket/ssh_socket_io.dart:32:5',
          'package:dartssh2/src/ssh_transport.dart:100:5',
          'package:monkeyssh/domain/services/ssh_service.dart:100:5',
        ]) {
          expect(
            isExpectedSshOperationError(
              error,
              StackTrace.fromString('#0 connect ($location)'),
            ),
            isTrue,
          );
        }
        for (final stack in [
          StackTrace.empty,
          StackTrace.fromString('#0 _NativeSocket.startConnect (dart:io:1:2)'),
          StackTrace.fromString(
            '#0 fetch (package:http/src/io_client.dart:10:5)',
          ),
          StackTrace.fromString(
            '#0 load (package:monkeyssh/domain/services/settings_service.dart:1:2)',
          ),
        ]) {
          expect(isExpectedSshOperationError(error, stack), isFalse);
        }
        expect(isExpectedSshOperationError(error), isFalse);
      });
    }

    test('does not absorb programming errors with SSH frames', () {
      expect(
        isExpectedSshOperationError(
          StateError('bug'),
          StackTrace.fromString(
            '#0 connect (package:monkeyssh/domain/services/ssh_service.dart:1:2)',
          ),
        ),
        isFalse,
      );
    });
  });

  test('recognizes late dartssh2 channel writes during teardown', () {
    final stackTrace = StackTrace.fromString(
      '#0 SSHTransport.sendPacket\n'
      '#1 SSHChannelController._uploadLoop.<anonymous closure>\n',
    );

    expect(
      isExpectedSshChannelTeardownError(
        SSHStateError('Transport is closed'),
        stackTrace,
      ),
      isTrue,
    );
  });

  test('does not hide SSH state errors from other operations', () {
    expect(
      isExpectedSshChannelTeardownError(
        SSHStateError('Transport is closed'),
        StackTrace.fromString('#0 SshSession.execute\n'),
      ),
      isFalse,
    );
  });

  test('recognizes SSH operation errors that do not extend Exception', () {
    expect(
      isExpectedSshOperationError(SSHChannelOpenError(1, 'denied')),
      isTrue,
    );
    expect(isExpectedSshOperationError(SSHSocketError('closed')), isTrue);
  });

  test('recognizes SFTP status errors that do not extend Exception', () {
    expect(
      isExpectedSshOperationError(
        SftpStatusError(SftpStatusCode.permissionDenied, 'denied'),
      ),
      isTrue,
    );
    expect(isExpectedSshOperationError(StateError('bug')), isFalse);
  });

  test('recognizes channel EOF writes after the transport closes', () {
    final stackTrace = StackTrace.fromString(
      '#0 SSHTransport.sendPacket\n'
      '#1 SSHChannelController._sendEOFIfNeeded\n'
      '#2 SSHChannelController.close\n',
    );

    expect(
      isExpectedSshChannelTeardownError(
        SSHStateError('Transport is closed'),
        stackTrace,
      ),
      isTrue,
    );
  });
}

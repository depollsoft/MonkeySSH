import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

const _channelUploadLoopFrame = 'SSHChannelController._uploadLoop';
const _channelCloseFrame = 'SSHChannelController._sendEOFIfNeeded';

/// Whether [error] is a late channel write after the SSH transport closed.
///
/// dartssh2 starts channel upload loops internally without exposing their
/// futures. A transport disconnect can therefore race a queued write and reach
/// the platform error handler. Closing a channel after the same disconnect can
/// also try to send EOF over the closed transport. Both are expected teardown.
bool isExpectedSshChannelTeardownError(Object error, StackTrace stackTrace) =>
    error is SSHStateError &&
    (_containsFrame(stackTrace, _channelUploadLoopFrame) ||
        _containsFrame(stackTrace, _channelCloseFrame));

/// Whether [error] is an operational SSH or SFTP failure.
///
/// dartssh2 models these as interface types rather than [Exception], so an
/// `on Exception` clause does not catch them.
/// Raw socket errors require an SSH frame: their type alone does not identify
/// the owner, and an empty stack must not classify unrelated network failures.
bool isExpectedSshOperationError(Object error, [StackTrace? stackTrace]) =>
    error is SSHError ||
    error is SftpError ||
    ((error is SocketException || error is TlsException || error is OSError) &&
        stackTrace != null &&
        _sshTransportFrame.hasMatch(stackTrace.toString()));

final _sshTransportFrame = RegExp(
  r'package:(?:dartssh2/src/(?:socket/ssh_socket(?:_io|_js)?|ssh_transport|ssh_client|ssh_channel)|monkeyssh/domain/services/ssh_service)\.dart:\d+',
);

bool _containsFrame(StackTrace stackTrace, String frame) =>
    stackTrace.toString().contains(frame);

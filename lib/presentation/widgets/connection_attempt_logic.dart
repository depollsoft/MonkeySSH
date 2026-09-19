import 'dart:io';

import '../../domain/services/ssh_error_policy.dart';
import '../../domain/services/ssh_service.dart';

/// Whether a connection failure is expected rather than a framework error.
bool isExpectedConnectionAttemptFailure(Object error, StackTrace stackTrace) =>
    isExpectedSshOperationError(error, stackTrace) ||
    error is SocketException ||
    error is HandshakeException ||
    error is TlsException ||
    error is OSError ||
    error is SshConnectionCancelledException;

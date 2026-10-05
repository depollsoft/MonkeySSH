// Shared one-line mocktail doubles. Register fallback values per test file.

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/domain/services/auth_service.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

/// Mock dartssh2 [SSHClient].
class MockSshClient extends Mock implements SSHClient {}

/// Mock dartssh2 [SSHSession] (an exec or shell channel), not the app's
/// [SshSession]; see [MockSshSession] for that.
class MockSSHSession extends Mock implements SSHSession {}

/// Mock app-level [SshSession].
class MockSshSession extends Mock implements SshSession {}

/// Mock dartssh2 [SftpClient].
class MockSftpClient extends Mock implements SftpClient {}

/// Mock [HostRepository].
class MockHostRepository extends Mock implements HostRepository {}

/// Mock [AuthService].
class MockAuthService extends Mock implements AuthService {}

/// Mock [MonetizationService].
class MockMonetizationService extends Mock implements MonetizationService {}

/// Mock [FlutterSecureStorage].
class MockFlutterSecureStorage extends Mock implements FlutterSecureStorage {}

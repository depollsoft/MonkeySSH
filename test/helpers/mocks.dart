// Shared one-line mocktail doubles. Register fallback values per test file.

import 'package:cross_file/cross_file.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/port_forward_repository.dart';
import 'package:monkeyssh/data/repositories/snippet_repository.dart';
import 'package:monkeyssh/domain/services/agent_launch_preset_service.dart';
import 'package:monkeyssh/domain/services/agent_management_service.dart';
import 'package:monkeyssh/domain/services/agent_session_discovery_service.dart';
import 'package:monkeyssh/domain/services/auth_service.dart';
import 'package:monkeyssh/domain/services/host_cli_launch_preferences_service.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_service.dart';
import 'package:monkeyssh/domain/services/remote_file_service.dart';
import 'package:monkeyssh/domain/services/secure_transfer_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/domain/services/tmux_service.dart';

/// Mock dartssh2 [SSHClient].
class MockSshClient extends Mock implements SSHClient {}

/// Mock dartssh2 [SSHSession] (an exec or shell channel), not the app's
/// [SshSession]; see [MockSshSession] for that.
class MockSSHSession extends Mock implements SSHSession {}

/// Mock app-level [SshSession].
class MockSshSession extends Mock implements SshSession {}

/// Mock [SshService].
class MockSshService extends Mock implements SshService {}

/// Mock dartssh2 [SftpClient].
class MockSftpClient extends Mock implements SftpClient {}

/// Mock dartssh2 [SftpFile].
class MockSftpFile extends Mock implements SftpFile {}

/// Mock [HostRepository].
class MockHostRepository extends Mock implements HostRepository {}

/// Mock [PortForwardRepository].
class MockPortForwardRepository extends Mock implements PortForwardRepository {}

/// Mock [SnippetRepository].
class MockSnippetRepository extends Mock implements SnippetRepository {}

/// Mock [AuthService].
class MockAuthService extends Mock implements AuthService {}

/// Mock [MonetizationService].
class MockMonetizationService extends Mock implements MonetizationService {}

/// Mock [FlutterSecureStorage].
class MockFlutterSecureStorage extends Mock implements FlutterSecureStorage {}

/// Mock [HostCliLaunchPreferencesService].
class MockHostCliLaunchPreferencesService extends Mock
    implements HostCliLaunchPreferencesService {}

/// Mock [AgentLaunchPresetService].
class MockAgentLaunchPresetService extends Mock
    implements AgentLaunchPresetService {}

/// Mock [AgentManagementService].
class MockAgentManagementService extends Mock
    implements AgentManagementService {}

/// Mock [AgentSessionDiscoveryService].
class MockAgentSessionDiscoveryService extends Mock
    implements AgentSessionDiscoveryService {}

/// Mock [MonkeyMuxService].
class MockMonkeyMuxService extends Mock implements MonkeyMuxService {}

/// Mock [TmuxService].
class MockTmuxService extends Mock implements TmuxService {}

/// Mock [RemoteFileService].
class MockRemoteFileService extends Mock implements RemoteFileService {}

/// Mock [SecureTransferService].
class MockSecureTransferService extends Mock implements SecureTransferService {}

/// Mock [XFile].
class MockXFile extends Mock implements XFile {}

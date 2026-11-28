// ignore_for_file: public_member_api_docs

import 'acp_bridge_connector_cases.dart';
import 'acp_client_capability_elicitation_cases.dart';
import 'acp_launch_profile_service_cases.dart';
import 'acp_lifecycle_service_cases.dart';
import 'acp_session_manager_elicitation_cases.dart';
import 'acp_telemetry_adapter_cases.dart';
import 'authorized_key_install_service_cases.dart';
import 'socks5_protocol_cases.dart';
import 'ssh_config_parser_cases.dart';
import 'ssh_session_runtime_cases.dart';
import 'telemetry_service_cases.dart';
import 'terminal_command_mark_tracker_cases.dart';
import 'terminal_connection_backend_service_cases.dart';
import 'windows_remote_powershell_cases.dart';

void main() {
  registerDomainServicesAcpBridgeConnectorTests();
  registerDomainServicesAcpClientCapabilityElicitationTests();
  registerDomainServicesAcpLaunchProfileServiceTests();
  registerDomainServicesAcpLifecycleServiceTests();
  registerDomainServicesAcpSessionManagerElicitationTests();
  registerDomainServicesAcpTelemetryAdapterTests();
  registerDomainServicesAuthorizedKeyInstallServiceTests();
  registerDomainServicesSocks5ProtocolTests();
  registerDomainServicesSshConfigParserTests();
  registerDomainServicesSshSessionRuntimeTests();
  registerDomainServicesTelemetryServiceTests();
  registerDomainServicesTerminalCommandMarkTrackerTests();
  registerDomainServicesTerminalConnectionBackendServiceTests();
  registerDomainServicesWindowsRemotePowershellTests();
}

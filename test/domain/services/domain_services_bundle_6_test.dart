// ignore_for_file: public_member_api_docs

import 'acp_attachment_service_cases.dart';
import 'acp_composer_draft_store_cases.dart';
import 'acp_mcp_server_service_cases.dart';
import 'acp_recent_sessions_service_cases.dart';
import 'agent_launch_preset_service_cases.dart';
import 'agent_usage_parser_cases.dart';
import 'background_ssh_service_cases.dart';
import 'codex_active_session_metadata_cases.dart';
import 'host_cli_launch_preferences_service_cases.dart';
import 'monkeymux_login_shell_command_cases.dart';
import 'official_agent_installers_cases.dart';
import 'shell_completion_service_cases.dart';
import 'socks_forward_route_cases.dart';
import 'ssh_dynamic_forward_cases.dart';
import 'synchronized_output_hold_cases.dart';

void main() {
  registerDomainServicesAcpAttachmentServiceTests();
  registerDomainServicesAcpComposerDraftStoreTests();
  registerDomainServicesAcpMcpServerServiceTests();
  registerDomainServicesAcpRecentSessionsServiceTests();
  registerDomainServicesAgentLaunchPresetServiceTests();
  registerDomainServicesAgentUsageParserTests();
  registerDomainServicesBackgroundSshServiceTests();
  registerDomainServicesCodexActiveSessionMetadataTests();
  registerDomainServicesHostCliLaunchPreferencesServiceTests();
  registerDomainServicesMonkeymuxLoginShellCommandTests();
  registerDomainServicesOfficialAgentInstallersTests();
  registerDomainServicesShellCompletionServiceTests();
  registerDomainServicesSocksForwardRouteTests();
  registerDomainServicesSshDynamicForwardTests();
  registerDomainServicesSynchronizedOutputHoldTests();
}

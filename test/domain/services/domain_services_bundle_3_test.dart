// ignore_for_file: public_member_api_docs

import 'acp_custom_provider_host_service_cases.dart';
import 'acp_custom_provider_service_cases.dart';
import 'acp_json_rpc_connection_cases.dart';
import 'acp_session_manager_writer_lease_cases.dart';
import 'agent_worktree_launcher_cases.dart';
import 'app_link_service_cases.dart';
import 'host_agent_forwarding_service_cases.dart';
import 'key_service_cases.dart';
import 'local_notification_service_cases.dart';
import 'pi_model_scope_metadata_service_cases.dart';
import 'ssh_agent_forwarding_cases.dart';
import 'ssh_exec_queue_cases.dart';
import 'terminal_hyperlink_tracker_cases.dart';
import 'terminal_iterm2_control_cases.dart';
import 'terminal_preview_graphics_cases.dart';
import 'terminal_scrollback_text_cases.dart';
import 'tmux_service_agent_detection_cases.dart';

void main() {
  registerDomainServicesAcpCustomProviderHostServiceTests();
  registerDomainServicesAcpCustomProviderServiceTests();
  registerDomainServicesAcpJsonRpcConnectionTests();
  registerDomainServicesAcpSessionManagerWriterLeaseTests();
  registerDomainServicesAgentWorktreeLauncherTests();
  registerDomainServicesAppLinkServiceTests();
  registerDomainServicesHostAgentForwardingServiceTests();
  registerDomainServicesKeyServiceTests();
  registerDomainServicesLocalNotificationServiceTests();
  registerDomainServicesPiModelScopeMetadataServiceTests();
  registerDomainServicesSshAgentForwardingTests();
  registerDomainServicesSshExecQueueTests();
  registerDomainServicesTerminalHyperlinkTrackerTests();
  registerDomainServicesTerminalIterm2ControlTests();
  registerDomainServicesTerminalPreviewGraphicsTests();
  registerDomainServicesTerminalScrollbackTextTests();
  registerDomainServicesTmuxServiceAgentDetectionTests();
}

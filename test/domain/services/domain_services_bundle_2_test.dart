// ignore_for_file: public_member_api_docs

import 'acp_client_capability_service_cases.dart';
import 'acp_session_manager_cases.dart';
import 'acp_session_manager_custom_provider_cases.dart';
import 'clipboard_sharing_service_cases.dart';
import 'device_debug_service_cases.dart';
import 'home_screen_shortcut_service_cases.dart';
import 'host_key_verification_cases.dart';
import 'kitty_clipboard_protocol_cases.dart';
import 'monetization_service_cases.dart';
import 'monkeymux_acp_writer_lease_cases.dart';
import 'performance_diagnostics_service_cases.dart';
import 'socks_browser_proxy_service_cases.dart';
import 'socks_browser_store_service_cases.dart';
import 'ssh_session_terminal_notification_cases.dart';
import 'terminal_mode_report_runtime_cases.dart';
import 'terminal_scrollback_search_cases.dart';

void main() {
  registerDomainServicesAcpClientCapabilityServiceTests();
  registerDomainServicesAcpSessionManagerCustomProviderTests();
  registerDomainServicesAcpSessionManagerTests();
  registerDomainServicesClipboardSharingServiceTests();
  registerDomainServicesDeviceDebugServiceTests();
  registerDomainServicesHomeScreenShortcutServiceTests();
  registerDomainServicesHostKeyVerificationTests();
  registerDomainServicesKittyClipboardProtocolTests();
  registerDomainServicesMonetizationServiceTests();
  registerDomainServicesMonkeymuxAcpWriterLeaseTests();
  registerDomainServicesPerformanceDiagnosticsServiceTests();
  registerDomainServicesSocksBrowserProxyServiceTests();
  registerDomainServicesSocksBrowserStoreServiceTests();
  registerDomainServicesSshSessionTerminalNotificationTests();
  registerDomainServicesTerminalModeReportRuntimeTests();
  registerDomainServicesTerminalScrollbackSearchTests();
}

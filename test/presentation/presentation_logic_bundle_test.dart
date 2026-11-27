// ignore_for_file: public_member_api_docs

import 'browser/browser_file_picker_cases.dart';
import 'controllers/acp_composer_controller_cases.dart';
import 'controllers/acp_composer_draft_persistence_cases.dart';
import 'controllers/acp_sftp_client_cache_cases.dart';
import 'controllers/terminal_session_controller_cases.dart';
import 'controllers/terminal_visibility_controller_cases.dart';
import 'models/acp_presentation_models_cases.dart';
import 'models/acp_timeline_mapper_content_cases.dart';
import 'providers/connection_attention_provider_cases.dart';
import 'screens/terminal/mux_session_connection_cases.dart';
import 'shortcuts/app_shortcuts_cases.dart';
import 'shortcuts/app_shortcuts_host_cases.dart';
import 'shortcuts/terminal_shortcut_precedence_cases.dart';
import 'view_models/agent_management_view_model_cases.dart';
import 'view_models/host_edit_view_model_cases.dart';
import 'view_models/mux_badge_controller_hold_cases.dart';

void main() {
  registerPresentationBrowserBrowserFilePickerTests();
  registerPresentationControllersAcpComposerControllerTests();
  registerPresentationControllersAcpComposerDraftPersistenceTests();
  registerPresentationControllersAcpSftpClientCacheTests();
  registerPresentationControllersTerminalSessionControllerTests();
  registerPresentationControllersTerminalVisibilityControllerTests();
  registerPresentationModelsAcpPresentationModelsTests();
  registerPresentationModelsAcpTimelineMapperContentTests();
  registerPresentationProvidersConnectionAttentionProviderTests();
  registerPresentationScreensTerminalMuxSessionConnectionTests();
  registerPresentationShortcutsAppShortcutsHostTests();
  registerPresentationShortcutsAppShortcutsTests();
  registerPresentationShortcutsTerminalShortcutPrecedenceTests();
  registerPresentationViewModelsAgentManagementViewModelTests();
  registerPresentationViewModelsHostEditViewModelTests();
  registerPresentationViewModelsMuxBadgeControllerHoldTests();
}

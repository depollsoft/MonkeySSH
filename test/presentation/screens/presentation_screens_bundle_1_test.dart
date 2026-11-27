// ignore_for_file: public_member_api_docs

import 'host_edit_logic_cases.dart';
import 'remote_text_editor_conflict_cases.dart';
import 'sftp_batch_operations_cases.dart';
import 'sftp_browser_logic_cases.dart';
import 'sftp_browser_view_cases.dart';
import 'tmux_alert_notification_content_cases.dart';
import 'transfer_screen_cases.dart';

void main() {
  registerPresentationScreensHostEditLogicTests();
  registerPresentationScreensRemoteTextEditorConflictTests();
  registerPresentationScreensSftpBatchOperationsTests();
  registerPresentationScreensSftpBrowserLogicTests();
  registerPresentationScreensSftpBrowserViewTests();
  registerPresentationScreensTmuxAlertNotificationContentTests();
  registerPresentationScreensTransferScreenTests();
}

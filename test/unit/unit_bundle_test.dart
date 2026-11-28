// ignore_for_file: public_member_api_docs

import '../data/repositories/decrypt_cost_characterization_cases.dart';
import '../data/repositories/repositories_cases.dart';
import '../domain/commands/save_host_command_cases.dart';
import '../helpers/live_ssh_terminal_helpers_cases.dart';
import '../main_bundled_licenses_cases.dart';
import 'auth_service_cases.dart';
import 'domain/services/port_forward_browser_service_cases.dart';
import 'native_project_configuration_cases.dart';
import 'secret_encryption_service_cases.dart';
import 'terminal_csi_cancellation_cases.dart';
import 'terminal_cursor_keys_mode_cases.dart';
import 'terminal_query_response_cases.dart';
import 'xterm_painter_cursor_cases.dart';
import 'xterm_paragraph_cache_cases.dart';

void main() {
  registerDataRepositoriesDecryptCostCharacterizationTests();
  registerDataRepositoriesRepositoriesTests();
  registerDomainCommandsSaveHostCommandTests();
  registerHelpersLiveSshTerminalHelpersTests();
  registerMainBundledLicensesTests();
  registerUnitAuthServiceTests();
  registerUnitDomainServicesPortForwardBrowserServiceTests();
  registerUnitNativeProjectConfigurationTests();
  registerUnitSecretEncryptionServiceTests();
  registerUnitTerminalCsiCancellationTests();
  registerUnitTerminalCursorKeysModeTests();
  registerUnitTerminalQueryResponseTests();
  registerUnitXtermPainterCursorTests();
  registerUnitXtermParagraphCacheTests();
}

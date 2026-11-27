// ignore_for_file: public_member_api_docs

import 'acp_json_cases.dart';
import 'acp_protocol_cases.dart';
import 'acp_recent_session_cases.dart';
import 'acp_session_keys_cases.dart';

/// Registers tests from acp_models_test.dart.
void registerDomainModelsAcpModelsTests() {
  registerAcpJsonTests();
  registerAcpProtocolTests();
  registerAcpRecentSessionTests();
  registerAcpSessionKeysTests();
}

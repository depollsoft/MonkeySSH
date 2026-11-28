// ignore_for_file: public_member_api_docs

import 'group_repository_cases.dart';
import 'host_repository_cases.dart';
import 'port_forward_repository_cases.dart';
import 'snippet_repository_cases.dart';
import 'ssh_key_repository_cases.dart';

/// Registers tests from repositories_test.dart.
void registerDataRepositoriesRepositoriesTests() {
  registerGroupRepositoryTests();
  registerHostRepositoryTests();
  registerPortForwardRepositoryTests();
  registerSnippetRepositoryTests();
  registerSshKeyRepositoryTests();
}

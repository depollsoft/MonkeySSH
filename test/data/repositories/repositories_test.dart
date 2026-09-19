// ignore_for_file: public_member_api_docs

import 'group_repository_cases.dart';
import 'host_repository_cases.dart';
import 'port_forward_repository_cases.dart';
import 'snippet_repository_cases.dart';
import 'ssh_key_repository_cases.dart';

void main() {
  registerGroupRepositoryTests();
  registerHostRepositoryTests();
  registerPortForwardRepositoryTests();
  registerSnippetRepositoryTests();
  registerSshKeyRepositoryTests();
}

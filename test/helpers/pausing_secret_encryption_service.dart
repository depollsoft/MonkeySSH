// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:monkeyssh/data/security/secret_encryption_service.dart';

class PausingSecretEncryptionService extends SecretEncryptionService {
  PausingSecretEncryptionService({required this.pausePlaintext})
    : super.forTesting();

  final String pausePlaintext;
  final _paused = Completer<void>();
  final _resume = Completer<void>();

  Future<void> get paused => _paused.future;

  void resume() {
    if (!_resume.isCompleted) {
      _resume.complete();
    }
  }

  @override
  Future<String?> encryptNullable(String? plaintext) async {
    if (plaintext == pausePlaintext && !_paused.isCompleted) {
      _paused.complete();
      await _resume.future;
    }
    return super.encryptNullable(plaintext);
  }
}

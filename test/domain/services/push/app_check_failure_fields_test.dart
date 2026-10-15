import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/push/push_messaging_gateway.dart';

void main() {
  FirebaseException failure(String code, String message) => FirebaseException(
    plugin: 'firebase_app_check',
    code: code,
    message: message,
  );

  test('keeps the Play Integrity error code, not the message', () {
    final fields = appCheckFailureFields(
      failure(
        'unknown',
        '-16: Integrity API error (-16): Cloud project number is invalid. '
            'Use the cloud project number 529923319565 from your app.',
      ),
    );
    expect(fields, {'code': 'unknown', 'integrityError': -16});
  });

  test('keeps the token exchange HTTP status', () {
    final fields = appCheckFailureFields(
      failure(
        'unknown',
        'Error returned from API. code: 403 body: App attestation failed.',
      ),
    );
    expect(fields, {'code': 'unknown', 'httpStatus': 403});
  });

  test('drops anything outside a short code', () {
    final fields = appCheckFailureFields(
      failure('weird code/with "quotes"', 'no numbers here'),
    );
    expect(fields, {'code': 'weirdcodewithquotes'});
  });
}

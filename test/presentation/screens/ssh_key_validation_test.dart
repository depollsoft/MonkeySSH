import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/screens/ssh_key_validation.dart';

void main() {
  test('key names validate the trimmed length', () {
    expect(validateSshKeyName(null), 'Please enter a name');
    expect(validateSshKeyName('   '), 'Please enter a name');
    expect(
      validateSshKeyName('x' * 256),
      'Name must be 255 characters or fewer',
    );
    expect(validateSshKeyName(' ${'x' * 255} '), isNull);
  });
  test('PEM validation only requires the existing envelope markers', () {
    expect(validateSshPrivateKeyPem(null), 'Please enter the private key');
    expect(validateSshPrivateKeyPem(''), 'Please enter the private key');
    for (final value in [' ', '-----BEGIN TEST-----', '-----END TEST-----']) {
      expect(validateSshPrivateKeyPem(value), 'Invalid PEM format');
    }
    expect(
      validateSshPrivateKeyPem(
        '-----BEGIN TEST FIXTURE-----\n-----END TEST FIXTURE-----',
      ),
      isNull,
    );
  });
}

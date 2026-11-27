import 'package:test/test.dart';
import 'package:xterm/src/core/input/keys.dart';
import 'package:xterm/src/core/input/keytab/keytab.dart';

void registerKeytabTests() {
  group('Keytab.find()', () {
    test('can match keyPad', () {
      final keytab = Keytab.parse(r'key Home +KeyPad : "TEST"');
      final record = keytab.find(TerminalKey.home, keyPad: true);
      expect(record!.action.unescapedValue(), 'TEST');

      final record1 = keytab.find(TerminalKey.home);
      expect(record1, isNull);
    });

    test('matches ANSI and VT52 records for the requested mode', () {
      final keytab = Keytab.parse(r'''
key Home -Ansi : "VT52"
key Home +Ansi : "ANSI"
''');

      expect(keytab.find(TerminalKey.home)!.action.unescapedValue(), 'ANSI');
      expect(
        keytab.find(TerminalKey.home, ansi: false)!.action.unescapedValue(),
        'VT52',
      );
    });

    test('default keytab exposes VT52 arrow mappings', () {
      expect(
        Keytab.defaultKeytab
            .find(TerminalKey.arrowUp, ansi: false)!
            .action
            .unescapedValue(),
        '\x1bA',
      );
      expect(
        Keytab.defaultKeytab
            .find(TerminalKey.tab, shift: true, ansi: false)!
            .action
            .unescapedValue(),
        '\t',
      );
    });
  });
}

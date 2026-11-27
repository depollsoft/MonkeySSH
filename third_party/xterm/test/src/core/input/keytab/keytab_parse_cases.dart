import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/core/input/keytab/keytab_parse.dart';
import 'package:xterm/src/core/input/keytab/keytab_token.dart';

void registerKeytabParseTests() {
  group('KeytabParser truncated input', () {
    test('keyboard declaration without a name throws ParseError', () {
      expect(
        () => KeytabParser().addTokens([
          KeytabToken(KeytabTokenType.keyboard, ''),
        ]),
        throwsA(isA<ParseError>()),
      );
    });

    test('key declaration without a key name throws ParseError', () {
      expect(
        () => KeytabParser().addTokens([
          KeytabToken(KeytabTokenType.keyDefine, ''),
        ]),
        throwsA(isA<ParseError>()),
      );
    });

    test('mode declaration without a colon throws ParseError', () {
      expect(
        () => KeytabParser().addTokens([
          KeytabToken(KeytabTokenType.keyDefine, ''),
          KeytabToken(KeytabTokenType.keyName, 'Home'),
          KeytabToken(KeytabTokenType.modeStatus, '+'),
          KeytabToken(KeytabTokenType.mode, 'Control'),
        ]),
        throwsA(isA<ParseError>()),
      );
    });

    test('key declaration without an action throws ParseError', () {
      expect(
        () => KeytabParser().addTokens([
          KeytabToken(KeytabTokenType.keyDefine, ''),
          KeytabToken(KeytabTokenType.keyName, 'Home'),
          KeytabToken(KeytabTokenType.colon, ':'),
        ]),
        throwsA(isA<ParseError>()),
      );
    });
  });
}

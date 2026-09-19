// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_json.dart';

void registerAcpJsonTests() {
  group('acp_json', () {
    test('recursively copies and freezes retained protocol JSON', () {
      final nested = <String, Object?>{'value': 1};
      final items = <Object?>[nested];
      final input = <String, Object?>{'nested': nested, 'items': items};

      final frozen = AcpJson.immutableObject(input);
      nested['value'] = 2;
      items.add('later');

      expect((frozen['nested']! as Map)['value'], 1);
      expect(frozen['items'], hasLength(1));
      expect(
        () => (frozen['nested']! as Map<String, Object?>)['value'] = 3,
        throwsUnsupportedError,
      );
      expect(
        () => (frozen['items']! as List<Object?>).add('nope'),
        throwsUnsupportedError,
      );
    });

    test('truncates provider JSON beyond the safe nesting depth', () {
      Object? nested = 'leaf';
      for (var depth = 0; depth < acpMaxJsonNestingDepth + 20; depth++) {
        nested = <Object?>[nested];
      }

      final frozen = AcpJson.immutableObject({'nested': nested});
      var cursor = frozen['nested'];
      var retainedDepth = 0;
      while (cursor is List<Object?>) {
        retainedDepth++;
        cursor = cursor.single;
      }

      expect(retainedDepth, acpMaxJsonNestingDepth);
      expect(cursor, isNull);
    });

    test('rejects provider identifiers above the retained-state bound', () {
      final maximum = 'x' * acpMaxIdentifierCharacters;
      final oversized = '$maximum!';

      expect(AcpJson.identifier({'id': maximum}, 'id'), maximum);
      expect(AcpJson.identifier({'id': oversized}, 'id'), isNull);
    });

    test('meta and extensions recursively freeze unknown data', () {
      final input = <String, Object?>{
        '_meta': <String, Object?>{
          'nested': <Object?>[
            <String, Object?>{'safe': true},
          ],
        },
        'known': 1,
        'future': <String, Object?>{
          'items': <Object?>[1, 2],
        },
      };

      final meta = AcpJson.meta(input);
      final extensions = AcpJson.extensions(input, const ['known']);

      expect(
        () => ((meta['nested']! as List).first as Map)['safe'] = false,
        throwsUnsupportedError,
      );
      expect(
        () => (extensions['future']! as Map)['items'] = const [],
        throwsUnsupportedError,
      );
    });
  });
}

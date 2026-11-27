import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/pi_model_scope_metadata_service.dart';

/// Registers tests from pi_model_scope_metadata_service_test.dart.
void registerDomainServicesPiModelScopeMetadataServiceTests() {
  group('pi_model_scope_metadata_service', () {
    group('decodePiEnabledModels', () {
      test('extracts only a valid bounded enabledModels list', () {
        final metadata = decodePiEnabledModels('''
        {
          "theme": "dark",
          "enabledModels": [" anthropic/claude-* ", "gpt-5:high"],
          "httpProxy": "not retained"
        }
      ''');

        expect(metadata.present, isTrue);
        expect(metadata.patterns, ['anthropic/claude-*', 'gpt-5:high']);
        expect(() => metadata.patterns!.add('another'), throwsUnsupportedError);
      });

      test('distinguishes an explicit empty scope from a missing field', () {
        final empty = decodePiEnabledModels('{"enabledModels": []}');
        final missing = decodePiEnabledModels('{"theme": "dark"}');

        expect(empty.present, isTrue);
        expect(empty.patterns, isEmpty);
        expect(missing.present, isFalse);
        expect(missing.patterns, isNull);
      });

      test('rejects malformed settings without retaining partial patterns', () {
        expect(decodePiEnabledModels('not json').present, isFalse);
        expect(
          decodePiEnabledModels('{"enabledModels": ["claude-*", 3]}').present,
          isFalse,
        );
      });
    });

    group('resolvePiScopedModelIds', () {
      const models = <String>[
        'anthropic/claude-sonnet-4-5',
        'anthropic/claude-sonnet-4-5-20250929',
        'openai/gpt-5',
        'openai/gpt-4o',
        'openrouter/zai/glm-5',
      ];

      test('matches provider and bare-id globs with thinking suffixes', () {
        final scoped = resolvePiScopedModelIds(
          patterns: const ['anthropic/claude-*:high', 'gpt-?', 'openrouter/**'],
          availableModelIds: models,
        );

        expect(scoped, [
          'anthropic/claude-sonnet-4-5',
          'anthropic/claude-sonnet-4-5-20250929',
          'openai/gpt-5',
          'openrouter/zai/glm-5',
        ]);
      });

      test('prefers an alias for one fuzzy non-glob pattern', () {
        final scoped = resolvePiScopedModelIds(
          patterns: const ['sonnet-4-5'],
          availableModelIds: models,
        );

        expect(scoped, ['anthropic/claude-sonnet-4-5']);
      });

      test('supports case-insensitive classes and ordered de-duplication', () {
        final scoped = resolvePiScopedModelIds(
          patterns: const ['OPENAI/gpt-[45]*', 'gpt-5', 'missing-*'],
          availableModelIds: models,
        );

        expect(scoped, ['openai/gpt-5', 'openai/gpt-4o']);
      });

      test('uses model display names for fuzzy matching', () {
        final scoped = resolvePiScopedModelIds(
          patterns: const ['Favorite'],
          availableModelIds: models,
          modelNames: const {'openai/gpt-5': 'openai/My Favorite Model'},
        );

        expect(scoped, ['openai/gpt-5']);
      });
    });
  });
}

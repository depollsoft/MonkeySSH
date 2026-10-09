// ignore_for_file: public_member_api_docs

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';

AcpLaunchCommand _command([List<String> arguments = const ['acp']]) =>
    AcpLaunchCommand(executable: 'goose', arguments: arguments);

AcpCustomProviderDefinition _goose({
  List<String> arguments = const ['acp'],
  List<String> environment = const ['GOOSE_PROVIDER'],
  AcpCustomProviderCwdPolicy cwdPolicy =
      AcpCustomProviderCwdPolicy.chosenDirectory,
}) => AcpCustomProviderDefinition.create(
  id: 'goose',
  label: 'Goose',
  launchCommand: _command(arguments),
  environmentVariableNames: environment,
  cwdPolicy: cwdPolicy,
  now: DateTime.utc(2026),
);

void main() {
  group('validators', () {
    test('custom IDs are lowercase slugs outside the built-in namespace', () {
      expect(validateAcpCustomProviderId('  gemini-cli '), 'gemini-cli');
      for (final invalid in [
        '',
        '   ',
        'builtin:goose',
        'Goose',
        'goose agent',
        '-goose',
        'goose\u0000',
        'a' * (acpCustomProviderIdMaxLength + 1),
      ]) {
        expect(
          () => validateAcpCustomProviderId(invalid),
          throwsFormatException,
          reason: invalid,
        );
      }
    });

    test('labels are trimmed, bounded and free of control characters', () {
      expect(validateAcpProviderLabel('  Goose  '), 'Goose');
      expect(() => validateAcpProviderLabel(' '), throwsFormatException);
      expect(() => validateAcpProviderLabel('Go\nose'), throwsFormatException);
      expect(
        () => validateAcpProviderLabel('a' * (acpProviderLabelMaxLength + 1)),
        throwsFormatException,
      );
    });

    test('launch commands reject blanks, controls and oversized argv', () {
      expect(
        () => validateAcpLaunchCommand(AcpLaunchCommand(executable: ' ')),
        throwsFormatException,
      );
      expect(
        () => validateAcpLaunchCommand(AcpLaunchCommand(executable: ' goose')),
        throwsFormatException,
      );
      expect(
        () => validateAcpLaunchCommand(_command(const ['ac\u0000p'])),
        throwsFormatException,
      );
      expect(
        () => validateAcpLaunchCommand(
          _command(List.filled(acpLaunchCommandMaxArgumentCount + 1, 'x')),
        ),
        throwsFormatException,
      );
      expect(
        () => validateAcpLaunchCommand(
          _command(['a' * acpLaunchCommandMaxTotalLength]),
        ),
        throwsFormatException,
      );
      expect(() => validateAcpLaunchCommand(_command()), returnsNormally);
    });

    test('environment variable names are normalized identifiers', () {
      expect(
        validateAcpEnvironmentVariableNames([' B_KEY', 'A_KEY', 'B_KEY', '']),
        ['A_KEY', 'B_KEY'],
      );
      for (final invalid in ['1KEY', 'KEY=value', 'MY-KEY', r'$KEY']) {
        expect(
          () => validateAcpEnvironmentVariableNames([invalid]),
          throwsFormatException,
          reason: invalid,
        );
      }
      expect(
        () => validateAcpEnvironmentVariableNames([
          for (var i = 0; i <= acpCustomProviderMaxEnvironmentVariables; i++)
            'KEY_$i',
        ]),
        throwsFormatException,
      );
    });
  });

  group('fingerprint', () {
    test('is a lowercase hex SHA-256 digest', () {
      expect(_goose().fingerprint, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('changes with argv, environment names and cwd policy only', () {
      final base = _goose();
      expect(_goose().fingerprint, base.fingerprint);
      expect(
        _goose(arguments: const ['acp', '--debug']).fingerprint,
        isNot(base.fingerprint),
      );
      expect(
        _goose(arguments: const ['--debug', 'acp']).fingerprint,
        isNot(_goose(arguments: const ['acp', '--debug']).fingerprint),
      );
      expect(
        _goose(environment: const ['OTHER']).fingerprint,
        isNot(base.fingerprint),
      );
      expect(
        _goose(cwdPolicy: AcpCustomProviderCwdPolicy.homeDirectory).fingerprint,
        isNot(base.fingerprint),
      );
      expect(base.edit(label: 'Renamed').fingerprint, base.fingerprint);
    });
  });

  group('approval', () {
    test('a new definition is unapproved until approved explicitly', () {
      final created = _goose();
      expect(created.isCommandApproved, isFalse);
      expect(created.approval, isNull);
      final approved = created.approve(now: DateTime.utc(2026, 2));
      expect(approved.isCommandApproved, isTrue);
      expect(approved.approval!.commandFingerprint, created.fingerprint);
      expect(approved.approval!.approvedAt, DateTime.utc(2026, 2));
    });

    test('changing what runs withdraws approval; renaming does not', () {
      final approved = _goose().approve();
      expect(
        approved
            .edit(launchCommand: _command(const ['acp', '--yolo']))
            .isCommandApproved,
        isFalse,
      );
      expect(
        approved.edit(environmentVariableNames: const []).isCommandApproved,
        isFalse,
      );
      expect(
        approved
            .edit(cwdPolicy: AcpCustomProviderCwdPolicy.homeDirectory)
            .isCommandApproved,
        isFalse,
      );
      expect(approved.edit(label: 'Goose CLI').isCommandApproved, isTrue);
    });

    test('a stored approval for another fingerprint does not authorize', () {
      final approved = _goose().approve();
      final tampered = AcpCustomProviderDefinition.tryFromJson({
        ...approved.toJson(),
        'command': ['goose', 'acp', '--extra'],
      });
      expect(tampered, isNotNull);
      expect(tampered!.isCommandApproved, isFalse);
    });
  });

  group('storage JSON', () {
    test('round-trips including approval', () {
      final approved = _goose().approve(now: DateTime.utc(2026, 3));
      final decoded = AcpCustomProviderDefinition.tryFromJson(
        jsonDecode(jsonEncode(approved.toJson())),
      );
      expect(decoded, approved);
      expect(decoded!.isCommandApproved, isTrue);
    });

    test('rejects malformed entries instead of throwing', () {
      final valid = _goose().toJson();
      for (final invalid in <Object?>[
        null,
        'goose',
        {...valid, 'id': 'builtin:goose'},
        {...valid, 'command': <String>[]},
        {...valid, 'command': 'goose acp'},
        {
          ...valid,
          'environmentVariables': {'KEY': 'secret'},
        },
        {...valid, 'workingDirectory': 'elsewhere'},
        {...valid, 'createdAt': 'yesterday'},
        {...valid, 'approval': 'yes'},
      ]) {
        expect(
          AcpCustomProviderDefinition.tryFromJson(invalid),
          isNull,
          reason: '$invalid',
        );
      }
    });

    test('decodeStoredAcpCustomProviders skips bad and repeated entries', () {
      final goose = _goose();
      final decoded = decodeStoredAcpCustomProviders([
        goose.toJson(),
        {'id': 'broken'},
        goose.toJson(),
      ]);
      expect(decoded, [goose]);
    });

    test('toString never includes the label or command', () {
      final rendered = AcpCustomProviderDefinition.create(
        id: 'secret-agent',
        label: 'Secret label',
        launchCommand: AcpLaunchCommand(
          executable: '/opt/secret/bin',
          arguments: const ['--token-file', '/tmp/x'],
        ),
      ).toString();
      expect(rendered, isNot(contains('secret')));
      expect(rendered, isNot(contains('Secret')));
      expect(rendered, isNot(contains('token')));
    });
  });

  group('export and import', () {
    test('exports carry names only, never approvals or values', () {
      final approved = _goose().approve();
      final text = encodeAcpCustomProviderExport([approved]);
      final document = jsonDecode(text) as Map<String, Object?>;
      expect(document['format'], acpCustomProviderExportFormat);
      expect(document['version'], acpCustomProviderExportVersion);
      final agent = (document['agents']! as List).single as Map;
      expect(agent, {
        'id': 'goose',
        'label': 'Goose',
        'command': ['goose', 'acp'],
        'environmentVariables': ['GOOSE_PROVIDER'],
        'workingDirectory': 'chosen',
      });
      expect(text, isNot(contains('approval')));
      expect(text, isNot(contains('commandFingerprint')));
      expect(text, isNot(contains(approved.fingerprint)));
    });

    test('imports arrive unapproved even when they claim approval', () {
      final approved = _goose().approve();
      final forged = {
        'format': acpCustomProviderExportFormat,
        'version': 1,
        'agents': [approved.toJson()],
      };
      final imported = decodeAcpCustomProviderImport(jsonEncode(forged));
      expect(imported.single.id, 'goose');
      expect(imported.single.approval, isNull);
      expect(imported.single.isCommandApproved, isFalse);
    });

    test('accepts a bare list or a single agent object', () {
      final agent = _goose().toExportJson();
      expect(decodeAcpCustomProviderImport(jsonEncode([agent])), hasLength(1));
      expect(decodeAcpCustomProviderImport(jsonEncode(agent)), hasLength(1));
    });

    test('rejects literal environment values with a clear message', () {
      final agent = {
        ..._goose().toExportJson(),
        'environmentVariables': {'OPENAI_API_KEY': 'sk-secret'},
      };
      expect(
        () => decodeAcpCustomProviderImport(jsonEncode(agent)),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('by name only'),
          ),
        ),
      );
    });

    test('rejects invalid documents with user-facing messages', () {
      for (final text in [
        'not json',
        '[]',
        '{"format": "something-else", "agents": []}',
        '{"format": "$acpCustomProviderExportFormat", "version": 99, "agents": []}',
        jsonEncode([_goose().toExportJson(), _goose().toExportJson()]),
        jsonEncode({'id': 'x', 'label': 'X'}),
      ]) {
        expect(
          () => decodeAcpCustomProviderImport(text),
          throwsFormatException,
          reason: text,
        );
      }
    });
  });

  group('mergeImportedAcpCustomProviders', () {
    final approvedLocal = _goose().approve();
    final other = AcpCustomProviderDefinition.create(
      id: 'kimi',
      label: 'Kimi',
      launchCommand: AcpLaunchCommand(
        executable: 'kimi',
        arguments: const ['acp'],
      ),
    ).approve();

    test('keeps approval only for an identical, locally approved launch', () {
      final sameImport = decodeAcpCustomProviderImport(
        encodeAcpCustomProviderExport([approvedLocal.edit(label: 'Renamed')]),
      );
      final merged = mergeImportedAcpCustomProviders(
        local: [approvedLocal],
        imported: sameImport,
        keepUnmatchedLocal: true,
      );
      expect(merged.single.label, 'Renamed');
      expect(merged.single.isCommandApproved, isTrue);
    });

    test('a changed import replaces the local one unapproved', () {
      final changed = decodeAcpCustomProviderImport(
        encodeAcpCustomProviderExport([
          approvedLocal.edit(launchCommand: _command(const ['acp', '--x'])),
        ]),
      );
      final merged = mergeImportedAcpCustomProviders(
        local: [approvedLocal, other],
        imported: changed,
        keepUnmatchedLocal: true,
      );
      expect(merged.map((definition) => definition.id), ['goose', 'kimi']);
      expect(merged.first.isCommandApproved, isFalse);
      expect(merged.last.isCommandApproved, isTrue);
    });

    test('drops forged approvals and unmatched local entries on replace', () {
      final forged = AcpCustomProviderDefinition.tryFromJson({
        ...approvedLocal.toJson(),
        'id': 'forged',
      })!;
      expect(forged.isCommandApproved, isTrue);
      final merged = mergeImportedAcpCustomProviders(
        local: [other],
        imported: [forged],
        keepUnmatchedLocal: false,
      );
      expect(merged.single.id, 'forged');
      expect(merged.single.isCommandApproved, isFalse);
    });
  });

  test('built-in providers are not custom', () {
    for (final provider in acpBuiltinProviders) {
      expect(provider.isCustom, isFalse);
    }
    expect(_goose().isCustom, isTrue);
  });
}

// ignore_for_file: public_member_api_docs

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/services/acp_provider_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

void main() {
  late AppDatabase database;
  late SettingsService settings;
  late AcpCustomProviderService service;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    settings = SettingsService(database);
    service = AcpCustomProviderService(
      settings,
      clock: () => DateTime.utc(2026, 10, 9),
    );
  });

  tearDown(() => database.close());

  Future<AcpCustomProviderDefinition> addGoose({
    List<String> environment = const ['GOOSE_PROVIDER'],
  }) => service.create(
    label: 'Goose',
    launchCommand: AcpLaunchCommand(
      executable: 'goose',
      arguments: const ['acp'],
    ),
    environmentVariableNames: environment,
  );

  test('creates unapproved definitions with unique slug IDs', () async {
    final first = await addGoose();
    final second = await addGoose();
    expect(first.id, 'goose');
    expect(second.id, 'goose-2');
    expect(first.isCommandApproved, isFalse);
    expect(await service.listCustomProviders(), [first, second]);
  });

  test('suggestAcpCustomProviderId falls back and trims', () {
    expect(suggestAcpCustomProviderId('Gemini CLI!', {}), 'gemini-cli');
    expect(suggestAcpCustomProviderId('🙈', {}), 'agent');
    expect(suggestAcpCustomProviderId('agent', {'agent'}), 'agent-2');
    // Never an ID MonkeyMux would read as a built-in agent.
    expect(suggestAcpCustomProviderId('Pi ACP', {}), 'pi-acp-2');
    expect(suggestAcpCustomProviderId('OpenCode', {}), 'opencode-2');
  });

  test('approve requires the reviewed fingerprint to still match', () async {
    final created = await addGoose();
    final approved = await service.approve(
      created.id,
      reviewedFingerprint: created.fingerprint,
    );
    expect(approved.isCommandApproved, isTrue);

    await expectLater(
      service.approve(created.id, reviewedFingerprint: 'stale'),
      throwsA(isA<AcpCustomProviderException>()),
    );
  });

  test('changing the command or the name of an approved definition requires '
      're-approval', () async {
    final created = await addGoose();
    await service.approve(created.id, reviewedFingerprint: created.fingerprint);

    final renamed = await service.update(
      created.id,
      label: 'Goose CLI',
      launchCommand: created.launchCommand,
      environmentVariableNames: created.environmentVariableNames,
      cwdPolicy: created.cwdPolicy,
    );
    expect(renamed.isCommandApproved, isFalse);
    await service.approve(created.id, reviewedFingerprint: renamed.fingerprint);

    final changed = await service.update(
      created.id,
      label: 'Goose CLI',
      launchCommand: AcpLaunchCommand(
        executable: 'goose',
        arguments: const ['acp', '--with-builtin', 'developer'],
      ),
      environmentVariableNames: created.environmentVariableNames,
      cwdPolicy: created.cwdPolicy,
    );
    expect(changed.isCommandApproved, isFalse);
    expect(
      (await service.getCustomProvider(created.id))!.isCommandApproved,
      isFalse,
    );
  });

  test('rejects invalid fields as user-facing exceptions', () async {
    await expectLater(
      service.create(
        label: 'Bad',
        launchCommand: AcpLaunchCommand(executable: 'agent'),
        environmentVariableNames: ['NOT-A-NAME'],
      ),
      throwsA(isA<AcpCustomProviderException>()),
    );
    await expectLater(
      service.create(
        label: ' ',
        launchCommand: AcpLaunchCommand(executable: 'agent'),
      ),
      throwsA(isA<AcpCustomProviderException>()),
    );
    expect(await service.listCustomProviders(), isEmpty);
  });

  test('rejects a command the bridge would refuse once quoted', () async {
    // 4,000 apostrophes pass the raw length limit but quote to about 16 KiB.
    await expectLater(
      service.create(
        label: 'Quotes',
        launchCommand: AcpLaunchCommand(
          executable: 'agent',
          arguments: ["'" * 4000],
        ),
      ),
      throwsA(
        isA<AcpCustomProviderException>().having(
          (error) => error.message,
          'message',
          contains('too long to launch'),
        ),
      ),
    );
    expect(await service.listCustomProviders(), isEmpty);
  });

  test('a relabelled import of an approved agent needs approval', () async {
    final created = await addGoose();
    await service.approve(created.id, reviewedFingerprint: created.fingerprint);
    final document = jsonDecode(await service.export()) as Map<String, Object?>;
    ((document['agents']! as List).single as Map)['label'] =
        r"Goose\'; touch /tmp/pwned; #";

    final result = await service.import(jsonEncode(document));

    expect(result.replaced, 1);
    expect(result.needsApproval, 1);
    final stored = (await service.getCustomProvider(created.id))!;
    expect(stored.label, r"Goose\'; touch /tmp/pwned; #");
    expect(stored.isCommandApproved, isFalse);
  });

  test('stores environment variable names only', () async {
    await addGoose(environment: ['OPENAI_API_KEY']);
    final raw = await settings.getString(SettingKeys.acpCustomProviders);
    final stored = (jsonDecode(raw!) as List).single as Map;
    expect(stored['environmentVariables'], ['OPENAI_API_KEY']);
  });

  test('exports never contain approvals or environment values', () async {
    final created = await addGoose(environment: ['OPENAI_API_KEY']);
    await service.approve(created.id, reviewedFingerprint: created.fingerprint);

    final text = await service.export();
    expect(text, contains('OPENAI_API_KEY'));
    expect(text, isNot(contains('approval')));
    expect(text, isNot(contains(created.fingerprint)));
    final agent = ((jsonDecode(text) as Map)['agents'] as List).single as Map;
    expect(agent['environmentVariables'], ['OPENAI_API_KEY']);
  });

  test('imports require approval, except for an unchanged approved '
      'definition', () async {
    final created = await addGoose();
    await service.approve(created.id, reviewedFingerprint: created.fingerprint);
    final exported = await service.export();

    final unchanged = await service.import(exported);
    expect(unchanged.replaced, 1);
    expect(unchanged.needsApproval, 0);
    expect(
      (await service.getCustomProvider('goose'))!.isCommandApproved,
      isTrue,
    );

    final changedDocument = (jsonDecode(exported) as Map<String, Object?>)
      ..['agents'] = [
        {
          'id': 'goose',
          'label': 'Goose',
          'command': ['goose', 'acp', '--extra'],
        },
        {
          'id': 'kimi',
          'label': 'Kimi',
          'command': ['kimi', 'acp'],
        },
      ];
    final changed = await service.import(jsonEncode(changedDocument));
    expect(changed.added, 1);
    expect(changed.replaced, 1);
    expect(changed.needsApproval, 2);
    final stored = await service.listCustomProviders();
    expect(stored.map((definition) => definition.id), ['goose', 'kimi']);
    expect(stored.every((definition) => !definition.isCommandApproved), isTrue);
  });

  test('invalid imports change nothing', () async {
    await addGoose();
    await expectLater(
      service.import('{"agents": [{"id": "x"}]}'),
      throwsA(isA<AcpCustomProviderException>()),
    );
    expect(await service.listCustomProviders(), hasLength(1));
  });

  test('delete removes the definition', () async {
    final created = await addGoose();
    await service.delete(created.id);
    expect(await service.listCustomProviders(), isEmpty);
    expect(await settings.getString(SettingKeys.acpCustomProviders), isNull);
  });

  test('acpProvidersProvider lists built-ins then approved custom '
      'agents only', () async {
    final container = ProviderContainer(
      overrides: [settingsServiceProvider.overrideWithValue(settings)],
    );
    addTearDown(container.dispose);
    final approved = await addGoose();
    await service.approve(
      approved.id,
      reviewedFingerprint: approved.fingerprint,
    );
    await service.create(
      label: 'Pending',
      launchCommand: AcpLaunchCommand(executable: 'pending'),
    );

    // A stream provider only runs while something listens to it.
    container.listen(acpProvidersProvider, (_, _) {});
    final providers = await container.read(acpProvidersProvider.future);
    expect(
      providers.take(acpBuiltinProviders.length),
      orderedEquals(acpBuiltinProviders),
    );
    expect(
      providers.skip(acpBuiltinProviders.length).map((provider) => provider.id),
      ['goose'],
    );
  });
}

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
  late AcpProviderService service;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    settings = SettingsService(database);
    service = AcpProviderService(settings);
  });

  tearDown(() async {
    await database.close();
  });

  test('builtinProviders returns Copilot CLI and OpenCode', () {
    expect(service.builtinProviders, acpBuiltinProviders);
  });

  test('listCustomProviders is empty when nothing is stored', () async {
    expect(await service.listCustomProviders(), isEmpty);
  });

  group('malformed storage', () {
    test('returns an empty list for invalid JSON', () async {
      await settings.setString(
        SettingKeys.acpCustomProviders,
        '{not valid json',
      );
      expect(await service.listCustomProviders(), isEmpty);
    });

    test('returns an empty list when the JSON is not a list', () async {
      await settings.setJson(SettingKeys.acpCustomProviders, {'foo': 'bar'});
      expect(await service.listCustomProviders(), isEmpty);
    });

    test('skips malformed entries but keeps valid ones', () async {
      final valid = AcpCustomProviderDefinition.create(
        id: 'valid-agent',
        label: 'Valid Agent',
        launchCommand: AcpLaunchCommand(executable: 'valid-agent'),
      );
      await settings.setString(
        SettingKeys.acpCustomProviders,
        jsonEncode([
          valid.toJson(),
          {'id': 'broken'},
          'not-a-map',
        ]),
      );

      final loaded = await service.listCustomProviders();
      expect(loaded, hasLength(1));
      expect(loaded.single, valid);
    });
  });

  group('persisted definitions', () {
    test('listCustomProviders preserves stored order', () async {
      final first = AcpCustomProviderDefinition.create(
        id: 'first',
        label: 'First',
        launchCommand: AcpLaunchCommand(executable: 'first'),
      );
      final second = AcpCustomProviderDefinition.create(
        id: 'second',
        label: 'Second',
        launchCommand: AcpLaunchCommand(executable: 'second'),
      );

      await settings.setString(
        SettingKeys.acpCustomProviders,
        jsonEncode([first.toJson(), second.toJson()]),
      );

      final loaded = await service.listCustomProviders();
      expect(loaded.map((d) => d.id).toList(), ['first', 'second']);
    });

    test('getCustomProvider returns a matching entry or null', () async {
      final first = AcpCustomProviderDefinition.create(
        id: 'first',
        label: 'First',
        launchCommand: AcpLaunchCommand(executable: 'first'),
      );
      await settings.setString(
        SettingKeys.acpCustomProviders,
        jsonEncode([first.toJson()]),
      );

      expect(await service.getCustomProvider('first'), first);
      expect(await service.getCustomProvider('missing'), isNull);
    });
  });

  group('combined provider loading', () {
    test('lists built-ins before persisted custom providers', () async {
      final custom = AcpCustomProviderDefinition.create(
        id: 'custom-agent',
        label: 'Custom Agent',
        launchCommand: AcpLaunchCommand(executable: 'custom-agent'),
      );
      await settings.setString(
        SettingKeys.acpCustomProviders,
        jsonEncode([custom.toJson()]),
      );

      final all = await service.watchAllProviders().first;
      expect(all, hasLength(acpBuiltinProviders.length + 1));
      expect(
        all.take(acpBuiltinProviders.length).map((p) => p.id),
        acpBuiltinProviders.map((p) => p.id),
      );
      expect(all.last.id, custom.id);
      expect(all.last.isCustom, isTrue);
    });
  });

  group('watchAllProviders', () {
    test('emits built-ins immediately, then refreshes after add, edit, and '
        'remove without any manual invalidation', () async {
      final emissions = <List<AcpProvider>>[];
      final subscription = service.watchAllProviders().listen(emissions.add);
      addTearDown(subscription.cancel);

      await pumpEventQueue();
      expect(emissions, hasLength(1));
      expect(
        emissions.single.map((p) => p.id),
        acpBuiltinProviders.map((p) => p.id),
      );

      final added = AcpCustomProviderDefinition.create(
        id: 'agent-1',
        label: 'Agent One',
        launchCommand: AcpLaunchCommand(executable: 'agent-1'),
      );
      await settings.setString(
        SettingKeys.acpCustomProviders,
        jsonEncode([added.toJson()]),
      );
      await pumpEventQueue();
      expect(emissions, hasLength(2));
      expect(emissions.last.map((p) => p.id).last, 'agent-1');
      expect(emissions.last.last.label, 'Agent One');

      final edited = AcpCustomProviderDefinition.tryFromJson({
        ...added.toJson(),
        'label': 'Agent One Renamed',
      })!;
      await settings.setString(
        SettingKeys.acpCustomProviders,
        jsonEncode([edited.toJson()]),
      );
      await pumpEventQueue();
      expect(emissions, hasLength(3));
      expect(emissions.last.last.label, 'Agent One Renamed');

      await settings.delete(SettingKeys.acpCustomProviders);
      await pumpEventQueue();
      expect(emissions, hasLength(4));
      expect(
        emissions.last.map((p) => p.id),
        acpBuiltinProviders.map((p) => p.id),
      );
    });

    test('recovers to an empty custom list after malformed storage', () async {
      final emissions = <List<AcpProvider>>[];
      final subscription = service.watchAllProviders().listen(emissions.add);
      addTearDown(subscription.cancel);
      await pumpEventQueue();

      await settings.setString(
        SettingKeys.acpCustomProviders,
        '{not valid json',
      );
      await pumpEventQueue();

      expect(
        emissions.last.map((p) => p.id),
        acpBuiltinProviders.map((p) => p.id),
      );
    });
  });

  group('acpProvidersProvider', () {
    late AppDatabase providerDb;
    late ProviderContainer container;

    setUp(() {
      providerDb = AppDatabase.forTesting(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(providerDb)],
      );
    });

    tearDown(() async {
      container.dispose();
      await providerDb.close();
    });

    test('refreshes automatically after add, edit, and remove without the '
        'caller manually invalidating the provider', () async {
      final emissions = <AsyncValue<List<AcpProvider>>>[];
      final subscription = container.listen(
        acpProvidersProvider,
        (previous, next) => emissions.add(next),
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      await container.read(acpProvidersProvider.future);
      expect(
        emissions.last.value!.map((p) => p.id),
        acpBuiltinProviders.map((p) => p.id),
      );

      final providerSettings = container.read(settingsServiceProvider);
      final added = AcpCustomProviderDefinition.create(
        id: 'agent-1',
        label: 'Agent One',
        launchCommand: AcpLaunchCommand(executable: 'agent-1'),
      );
      await providerSettings.setString(
        SettingKeys.acpCustomProviders,
        jsonEncode([added.toJson()]),
      );
      await pumpEventQueue();
      expect(emissions.last.value!.map((p) => p.id).last, 'agent-1');

      final edited = AcpCustomProviderDefinition.tryFromJson({
        ...added.toJson(),
        'label': 'Agent One Renamed',
      })!;
      await providerSettings.setString(
        SettingKeys.acpCustomProviders,
        jsonEncode([edited.toJson()]),
      );
      await pumpEventQueue();
      expect(emissions.last.value!.last.label, 'Agent One Renamed');

      await providerSettings.delete(SettingKeys.acpCustomProviders);
      await pumpEventQueue();
      expect(
        emissions.last.value!.map((p) => p.id),
        acpBuiltinProviders.map((p) => p.id),
      );
    });
  });
}

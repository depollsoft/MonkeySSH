// ignore_for_file: public_member_api_docs

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/host_cli_launch_preferences.dart';
import 'package:monkeyssh/domain/services/host_cli_launch_preferences_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

void main() {
  late AppDatabase database;
  late HostCliLaunchPreferencesService service;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    service = HostCliLaunchPreferencesService(SettingsService(database));
  });

  tearDown(() async {
    await database.close();
  });

  test(
    'concurrent saves across service instances preserve both hosts',
    () async {
      final otherService = HostCliLaunchPreferencesService(
        SettingsService(database),
      );
      const preferences = HostCliLaunchPreferences(startInYoloMode: true);

      await Future.wait([
        service.setPreferencesForHost(1, preferences),
        otherService.setPreferencesForHost(2, preferences),
      ]);

      expect((await service.getPreferencesForHost(1)).startInYoloMode, isTrue);
      expect((await service.getPreferencesForHost(2)).startInYoloMode, isTrue);
    },
  );

  test(
    'concurrent delete and save do not restore deleted preferences',
    () async {
      const preferences = HostCliLaunchPreferences(startInYoloMode: true);
      await service.setPreferencesForHost(1, preferences);
      await service.setPreferencesForHost(2, preferences);

      await Future.wait([
        service.deletePreferencesForHost(1),
        service.setPreferencesForHost(3, preferences),
      ]);

      expect((await service.getPreferencesForHost(1)).isEmpty, isTrue);
      expect((await service.getPreferencesForHost(2)).startInYoloMode, isTrue);
      expect((await service.getPreferencesForHost(3)).startInYoloMode, isTrue);
    },
  );

  test('stores and loads host CLI launch preferences', () async {
    const preferences = HostCliLaunchPreferences(startInYoloMode: true);

    await service.setPreferencesForHost(42, preferences);
    final loaded = await service.getPreferencesForHost(42);

    expect(loaded.startInYoloMode, isTrue);
  });

  test(
    'returns default preferences when a host has no saved overrides',
    () async {
      final loaded = await service.getPreferencesForHost(7);

      expect(loaded.startInYoloMode, isFalse);
      expect(loaded.isEmpty, isTrue);
    },
  );

  test('deletes stored preferences when saved settings are empty', () async {
    await service.setPreferencesForHost(
      7,
      const HostCliLaunchPreferences(startInYoloMode: true),
    );
    await service.setPreferencesForHost(7, const HostCliLaunchPreferences());

    final loaded = await service.getPreferencesForHost(7);
    expect(loaded.startInYoloMode, isFalse);
    expect(loaded.isEmpty, isTrue);
  });
}

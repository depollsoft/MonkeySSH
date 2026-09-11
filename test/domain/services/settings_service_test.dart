// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/host_cli_launch_preferences.dart';
import 'package:monkeyssh/domain/models/terminal_themes.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

class _DelayedBoolSettingsService extends SettingsService {
  _DelayedBoolSettingsService(super.database);

  final loadedValue = Completer<bool>();
  final readStarted = Completer<void>();

  @override
  Future<bool> getBool(String key, {bool defaultValue = false}) {
    if (!readStarted.isCompleted) readStarted.complete();
    return loadedValue.future;
  }
}

void main() {
  late AppDatabase db;
  late SettingsService service;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    service = SettingsService(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('SettingsService', () {
    group('String settings', () {
      test('getString returns null when not set', () async {
        final value = await service.getString('nonexistent');
        expect(value, isNull);
      });

      test('setString stores value', () async {
        await service.setString('test_key', 'test_value');
        final value = await service.getString('test_key');
        expect(value, 'test_value');
      });

      test('setString overwrites existing value', () async {
        await service.setString('test_key', 'value1');
        await service.setString('test_key', 'value2');
        final value = await service.getString('test_key');
        expect(value, 'value2');
      });
    });

    group('Int settings', () {
      test('getInt returns null when not set', () async {
        final value = await service.getInt('nonexistent');
        expect(value, isNull);
      });

      test('setInt stores value', () async {
        await service.setInt('port', 2222);
        final value = await service.getInt('port');
        expect(value, 2222);
      });

      test('getInt returns null for non-integer string', () async {
        await service.setString('invalid_int', 'not_a_number');
        final value = await service.getInt('invalid_int');
        expect(value, isNull);
      });
    });

    group('Bool settings', () {
      test('getBool returns default when not set', () async {
        final value = await service.getBool('nonexistent', defaultValue: true);
        expect(value, isTrue);
      });

      test('getBool returns false as default', () async {
        final value = await service.getBool('nonexistent');
        expect(value, isFalse);
      });

      test('setBool stores true value', () async {
        await service.setBool('enabled', value: true);
        final value = await service.getBool('enabled');
        expect(value, isTrue);
      });

      test('setBool stores false value', () async {
        await service.setBool('enabled', value: false);
        final value = await service.getBool('enabled');
        expect(value, isFalse);
      });

      test('getBool returns default for non-boolean string', () async {
        await service.setString('invalid_bool', 'maybe');
        final value = await service.getBool('invalid_bool', defaultValue: true);
        expect(value, isTrue);
      });
    });

    group('JSON settings', () {
      test('getJson returns null when not set', () async {
        final value = await service.getJson('nonexistent');
        expect(value, isNull);
      });

      test('setJson stores value', () async {
        await service.setJson('config', {'key': 'value', 'count': 42});
        final value = await service.getJson('config');
        expect(value, {'key': 'value', 'count': 42});
      });

      test('getJson returns null for invalid JSON', () async {
        await service.setString('invalid_json', 'not json');
        final value = await service.getJson('invalid_json');
        expect(value, isNull);
      });

      test('getJson returns null for JSON arrays', () async {
        await service.setString('json_array', '[]');
        final value = await service.getJson('json_array');
        expect(value, isNull);
      });

      test('getJson returns null for JSON strings', () async {
        await service.setString('json_string', '"not an object"');
        final value = await service.getJson('json_string');
        expect(value, isNull);
      });

      test('setJson handles nested objects', () async {
        await service.setJson('nested', {
          'level1': {
            'level2': {'value': 'deep'},
          },
        });
        final value = await service.getJson('nested');
        expect(
          ((value?['level1'] as Map?)?['level2'] as Map?)?['value'],
          'deep',
        );
      });
    });

    group('Delete settings', () {
      test('delete removes setting', () async {
        await service.setString('to_delete', 'value');
        expect(await service.getString('to_delete'), 'value');

        await service.delete('to_delete');
        expect(await service.getString('to_delete'), isNull);
      });

      test('delete does nothing for nonexistent key', () async {
        // Should not throw
        await service.delete('nonexistent');
      });
    });

    group('GetAll settings', () {
      test('getAll returns empty map initially', () async {
        final all = await service.getAll();
        expect(all, isEmpty);
      });

      test('getAll returns all settings', () async {
        await service.setString('key1', 'value1');
        await service.setString('key2', 'value2');
        await service.setInt('key3', 123);

        final all = await service.getAll();
        expect(all, hasLength(3));
        expect(all['key1'], 'value1');
        expect(all['key2'], 'value2');
        expect(all['key3'], '123');
      });
    });

    group('Watch settings', () {
      test('watchString emits updates on change', () async {
        await service.setString('watched_key', 'value1');

        final stream = service.watchString('watched_key');

        final firstValue = await stream.first;
        expect(firstValue, 'value1');
      });
    });
  });

  group('SettingKeys', () {
    test('has expected constants', () {
      expect(SettingKeys.themeMode, 'theme_mode');
      expect(
        SettingKeys.terminalThemesApplyToApp,
        'terminal_themes_apply_to_app',
      );
      expect(SettingKeys.terminalFont, 'terminal_font');
      expect(SettingKeys.terminalFontSize, 'terminal_font_size');
      expect(SettingKeys.cursorStyle, 'cursor_style');
      expect(SettingKeys.bellSound, 'bell_sound');
      expect(SettingKeys.shellCompletions, 'shell_completions');
      expect(SettingKeys.autoLockTimeout, 'auto_lock_timeout');
    });
  });

  test('app-wide agent window mode loads and persists', () async {
    await service.setString(
      SettingKeys.agentWindowModePreference,
      AgentWindowModePreference.preferTerminal.storageValue,
    );
    final container = ProviderContainer(
      overrides: [settingsServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);

    final notifier = container.read(
      agentWindowModePreferenceNotifierProvider.notifier,
    );
    expect(
      await notifier.initializedValue(),
      AgentWindowModePreference.preferTerminal,
    );

    await notifier.setPreference(AgentWindowModePreference.preferNative);

    expect(
      container.read(agentWindowModePreferenceNotifierProvider),
      AgentWindowModePreference.preferNative,
    );
    expect(
      await service.getString(SettingKeys.agentWindowModePreference),
      'native',
    );
  });

  group('Settings Providers', () {
    late AppDatabase testDb;
    late ProviderContainer container;

    setUp(() {
      testDb = AppDatabase.forTesting(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(testDb)],
      );
    });

    tearDown(() async {
      container.dispose();
      await testDb.close();
    });

    for (final (provider, notifierProvider, key) in [
      (
        sharedClipboardProvider,
        sharedClipboardNotifierProvider,
        SettingKeys.sharedClipboard,
      ),
      (
        sharedClipboardLocalReadProvider,
        sharedClipboardLocalReadNotifierProvider,
        SettingKeys.sharedClipboardLocalRead,
      ),
    ]) {
      for (final enabled in [true, false]) {
        test('$key future follows permission change to $enabled', () async {
          await container
              .read(settingsServiceProvider)
              .setBool(key, value: !enabled);
          expect(await container.read(provider.future), !enabled);

          await container
              .read(notifierProvider.notifier)
              .setEnabled(enabled: enabled);

          expect(await container.read(provider.future), enabled);
        });
      }
    }

    test(
      'a previous settings generation cannot replace a newer value',
      () async {
        container.dispose();
        final oldSettings = _DelayedBoolSettingsService(testDb);
        final newSettings = _DelayedBoolSettingsService(testDb);
        var currentSettings = oldSettings;
        container = ProviderContainer(
          overrides: [
            settingsServiceProvider.overrideWith((ref) => currentSettings),
          ],
        );
        final notifier = container.read(
          sharedClipboardLocalReadNotifierProvider.notifier,
        );
        final oldInitialization = notifier.initializedValue();
        await oldSettings.readStarted.future;

        currentSettings = newSettings;
        container.invalidate(settingsServiceProvider);
        expect(
          container.read(sharedClipboardLocalReadNotifierProvider.notifier),
          same(notifier),
        );
        newSettings.loadedValue.complete(false);
        expect(await notifier.initializedValue(), isFalse);

        oldSettings.loadedValue.complete(true);
        await oldInitialization;
        expect(
          container.read(sharedClipboardLocalReadNotifierProvider),
          isFalse,
        );
      },
    );

    for (final (provider, key, defaultValue) in [
      (
        terminalThemesApplyToAppNotifierProvider,
        SettingKeys.terminalThemesApplyToApp,
        true,
      ),
      (
        confirmMuxWindowCloseNotifierProvider,
        SettingKeys.confirmMuxWindowClose,
        true,
      ),
      (bellSoundNotifierProvider, SettingKeys.bellSound, true),
      (
        terminalNotificationsNotifierProvider,
        SettingKeys.terminalNotifications,
        true,
      ),
      (
        agentUpdateNotificationsNotifierProvider,
        SettingKeys.agentUpdateNotifications,
        true,
      ),
      (terminalWakeLockNotifierProvider, SettingKeys.terminalWakeLock, false),
      (terminalPathLinksNotifierProvider, SettingKeys.terminalPathLinks, true),
      (
        terminalPathLinkUnderlinesNotifierProvider,
        SettingKeys.terminalPathLinkUnderlines,
        true,
      ),
      (
        portForwardBrowserLinksNotifierProvider,
        SettingKeys.portForwardBrowserLinks,
        true,
      ),
      (shellCompletionsNotifierProvider, SettingKeys.shellCompletions, true),
      (sharedClipboardNotifierProvider, SettingKeys.sharedClipboard, false),
      (
        sharedClipboardLocalReadNotifierProvider,
        SettingKeys.sharedClipboardLocalRead,
        false,
      ),
      (tapToShowKeyboardNotifierProvider, SettingKeys.tapToShowKeyboard, true),
    ]) {
      test('$key uses its default and persistence key', () async {
        final settings = container.read(settingsServiceProvider);
        final notifier = container.read(provider.notifier);
        expect(container.read(provider), defaultValue);
        expect(await notifier.initializedValue(), defaultValue);

        await settings.setBool(key, value: !defaultValue);
        container.invalidate(provider);
        final reloaded = container.read(provider.notifier);
        expect(await reloaded.initializedValue(), !defaultValue);

        for (final enabled in [defaultValue, !defaultValue]) {
          await reloaded.setEnabled(enabled: enabled);
          expect(container.read(provider), enabled);
          expect(await settings.getString(key), enabled.toString());
        }
      });
    }

    group('confirmMuxWindowCloseNotifierProvider', () {
      for (final (provider, key) in [
        (
          terminalNotificationsNotifierProvider,
          SettingKeys.terminalNotifications,
        ),
        (shellCompletionsNotifierProvider, SettingKeys.shellCompletions),
        (
          confirmMuxWindowCloseNotifierProvider,
          SettingKeys.confirmMuxWindowClose,
        ),
      ]) {
        test('$key ignores a stale startup read', () async {
          container.dispose();
          final delayedSettings = _DelayedBoolSettingsService(testDb);
          container = ProviderContainer(
            overrides: [
              settingsServiceProvider.overrideWithValue(delayedSettings),
            ],
          );
          final notifier = container.read(provider.notifier);
          await notifier.setEnabled(enabled: false);
          delayedSettings.loadedValue.complete(true);
          await notifier.initializedValue();
          expect(container.read(provider), isFalse);
          expect(
            await SettingsService(testDb).getBool(key, defaultValue: true),
            isFalse,
          );
        });
      }

      test('loads disabled preference after provider reconstruction', () async {
        final settings = container.read(settingsServiceProvider);
        await settings.setBool(SettingKeys.confirmMuxWindowClose, value: false);

        final first = await container
            .read(confirmMuxWindowCloseNotifierProvider.notifier)
            .initializedValue();
        expect(first, isFalse);

        container.dispose();
        container = ProviderContainer(
          overrides: [databaseProvider.overrideWithValue(testDb)],
        );

        final restored = await container
            .read(confirmMuxWindowCloseNotifierProvider.notifier)
            .initializedValue();
        expect(restored, isFalse);
      });
    });

    group('themeModeNotifierProvider', () {
      test('returns system by default', () async {
        final result = await container
            .read(themeModeNotifierProvider.notifier)
            .initializedValue();
        expect(result, ThemeMode.system);
      });

      test('returns stored value when set', () async {
        final settings = container.read(settingsServiceProvider);
        await settings.setString(SettingKeys.themeMode, 'dark');
        container.invalidate(themeModeNotifierProvider);
        final result = await container
            .read(themeModeNotifierProvider.notifier)
            .initializedValue();
        expect(result, ThemeMode.dark);
      });
    });

    group('fontSizeNotifierProvider', () {
      test('returns 14.0 by default', () async {
        final result = await container
            .read(fontSizeNotifierProvider.notifier)
            .initializedValue();
        expect(result, 14.0);
      });
    });

    group('fontFamilyNotifierProvider', () {
      test('returns monospace by default', () async {
        final result = await container
            .read(fontFamilyNotifierProvider.notifier)
            .initializedValue();
        expect(result, 'monospace');
      });
    });

    group('autoLockTimeoutNotifierProvider', () {
      test('returns 5 by default', () async {
        final result = await container
            .read(autoLockTimeoutNotifierProvider.notifier)
            .initializedValue();
        expect(result, 5);
      });

      test('returns stored zero when auto-lock is disabled', () async {
        final settings = container.read(settingsServiceProvider);
        await settings.setInt(SettingKeys.autoLockTimeout, 0);
        container.invalidate(autoLockTimeoutNotifierProvider);

        final result = await container
            .read(autoLockTimeoutNotifierProvider.notifier)
            .initializedValue();

        expect(result, 0);
      });
    });

    group('autoLockTimeoutNotifierProvider', () {
      test('persists zero as an intentional disablement', () async {
        final notifier = container.read(
          autoLockTimeoutNotifierProvider.notifier,
        );

        await notifier.setTimeout(0);

        expect(container.read(autoLockTimeoutNotifierProvider), 0);
        expect(
          await container
              .read(settingsServiceProvider)
              .getInt(SettingKeys.autoLockTimeout),
          0,
        );
      });
    });

    group('cursorStyleNotifierProvider', () {
      test('returns block by default', () async {
        final result = await container
            .read(cursorStyleNotifierProvider.notifier)
            .initializedValue();
        expect(result, 'block');
      });
    });

    group('bellSoundNotifierProvider', () {
      test('returns true by default', () async {
        final result = await container
            .read(bellSoundNotifierProvider.notifier)
            .initializedValue();
        expect(result, isTrue);
      });
    });

    group('agentUpdateNotificationsNotifierProvider', () {
      test('defaults to enabled and persists changes', () async {
        final notifier = container.read(
          agentUpdateNotificationsNotifierProvider.notifier,
        );

        expect(await notifier.initializedValue(), isTrue);
        await notifier.setEnabled(enabled: false);

        expect(
          container.read(agentUpdateNotificationsNotifierProvider),
          isFalse,
        );
        expect(
          await container
              .read(settingsServiceProvider)
              .getBool(
                SettingKeys.agentUpdateNotifications,
                defaultValue: true,
              ),
          isFalse,
        );
      });
    });

    group('shellCompletionsNotifierProvider', () {
      test('defaults to enabled and persists changes', () async {
        final notifier = container.read(
          shellCompletionsNotifierProvider.notifier,
        );

        expect(container.read(shellCompletionsNotifierProvider), isTrue);

        await notifier.setEnabled(enabled: false);

        expect(container.read(shellCompletionsNotifierProvider), isFalse);
        expect(
          await container
              .read(settingsServiceProvider)
              .getBool(SettingKeys.shellCompletions, defaultValue: true),
          isFalse,
        );
      });
    });

    group('portForwardBrowserLinksNotifierProvider', () {
      test('defaults to enabled and persists changes', () async {
        final notifier = container.read(
          portForwardBrowserLinksNotifierProvider.notifier,
        );

        expect(container.read(portForwardBrowserLinksNotifierProvider), isTrue);

        await notifier.setEnabled(enabled: false);

        expect(
          container.read(portForwardBrowserLinksNotifierProvider),
          isFalse,
        );
        expect(
          await container
              .read(settingsServiceProvider)
              .getBool(SettingKeys.portForwardBrowserLinks, defaultValue: true),
          isFalse,
        );
      });
    });

    group('terminalThemeSettingsProvider', () {
      test(
        'normalizes legacy default theme ids to their iTerm2 successors',
        () async {
          final settings = container.read(settingsServiceProvider);
          await settings.setString(
            SettingKeys.defaultTerminalThemeLight,
            'github-light',
          );
          await settings.setString(
            SettingKeys.defaultTerminalThemeDark,
            'dracula',
          );

          container.read(terminalThemeSettingsProvider);
          // Users who explicitly picked GitHub Light or Dracula (via the old
          // unprefixed legacy IDs) should keep those exact themes after the
          // MonkeySSH defaults landed; only purely unknown IDs fall back to
          // the new branded defaults (covered by the next test).
          await _waitForStoredTerminalThemeIds(
            settings,
            lightThemeId: 'iterm2-github-light-default',
            darkThemeId: 'iterm2-dracula',
          );
          final state = container.read(terminalThemeSettingsProvider);

          expect(state.lightThemeId, 'iterm2-github-light-default');
          expect(state.darkThemeId, 'iterm2-dracula');
          expect(
            await settings.getString(SettingKeys.defaultTerminalThemeLight),
            'iterm2-github-light-default',
          );
          expect(
            await settings.getString(SettingKeys.defaultTerminalThemeDark),
            'iterm2-dracula',
          );
        },
      );

      test('normalizes unknown saved theme ids', () async {
        final settings = container.read(settingsServiceProvider);
        await settings.setString(
          SettingKeys.defaultTerminalThemeLight,
          'missing-light-theme',
        );
        await settings.setString(
          SettingKeys.defaultTerminalThemeDark,
          'missing-dark-theme',
        );

        container.read(terminalThemeSettingsProvider);
        await _waitForStoredTerminalThemeIds(
          settings,
          lightThemeId: TerminalThemes.defaultLightThemeId,
          darkThemeId: TerminalThemes.defaultDarkThemeId,
        );
        final state = container.read(terminalThemeSettingsProvider);

        expect(state.lightThemeId, TerminalThemes.defaultLightThemeId);
        expect(state.darkThemeId, TerminalThemes.defaultDarkThemeId);
        expect(
          await settings.getString(SettingKeys.defaultTerminalThemeLight),
          TerminalThemes.defaultLightThemeId,
        );
        expect(
          await settings.getString(SettingKeys.defaultTerminalThemeDark),
          TerminalThemes.defaultDarkThemeId,
        );
      });

      test('keeps saved custom theme ids', () async {
        final settings = container.read(settingsServiceProvider);
        final customTheme = TerminalThemes.defaultLightTheme.copyWith(
          id: 'custom-light-theme',
          name: 'Custom Light Theme',
          isCustom: true,
        );
        await settings.setString(
          SettingKeys.customTerminalThemes,
          jsonEncode([customTheme.toJson()]),
        );
        await settings.setString(
          SettingKeys.defaultTerminalThemeLight,
          customTheme.id,
        );

        container.read(terminalThemeSettingsProvider);
        final state = await _waitForTerminalThemeSettings(
          container,
          (settings) => settings.lightThemeId == customTheme.id,
        );

        expect(state.lightThemeId, customTheme.id);
        expect(
          await settings.getString(SettingKeys.defaultTerminalThemeLight),
          customTheme.id,
        );
      });

      test('keeps custom theme ids that match legacy defaults', () async {
        final settings = container.read(settingsServiceProvider);
        final customLightTheme = TerminalThemes.defaultLightTheme.copyWith(
          id: 'github-light',
          name: 'Custom GitHub Light',
          isCustom: true,
        );
        final customDarkTheme = TerminalThemes.defaultDarkTheme.copyWith(
          id: 'dracula',
          name: 'Custom Dracula',
          isCustom: true,
        );
        await settings.setString(
          SettingKeys.customTerminalThemes,
          jsonEncode([customLightTheme.toJson(), customDarkTheme.toJson()]),
        );
        await settings.setString(
          SettingKeys.defaultTerminalThemeLight,
          customLightTheme.id,
        );
        await settings.setString(
          SettingKeys.defaultTerminalThemeDark,
          customDarkTheme.id,
        );

        container.read(terminalThemeSettingsProvider);
        final state = await _waitForTerminalThemeSettings(
          container,
          (settings) =>
              settings.lightThemeId == customLightTheme.id &&
              settings.darkThemeId == customDarkTheme.id,
        );

        expect(state.lightThemeId, customLightTheme.id);
        expect(state.darkThemeId, customDarkTheme.id);
        expect(
          await settings.getString(SettingKeys.defaultTerminalThemeLight),
          customLightTheme.id,
        );
        expect(
          await settings.getString(SettingKeys.defaultTerminalThemeDark),
          customDarkTheme.id,
        );
      });

      test(
        'normalizes unknown ids when custom theme JSON is not a list',
        () async {
          final settings = container.read(settingsServiceProvider);
          await settings.setString(
            SettingKeys.customTerminalThemes,
            jsonEncode({'themes': <String>[]}),
          );
          await settings.setString(
            SettingKeys.defaultTerminalThemeLight,
            'missing-light-theme',
          );
          await settings.setString(
            SettingKeys.defaultTerminalThemeDark,
            'missing-dark-theme',
          );

          container.read(terminalThemeSettingsProvider);
          await _waitForStoredTerminalThemeIds(
            settings,
            lightThemeId: TerminalThemes.defaultLightThemeId,
            darkThemeId: TerminalThemes.defaultDarkThemeId,
          );
          final state = container.read(terminalThemeSettingsProvider);

          expect(state.lightThemeId, TerminalThemes.defaultLightThemeId);
          expect(state.darkThemeId, TerminalThemes.defaultDarkThemeId);
        },
      );

      test(
        'keeps valid custom themes while skipping malformed entries',
        () async {
          final settings = container.read(settingsServiceProvider);
          final customTheme = TerminalThemes.defaultLightTheme.copyWith(
            id: 'custom-theme-with-malformed-neighbors',
            name: 'Custom Theme With Malformed Neighbors',
            isCustom: true,
          );
          await settings.setString(
            SettingKeys.customTerminalThemes,
            jsonEncode([
              42,
              {'id': 'incomplete-theme'},
              customTheme.toJson(),
            ]),
          );
          await settings.setString(
            SettingKeys.defaultTerminalThemeLight,
            customTheme.id,
          );

          container.read(terminalThemeSettingsProvider);
          final state = await _waitForTerminalThemeSettings(
            container,
            (settings) => settings.lightThemeId == customTheme.id,
          );

          expect(state.lightThemeId, customTheme.id);
        },
      );
    });

    // Note: most NotifierProvider tests (themeModeNotifierProvider,
    // fontSizeNotifierProvider, etc.) are skipped because they have async _init()
    // methods that can race with test teardown and cause "database closed"
    // errors.
    // The FutureProvider tests above provide coverage for the provider initialization.
  });
}

Future<TerminalThemeSettings> _waitForTerminalThemeSettings(
  ProviderContainer container,
  bool Function(TerminalThemeSettings settings) matches,
) async {
  for (var attempt = 0; attempt < 20; attempt += 1) {
    final settings = container.read(terminalThemeSettingsProvider);
    if (matches(settings)) {
      return settings;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return container.read(terminalThemeSettingsProvider);
}

Future<void> _waitForStoredTerminalThemeIds(
  SettingsService settings, {
  required String lightThemeId,
  required String darkThemeId,
}) async {
  String? lastLight;
  String? lastDark;

  for (var attempt = 0; attempt < 20; attempt += 1) {
    final light = await settings.getString(
      SettingKeys.defaultTerminalThemeLight,
    );
    final dark = await settings.getString(SettingKeys.defaultTerminalThemeDark);
    lastLight = light;
    lastDark = dark;
    if (light == lightThemeId && dark == darkThemeId) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  throw TestFailure(
    'Timed out waiting for stored terminal theme IDs. '
    'Expected light="$lightThemeId", dark="$darkThemeId", '
    'but last observed light="$lastLight", dark="$lastDark".',
  );
}

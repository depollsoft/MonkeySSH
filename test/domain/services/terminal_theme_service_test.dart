// ignore_for_file: public_member_api_docs

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/terminal_themes.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/terminal_theme_service.dart';

void main() {
  late AppDatabase db;
  late SettingsService settingsService;
  late TerminalThemeService themeService;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    settingsService = SettingsService(db);
    themeService = TerminalThemeService(settingsService);
  });

  tearDown(() async {
    await db.close();
  });

  group('TerminalThemeService', () {
    group('getThemeForHost', () {
      test('returns built-in dark default when no host', () async {
        final theme = await themeService.getThemeForHost(null, Brightness.dark);
        expect(theme.id, TerminalThemes.defaultDarkTheme.id);
      });

      test('returns built-in light default when no host', () async {
        final theme = await themeService.getThemeForHost(
          null,
          Brightness.light,
        );
        expect(theme.id, TerminalThemes.defaultLightTheme.id);
      });

      test('ignores host override when disabled', () async {
        final host = Host(
          id: 1,
          label: 'Prod',
          hostname: 'prod.example.com',
          port: 22,
          username: 'root',
          isFavorite: false,
          createdAt: DateTime(2024),
          updatedAt: DateTime(2024),
          terminalThemeLightId: TerminalThemes.githubLightDefault.id,
          terminalThemeDarkId: TerminalThemes.nord.id,
          autoConnectRequiresConfirmation: false,
          autoForwardPorts: false,
          sortOrder: 0,
        );

        final theme = await themeService.getThemeForHost(
          host,
          Brightness.dark,
          allowHostOverride: false,
        );

        expect(theme.id, TerminalThemes.defaultDarkTheme.id);
      });

      test('resolves legacy host override IDs', () async {
        final host = Host(
          id: 1,
          label: 'Prod',
          hostname: 'prod.example.com',
          port: 22,
          username: 'root',
          isFavorite: false,
          createdAt: DateTime(2024),
          updatedAt: DateTime(2024),
          terminalThemeLightId: 'clean-white',
          terminalThemeDarkId: 'ocean-dark',
          autoConnectRequiresConfirmation: false,
          autoForwardPorts: false,
          sortOrder: 0,
        );

        final theme = await themeService.getThemeForHost(host, Brightness.dark);

        expect(theme.id, TerminalThemes.solarizedDark.id);
      });
    });

    group('getThemeById', () {
      test('returns built-in theme by id', () async {
        final theme = await themeService.getThemeById('iterm2-dracula');
        expect(theme, isNotNull);
        expect(theme!.name, 'Dracula');
      });

      test('returns mapped built-in theme by legacy id', () async {
        final theme = await themeService.getThemeById('midnight-purple');
        expect(theme, isNotNull);
        expect(theme!.id, TerminalThemes.defaultDarkThemeId);
      });

      test('returns null for unknown id', () async {
        final theme = await themeService.getThemeById('nonexistent-theme');
        expect(theme, isNull);
      });
    });

    group('getAllThemes', () {
      test('returns all built-in themes', () async {
        final themes = await themeService.getAllThemes();
        expect(themes.length, TerminalThemes.all.length);
      });
    });

    group('getCustomThemes', () {
      test('returns empty list initially', () async {
        final themes = await themeService.getCustomThemes();
        expect(themes, isEmpty);
      });

      test(
        'returns empty list when stored custom themes are not a list',
        () async {
          await settingsService.setString(
            SettingKeys.customTerminalThemes,
            jsonEncode({'themes': <String>[]}),
          );

          final themes = await themeService.getCustomThemes();

          expect(themes, isEmpty);
        },
      );

      test('skips malformed custom theme entries', () async {
        final theme = TerminalThemes.defaultDarkTheme.copyWith(
          id: 'custom-with-malformed-neighbors',
          name: 'Custom With Malformed Neighbors',
          isCustom: true,
        );
        await settingsService.setString(
          SettingKeys.customTerminalThemes,
          jsonEncode([
            42,
            {'id': 'incomplete-theme'},
            theme.toJson(),
          ]),
        );

        final themes = await themeService.getCustomThemes();

        expect(themes, hasLength(1));
        expect(themes.single.id, theme.id);
      });
    });

    group('saveCustomTheme', () {
      test('saves and retrieves a custom theme', () async {
        final theme = TerminalThemes.defaultDarkTheme.copyWith(
          id: 'custom-test',
          name: 'Custom Test',
          isCustom: true,
        );

        await themeService.saveCustomTheme(theme);

        final customs = await themeService.getCustomThemes();
        expect(customs, hasLength(1));
        expect(customs.first.id, 'custom-test');
        expect(customs.first.name, 'Custom Test');
      });

      test('updates existing custom theme', () async {
        final theme = TerminalThemes.defaultDarkTheme.copyWith(
          id: 'custom-update',
          name: 'Original',
          isCustom: true,
        );
        await themeService.saveCustomTheme(theme);

        final updated = theme.copyWith(name: 'Updated');
        await themeService.saveCustomTheme(updated);

        final customs = await themeService.getCustomThemes();
        expect(customs, hasLength(1));
        expect(customs.first.name, 'Updated');
      });
    });

    group('deleteCustomTheme', () {
      test('deletes a custom theme', () async {
        final theme = TerminalThemes.defaultDarkTheme.copyWith(
          id: 'custom-delete',
          name: 'To Delete',
          isCustom: true,
        );
        await themeService.saveCustomTheme(theme);
        expect(await themeService.getCustomThemes(), hasLength(1));

        await themeService.deleteCustomTheme('custom-delete');

        final customs = await themeService.getCustomThemes();
        expect(customs, isEmpty);
      });
    });
  });

  group('TerminalAppThemeOverrideNotifier', () {
    test('does not notify for repeated equivalent overrides', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final owner = Object();
      final notifications = <TerminalAppThemeOverride?>[];
      final subscription = container.listen<TerminalAppThemeOverride?>(
        terminalAppThemeOverrideProvider,
        (_, next) => notifications.add(next),
      );
      addTearDown(subscription.close);

      final notifier = container.read(
        terminalAppThemeOverrideProvider.notifier,
      );
      void setOverride(Object overrideOwner) {
        notifier.activeOverride = TerminalAppThemeOverride(
          owner: overrideOwner,
          lightThemeId: TerminalThemes.githubLightDefault.id,
          darkThemeId: TerminalThemes.dracula.id,
        );
      }

      setOverride(owner);
      setOverride(owner);

      expect(notifications, hasLength(1));

      setOverride(Object());

      expect(notifications, hasLength(2));
    });
  });
}

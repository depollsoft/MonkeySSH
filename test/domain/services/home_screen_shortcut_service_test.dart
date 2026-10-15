// ignore_for_file: public_member_api_docs, avoid_redundant_argument_values

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/services/home_screen_shortcut_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

Host _buildHost({
  required int id,
  required String label,
  required int sortOrder,
  bool isFavorite = false,
  DateTime? lastConnectedAt,
  int port = 22,
}) => Host(
  id: id,
  label: label,
  hostname: '$label.example.com',
  port: port,
  username: 'root',
  password: null,
  keyId: null,
  groupId: null,
  jumpHostId: null,
  isFavorite: isFavorite,
  color: null,
  notes: null,
  tags: null,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  lastConnectedAt: lastConnectedAt,
  terminalThemeLightId: null,
  terminalThemeDarkId: null,
  terminalFontFamily: null,
  autoConnectCommand: null,
  autoConnectSnippetId: null,
  autoConnectRequiresConfirmation: false,
  autoForwardPorts: false,
  tmuxSessionName: null,
  tmuxWorkingDirectory: null,
  tmuxExtraFlags: null,
  sortOrder: sortOrder,
  notifyAgentAttention: true,
  notifyAgentFinished: true,
  notifyWindowAlerts: true,
  notifyShellNotifications: true,
  pushWhenClosed: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('home screen shortcut payload parsing', () {
    test('parses valid host shortcut types', () {
      expect(parseHomeScreenShortcutHostId('host:42'), 42);
    });

    test('rejects invalid host shortcut types', () {
      expect(parseHomeScreenShortcutHostId(null), isNull);
      expect(parseHomeScreenShortcutHostId(''), isNull);
      expect(parseHomeScreenShortcutHostId('help'), isNull);
      expect(parseHomeScreenShortcutHostId('host:abc'), isNull);
      expect(parseHomeScreenShortcutHostId('host:0'), isNull);
    });
  });

  group('home screen shortcut ranking', () {
    test('prefers pinned hosts, then favorites, then recents', () {
      final selectedHosts = selectHomeScreenShortcutHosts(
        <Host>[
          _buildHost(
            id: 1,
            label: 'recent',
            sortOrder: 10,
            lastConnectedAt: DateTime(2026, 1, 3),
          ),
          _buildHost(id: 2, label: 'favorite', sortOrder: 20, isFavorite: true),
          _buildHost(id: 3, label: 'pinned', sortOrder: 30),
          _buildHost(id: 4, label: 'fallback', sortOrder: 0),
        ],
        pinnedHostIds: <int>{3},
      );

      expect(selectedHosts.map((host) => host.id).toList(), <int>[3, 2, 1, 4]);
    });

    test('limits the shortcut list to four hosts', () {
      final selectedHosts = selectHomeScreenShortcutHosts(
        List<Host>.generate(
          6,
          (index) => _buildHost(
            id: index + 1,
            label: 'host-${index + 1}',
            sortOrder: index,
          ),
        ),
        pinnedHostIds: const <int>{},
      );

      expect(selectedHosts, hasLength(maxHomeScreenShortcutItems));
      expect(selectedHosts.map((host) => host.id).toList(), <int>[1, 2, 3, 4]);
    });

    test('builds shortcut items with host payloads and subtitles', () {
      final shortcutItems = buildHomeScreenShortcutItems(<Host>[
        _buildHost(id: 1, label: 'alpha', sortOrder: 0),
        _buildHost(id: 2, label: 'beta', sortOrder: 1, port: 2202),
      ]);

      expect(shortcutItems, hasLength(2));
      expect(shortcutItems.first.type, 'host:1');
      expect(shortcutItems.first.localizedTitle, 'alpha');
      expect(shortcutItems.first.localizedSubtitle, 'root@alpha.example.com');
      expect(
        shortcutItems.last.localizedSubtitle,
        'root@beta.example.com:2202',
      );
    });

    test('omits an icon when no icon name is provided', () {
      final shortcutItems = buildHomeScreenShortcutItems(<Host>[
        _buildHost(id: 1, label: 'alpha', sortOrder: 0),
      ]);

      expect(shortcutItems.single.icon, isNull);
    });

    test('applies the provided icon name to every shortcut item', () {
      final shortcutItems = buildHomeScreenShortcutItems(<Host>[
        _buildHost(id: 1, label: 'alpha', sortOrder: 0),
        _buildHost(id: 2, label: 'beta', sortOrder: 1),
      ], iconName: homeScreenShortcutHostIconResourceName);

      expect(
        shortcutItems.map((item) => item.icon),
        everyElement(equals('ic_shortcut_host')),
      );
    });
  });

  group('home screen shortcut host icon name', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('is the Android drawable resource on Android', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(homeScreenShortcutHostIconName, 'ic_shortcut_host');
    });

    test('is the asset-catalog template image on iOS', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(homeScreenShortcutHostIconName, 'ic_shortcut_host');
    });

    test('is null on other platforms', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(homeScreenShortcutHostIconName, isNull);
    });
  });

  group('home screen shortcut preferences', () {
    late AppDatabase db;
    late SettingsService settingsService;
    late HomeScreenShortcutPreferencesService preferencesService;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      settingsService = SettingsService(db);
      preferencesService = HomeScreenShortcutPreferencesService(
        settingsService,
      );
    });

    tearDown(() async {
      await db.close();
    });

    test('stores pinned host IDs in a stable sorted order', () async {
      await preferencesService.setHostPinned(7, pinned: true);
      await preferencesService.setHostPinned(3, pinned: true);

      expect(await preferencesService.getPinnedHostIds(), <int>{3, 7});
      expect(
        await settingsService.getString(SettingKeys.homeScreenShortcutHostIds),
        '[3,7]',
      );
    });

    test(
      'clears the persisted setting after the last pinned host is removed',
      () async {
        await preferencesService.setHostPinned(3, pinned: true);
        await preferencesService.setHostPinned(3, pinned: false);

        expect(await preferencesService.getPinnedHostIds(), isEmpty);
        expect(
          await settingsService.getString(
            SettingKeys.homeScreenShortcutHostIds,
          ),
          isNull,
        );
      },
    );
  });

  test('queued shortcut launches flush to the first listener', () async {
    final service = HomeScreenShortcutService();
    addTearDown(service.dispose);

    service.debugEmitHostLaunch(9);

    await expectLater(service.hostLaunches, emits(9));
  });

  test('debug-emitted launches after dispose are ignored', () async {
    final service = HomeScreenShortcutService();

    await service.dispose();

    expect(() => service.debugEmitHostLaunch(9), returnsNormally);
  });
}

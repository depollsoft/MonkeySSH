// ignore_for_file: public_member_api_docs, directives_ordering

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/app/app.dart';
import 'package:monkeyssh/app/app_metadata.dart';
import 'package:monkeyssh/app/auth_lifecycle_controller.dart';
import 'package:monkeyssh/app/router.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/domain/services/acp_lifecycle_service.dart';
import 'package:monkeyssh/domain/services/auth_service.dart';
import 'package:monkeyssh/domain/services/home_screen_shortcut_service.dart';
import 'package:monkeyssh/domain/services/local_notification_service.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

class _Notifications extends Mock implements LocalNotificationService {}

class _Shortcuts extends Mock implements HomeScreenShortcutService {}

class _ShortcutPreferences extends Mock
    implements HomeScreenShortcutPreferencesService {}

class _Hosts extends Mock implements HostRepository {}

class _Monetization extends Mock implements MonetizationService {}

class _AuthLifecycle extends Mock implements AuthLifecycleController {}

class _AcpLifecycle extends Mock implements AcpLifecycleService {}

class _AuthState extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.notConfigured;
}

class _Sessions extends ActiveSessionsNotifier {
  _Sessions(this.calls);
  final List<String> calls;

  @override
  Map<int, SshConnectionState> build() => {};

  @override
  Future<void> syncBackgroundStatus() async => calls.add('foreground');
}

void main() {
  setUp(() => FluttyTheme.debugUseSystemFonts = true);
  tearDown(() => FluttyTheme.debugUseSystemFonts = false);
  for (final platform in [TargetPlatform.android, TargetPlatform.linux]) {
    testWidgets('bridge startup and auth ordering on ${platform.name}', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final calls = <String>[];
        final notifications = _Notifications();
        final shortcuts = _Shortcuts();
        final preferences = _ShortcutPreferences();
        final hosts = _Hosts();
        final monetization = _Monetization();
        final auth = _AuthLifecycle();
        final acp = _AcpLifecycle();
        when(() => notifications.tmuxAlertTaps).thenAnswer((_) {
          calls.add('listen:notifications');
          return const Stream.empty();
        });
        when(
          () => notifications.terminalNotificationTaps,
        ).thenAnswer((_) => const Stream.empty());
        when(
          () => notifications.acpNotificationTaps,
        ).thenAnswer((_) => const Stream.empty());
        when(notifications.initialize).thenAnswer((_) async {
          calls.add('notifications');
          return true;
        });
        when(
          notifications.consumeLaunchTmuxAlert,
        ).thenAnswer((_) async => null);
        when(
          notifications.consumeLaunchTerminalNotification,
        ).thenAnswer((_) async => null);
        when(
          notifications.consumeLaunchAcpNotification,
        ).thenAnswer((_) async => null);
        when(hosts.watchAll).thenAnswer((_) {
          calls.add('listen:shortcuts');
          return const Stream.empty();
        });
        when(
          preferences.watchPinnedHostIds,
        ).thenAnswer((_) => const Stream.empty());
        when(
          shortcuts.initialize,
        ).thenAnswer((_) async => calls.add('shortcuts'));
        when(
          monetization.initialize,
        ).thenAnswer((_) async => calls.add('monetization'));
        when(acp.handleForeground).thenAnswer((_) async {});
        when(
          acp.handleBackground,
        ).thenAnswer((_) async => calls.add('background'));
        final router = GoRouter(
          routes: [
            GoRoute(path: '/', builder: (_, _) => const SizedBox.shrink()),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              databaseProvider.overrideWithValue(db),
              routerProvider.overrideWithValue(router),
              appMetadataProvider.overrideWith(
                (_) async => const AppMetadata(
                  appName: 'MonkeySSH',
                  version: '1.0.0',
                  buildNumber: '1',
                ),
              ),
              localNotificationServiceProvider.overrideWithValue(notifications),
              homeScreenShortcutServiceProvider.overrideWithValue(shortcuts),
              homeScreenShortcutPreferencesServiceProvider.overrideWithValue(
                preferences,
              ),
              hostRepositoryProvider.overrideWithValue(hosts),
              monetizationServiceProvider.overrideWithValue(monetization),
              authStateProvider.overrideWith(_AuthState.new),
              authLifecycleControllerProvider.overrideWithValue(auth),
              acpLifecycleServiceProvider.overrideWithValue(acp),
              activeSessionsProvider.overrideWith(() => _Sessions(calls)),
            ],
            child: const FluttyApp(),
          ),
        );
        await tester.pumpAndSettle();
        expect(calls, [
          'listen:notifications',
          if (platform == TargetPlatform.android) 'listen:shortcuts',
          'notifications',
          if (platform == TargetPlatform.android) 'shortcuts',
          'monetization',
          'foreground',
        ]);

        final bridge = tester.allStates
            .whereType<ConsumerState>()
            .whereType<WidgetsBindingObserver>()
            .single;
        for (final state in AppLifecycleState.values) {
          calls.clear();
          final authComplete = Completer<void>();
          when(() => auth.handleLifecycleStateChanged(state)).thenAnswer((
            _,
          ) async {
            calls.add('auth:start');
            await authComplete.future;
            calls.add('auth:end');
          });
          bridge.didChangeAppLifecycleState(state);
          await tester.pump();
          expect(calls, ['auth:start']);
          authComplete.complete();
          await tester.pump();
          expect(calls, [
            'auth:start',
            'auth:end',
            if (state == AppLifecycleState.resumed ||
                state == AppLifecycleState.inactive)
              'foreground'
            else
              'background',
          ]);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }
}

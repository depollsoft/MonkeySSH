// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/app/routes.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/services/host_agent_forwarding_service.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/ssh_agent_forwarding.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/providers/entity_list_providers.dart';
import 'package:monkeyssh/presentation/widgets/host_agent_forwarding_section.dart';

import '../helpers/recording_diagnostics_logger.dart';

MonetizationState _access({required bool pro}) => MonetizationState(
  billingAvailability: MonetizationBillingAvailability.unavailable,
  entitlements: pro
      ? const MonetizationEntitlements.pro()
      : const MonetizationEntitlements.free(),
  offers: const [],
  debugUnlockAvailable: false,
  debugUnlocked: false,
);

class _Billing extends Fake implements MonetizationService {
  _Billing({required this.pro});

  final bool pro;

  @override
  MonetizationState get currentState => _access(pro: pro);

  @override
  Future<bool> canUseFeature(MonetizationFeature feature) async => pro;
}

SshKey _key(int id, String name, {String privateKey = 'private'}) => SshKey(
  id: id,
  name: name,
  keyType: 'ssh-ed25519',
  publicKey: 'ssh-ed25519 AAAA',
  privateKey: privateKey,
  createdAt: DateTime(2026),
);

class _MockSession extends Mock implements SshSession {}

/// Open connections by ID, each with its host, state and forwarding.
class _Connections extends ActiveSessionsNotifier {
  _Connections(this.connections);

  final Map<
    int,
    ({int hostId, SshConnectionState state, SshAgentForwarding? forwarding})
  >
  connections;

  @override
  Map<int, SshConnectionState> build() => {
    for (final entry in connections.entries) entry.key: entry.value.state,
  };

  @override
  List<int> getConnectionsForHost(int hostId) => [
    for (final entry in connections.entries)
      if (entry.value.hostId == hostId) entry.key,
  ];

  @override
  SshSession? getSession(int connectionId) {
    final connection = connections[connectionId];
    if (connection == null) {
      return null;
    }
    final session = _MockSession();
    when(() => session.config).thenReturn(
      SshConnectionConfig(
        hostname: 'example.test',
        port: 22,
        username: 'dev',
        agentForwarding: connection.forwarding,
      ),
    );
    return session;
  }
}

SshAgentForwarding _forwarding() => SshAgentForwarding(
  hostId: 5,
  hostLabel: 'build box',
  loadPolicy: () async => const SshAgentForwardingPolicy(enabled: true),
  diagnostics: RecordingDiagnosticsLogger(),
);

/// Holds every save until the test releases it.
class _SlowForwardingService extends HostAgentForwardingService {
  _SlowForwardingService(super.settings);

  final release = Completer<void>();

  @override
  Future<void> setForHost(
    int hostId,
    HostAgentForwardingSettings settings,
  ) async {
    await release.future;
    await super.setForHost(hostId, settings);
  }
}

void main() {
  group('HostAgentForwardingSection', () {
    late AppDatabase db;
    late HostAgentForwardingService service;
    final paywallFeatures = <String?>[];
    final keys = [
      _key(3, 'GitHub'),
      _key(4, 'prod deploy'),
      _key(5, 'reference only', privateKey: ''),
    ];

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      service = HostAgentForwardingService(SettingsService(db));
      paywallFeatures.clear();
    });

    tearDown(() => db.close());

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
      }
    }

    Future<void> pumpSection(
      WidgetTester tester, {
      required int? hostId,
      int? hostKeyId = 3,
      bool pro = true,
      bool connectedWithoutForwarding = false,
      HostAgentForwardingService? forwardingService,
    }) async {
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, _) => Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: HostAgentForwardingSection(
                  hostId: hostId,
                  hostKeyId: hostKeyId,
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/upgrade',
            name: Routes.upgrade,
            builder: (context, state) {
              paywallFeatures.add(state.uri.queryParameters['feature']);
              return const Scaffold(body: Text('paywall'));
            },
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsServiceProvider.overrideWithValue(SettingsService(db)),
            if (forwardingService != null)
              hostAgentForwardingServiceProvider.overrideWithValue(
                forwardingService,
              ),
            monetizationServiceProvider.overrideWithValue(_Billing(pro: pro)),
            monetizationStateProvider.overrideWith(
              (ref) => Stream.value(_access(pro: pro)),
            ),
            allKeysProvider.overrideWith((ref) => Stream.value(keys)),
            if (hostId != null)
              hostConnectedWithoutAgentForwardingProvider(hostId)
                  .overrideWith((ref) => connectedWithoutForwarding),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await settle(tester);
    }

    Future<HostAgentForwardingSettings?> saved(WidgetTester tester) =>
        tester.runAsync(() => service.getForHost(5));

    testWidgets('is off by default and warns about agents and background use', (
      tester,
    ) async {
      await pumpSection(tester, hostId: 5);

      final toggle = tester.widget<SwitchListTile>(
        find.byKey(const Key('host-agent-forwarding-switch')),
      );
      expect(toggle.value, isFalse);
      expect(
        find.byKey(const Key('host-agent-forwarding-confirm-switch')),
        findsNothing,
      );
      expect(find.textContaining('YOLO mode'), findsOneWidget);
      expect(find.textContaining('in the background'), findsOneWidget);
      expect(find.textContaining('with the screen off'), findsOneWidget);
      expect(find.textContaining('connection closes'), findsOneWidget);
      expect(find.textContaining('sleeps'), findsNothing);
    });

    testWidgets(
      'turning it on offers only the host key until more are chosen',
      (tester) async {
        await pumpSection(tester, hostId: 5);

        await tester.tap(find.byKey(const Key('host-agent-forwarding-switch')));
        await settle(tester);

        expect(
          await saved(tester),
          const HostAgentForwardingSettings(enabled: true, keyIds: [3]),
        );
        expect(
          find.byKey(const Key('host-agent-forwarding-key-3')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('host-agent-forwarding-key-4')),
          findsOneWidget,
        );
        // A public-only key cannot sign, so it is not offered.
        expect(
          find.byKey(const Key('host-agent-forwarding-key-5')),
          findsNothing,
        );
        expect(find.text('This host’s sign-in key'), findsOneWidget);

        await tester.tap(find.byKey(const Key('host-agent-forwarding-key-4')));
        await settle(tester);
        expect((await saved(tester))!.keyIds, [3, 4]);

        await tester.tap(find.byKey(const Key('host-agent-forwarding-key-3')));
        await settle(tester);
        expect((await saved(tester))!.keyIds, [4]);

        await tester.tap(
          find.byKey(const Key('host-agent-forwarding-confirm-switch')),
        );
        await settle(tester);
        expect(
          await saved(tester),
          const HostAgentForwardingSettings(
            enabled: true,
            confirmEachSignature: true,
            keyIds: [4],
          ),
        );
        expect(paywallFeatures, isEmpty);
      },
    );

    testWidgets('asks to choose a key when the host has none of its own', (
      tester,
    ) async {
      await pumpSection(tester, hostId: 5, hostKeyId: null);

      await tester.tap(find.byKey(const Key('host-agent-forwarding-switch')));
      await settle(tester);

      expect((await saved(tester))!.keyIds, isEmpty);
      expect(
        tester
            .widget<Text>(
              find.byKey(const Key('host-agent-forwarding-key-hint')),
            )
            .data,
        'Choose at least one. Until then the host sees no keys.',
      );
    });

    testWidgets('says turning it on waits for the next connection', (
      tester,
    ) async {
      await pumpSection(tester, hostId: 5);

      expect(find.textContaining('Applies to open connections'), findsNothing);
      expect(
        find.textContaining('Starts on your next connection'),
        findsOneWidget,
      );
    });

    testWidgets('asks for a reconnect while a connection is not forwarding', (
      tester,
    ) async {
      await tester.runAsync(
        () => service.setForHost(
          5,
          const HostAgentForwardingSettings(enabled: true, keyIds: [3]),
        ),
      );
      await pumpSection(tester, hostId: 5, connectedWithoutForwarding: true);

      expect(
        find.byKey(const Key('host-agent-forwarding-reconnect')),
        findsOneWidget,
      );
      expect(find.textContaining('Reconnect to use it there'), findsOneWidget);
    });

    testWidgets('asks for no reconnect while forwarding is off', (
      tester,
    ) async {
      await pumpSection(tester, hostId: 5, connectedWithoutForwarding: true);

      expect(
        find.byKey(const Key('host-agent-forwarding-reconnect')),
        findsNothing,
      );
    });

    testWidgets('explains that forwarding waits for Pro', (tester) async {
      await tester.runAsync(
        () => service.setForHost(
          5,
          const HostAgentForwardingSettings(enabled: true, keyIds: [3]),
        ),
      );
      await pumpSection(tester, hostId: 5, pro: false);

      expect(
        find.byKey(const Key('host-agent-forwarding-pro-inactive')),
        findsOneWidget,
      );
      // Connecting without Pro never starts forwarding, so a reconnect would
      // not help.
      expect(
        find.byKey(const Key('host-agent-forwarding-reconnect')),
        findsNothing,
      );
    });

    testWidgets('shows forwarding turned off from a prompt', (tester) async {
      await tester.runAsync(
        () => service.setForHost(
          5,
          const HostAgentForwardingSettings(enabled: true, keyIds: [3]),
        ),
      );
      final shared = HostAgentForwardingService(SettingsService(db));
      await pumpSection(tester, hostId: 5, forwardingService: shared);
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('host-agent-forwarding-switch')),
            )
            .value,
        isTrue,
      );

      // "Deny and turn off forwarding" saves through the same service.
      await tester.runAsync(
        () => shared.setForHost(
          5,
          const HostAgentForwardingSettings(keyIds: [3]),
        ),
      );
      await settle(tester);

      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('host-agent-forwarding-switch')),
            )
            .value,
        isFalse,
      );
    });

    testWidgets('asks for Pro before turning it on', (tester) async {
      await pumpSection(tester, hostId: 5, pro: false);

      expect(find.text('Pro'), findsOneWidget);
      await tester.tap(find.byKey(const Key('host-agent-forwarding-switch')));
      await settle(tester);

      expect(paywallFeatures, [MonetizationFeature.agentForwarding.name]);
      expect(await saved(tester), const HostAgentForwardingSettings());
    });

    testWidgets('cannot opt in before the host is saved', (tester) async {
      await pumpSection(tester, hostId: null);

      final toggle = tester.widget<SwitchListTile>(
        find.byKey(const Key('host-agent-forwarding-switch')),
      );
      expect(toggle.onChanged, isNull);
      expect(
        find.text('Save the host first to turn on agent forwarding.'),
        findsOneWidget,
      );
    });

    testWidgets('leaving the editor while a save runs is safe', (tester) async {
      final slow = _SlowForwardingService(SettingsService(db));
      await pumpSection(tester, hostId: 5, forwardingService: slow);

      await tester.tap(find.byKey(const Key('host-agent-forwarding-switch')));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      slow.release.complete();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect((await saved(tester))!.enabled, isTrue);
    });
  });

  group('hostConnectedWithoutAgentForwardingProvider', () {
    bool read(
      Map<
        int,
        ({int hostId, SshConnectionState state, SshAgentForwarding? forwarding})
      >
      connections,
    ) {
      final container = ProviderContainer(
        overrides: [
          activeSessionsProvider.overrideWith(() => _Connections(connections)),
          hostAgentForwardingSettingsProvider(5).overrideWith(
            (ref) async =>
                const HostAgentForwardingSettings(enabled: true, keyIds: [3]),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container.read(hostConnectedWithoutAgentForwardingProvider(5));
    }

    test('is true for a connection opened without forwarding', () {
      expect(
        read({
          1: (hostId: 5, state: SshConnectionState.connected, forwarding: null),
        }),
        isTrue,
      );
    });

    test('is true for a connection whose forwarding was stopped', () {
      final stopped = _forwarding()..stop();
      expect(
        read({
          1: (
            hostId: 5,
            state: SshConnectionState.connected,
            forwarding: stopped,
          ),
        }),
        isTrue,
      );
    });

    test('is false while every open connection forwards', () {
      expect(
        read({
          1: (
            hostId: 5,
            state: SshConnectionState.connected,
            forwarding: _forwarding(),
          ),
          // Another host, and a connection that is not up yet.
          2: (hostId: 6, state: SshConnectionState.connected, forwarding: null),
          3: (
            hostId: 5,
            state: SshConnectionState.connecting,
            forwarding: null,
          ),
        }),
        isFalse,
      );
    });

    test('is false with no connection', () {
      expect(read({}), isFalse);
    });
  });
}

// ignore_for_file: public_member_api_docs

import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/acp_recent_session.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/services/acp_recent_sessions_service.dart';
import 'package:monkeyssh/domain/services/host_setup_checklist_service.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_installer_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/ssh_exec_queue.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/providers/entity_list_providers.dart';
import 'package:monkeyssh/presentation/providers/host_setup_checklist_providers.dart';
import 'package:monkeyssh/presentation/widgets/host_setup_checklist.dart';

import '../helpers/mocks.dart';

class _Sessions extends ActiveSessionsNotifier {
  _Sessions(this.connected);

  Map<int, int> connected;

  /// Replaces every connection with [connectionId] for [hostId].
  void reconnect(int connectionId, int hostId) {
    connected = {connectionId: hostId};
    state = {connectionId: SshConnectionState.connected};
  }

  @override
  Map<int, SshConnectionState> build() => {
    for (final connectionId in connected.keys)
      connectionId: SshConnectionState.connected,
  };

  @override
  List<int> getConnectionsForHost(int hostId) => [
    for (final entry in connected.entries)
      if (entry.value == hostId) entry.key,
  ];

  @override
  ConnectionAttemptStatus? getConnectionAttempt(int hostId) => null;
}

class _SeededProbes extends HostSetupProbeResultsNotifier {
  _SeededProbes(this.seed);

  final Map<int, HostSetupProbeResult> seed;

  @override
  Map<int, HostSetupProbeResult> build() => seed;
}

class _FakeSshService extends SshService {
  _FakeSshService(this.hostId, {this.connected = const {}});

  final int hostId;
  final Map<int, int> connected;

  @override
  SshSession? getSession(int connectionId) {
    final session = MockSshSession();
    when(() => session.connectionId).thenReturn(connectionId);
    when(() => session.hostId).thenReturn(hostId);
    return session;
  }

  @override
  List<SshSession> getSessionsForHost(int hostId) => [
    for (final entry in connected.entries)
      if (entry.value == hostId) getSession(entry.key)!,
  ];
}

/// An installer whose install fails the way a dropped SSH channel does.
class _FailingInstaller implements MonkeyMuxInstallerService {
  @override
  Future<MonkeyMuxInstallation> ensureInstalled(
    SshSession session, {
    SshExecPriority priority = SshExecPriority.low,
    MonkeyMuxInstallConfirmation? confirmInstall,
    MonkeyMuxInstallation? Function()? reuseInstallation,
  }) async =>
      // dartssh2's errors are neither Exception nor Error.
      // ignore: only_throw_errors
      throw SSHStateError('SSH connection closed');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _freeState = MonetizationState(
  billingAvailability: MonetizationBillingAvailability.available,
  entitlements: MonetizationEntitlements.free(),
  offers: [],
  debugUnlockAvailable: false,
  debugUnlocked: false,
);

Host _host({int? keyId, String? password = 'secret'}) => Host(
  id: 3,
  label: 'gpu-box',
  hostname: 'gpu.example.com',
  port: 22,
  username: 'me',
  password: password,
  keyId: keyId,
  isFavorite: false,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  lastConnectedAt: DateTime(2026, 10),
  autoConnectRequiresConfirmation: false,
  autoForwardPorts: false,
  sortOrder: 0,
  notifyAgentAttention: true,
  notifyAgentFinished: true,
  notifyWindowAlerts: true,
  notifyShellNotifications: true,
  pushWhenClosed: true,
);

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> pump(
    WidgetTester tester, {
    required Host host,
    required Widget child,
    Map<int, int> connected = const {},
    HostSetupProber? prober,
    Map<int, HostSetupProbeResult>? probes,
    MonkeyMuxInstallerService? installer,
    MonetizationState monetization = _freeState,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          allHostsProvider.overrideWith((ref) => Stream.value([host])),
          activeSessionsProvider.overrideWith(() => _Sessions(connected)),
          sshServiceProvider.overrideWithValue(
            _FakeSshService(host.id, connected: connected),
          ),
          monetizationStateProvider.overrideWith(
            (ref) => Stream.value(monetization),
          ),
          if (installer != null)
            monkeyMuxInstallerServiceProvider.overrideWithValue(installer),
          if (prober != null) hostSetupProberProvider.overrideWithValue(prober),
          if (probes != null)
            hostSetupProbeResultsProvider.overrideWith(
              () => _SeededProbes(probes),
            ),
        ],
        child: MaterialApp(
          home: Scaffold(body: Center(child: child)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a password host shows the key step and opens the sheet', (
    tester,
  ) async {
    final host = _host();
    await pump(
      tester,
      host: host,
      child: HostSetupChecklistLine(host: host),
    );

    expect(find.text('0/4 · '), findsOneWidget);
    expect(find.text('switch to key login'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Setup 0 of 4 done. Next: switch to key login'),
      findsOneWidget,
    );

    await tester.tap(find.text('switch to key login'));
    await tester.pumpAndSettle();

    expect(find.text('Host Setup'), findsOneWidget);
    expect(find.text('Set Up Key Login'), findsOneWidget);
    expect(find.bySemanticsLabel('Key login: next'), findsOneWidget);
    expect(
      find.bySemanticsLabel('MonkeyMux installed: connect to check'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Agent signed in: to do'), findsOneWidget);
  });

  testWidgets('hiding the checklist persists per host', (tester) async {
    final host = _host();
    await pump(
      tester,
      host: host,
      child: HostSetupChecklistLine(host: host),
    );

    await tester.tap(find.byTooltip('Hide setup checklist'));
    await tester.pumpAndSettle();

    expect(find.text('0/4 · '), findsNothing);
    final states = await tester.runAsync(
      () => HostSetupChecklistStore(SettingsService(db)).load(),
    );
    expect(states![3]!.dismissed, isTrue);
  });

  testWidgets('Undo brings a hidden checklist back', (tester) async {
    final host = _host();
    await pump(
      tester,
      host: host,
      child: HostSetupChecklistLine(host: host),
    );

    await tester.tap(find.byTooltip('Hide setup checklist'));
    await tester.pumpAndSettle();
    expect(find.text('Setup checklist hidden for gpu-box.'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    expect(find.text('0/4 · '), findsOneWidget);
    final states = await tester.runAsync(
      () => HostSetupChecklistStore(SettingsService(db)).load(),
    );
    expect(states![3]!.dismissed, isFalse);
  });

  testWidgets('screen readers can open the sheet from the row line', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final host = _host();
    await pump(
      tester,
      host: host,
      child: HostSetupChecklistLine(host: host),
    );

    tester.semantics.tap(
      find.semantics.byLabel('Setup 0 of 4 done. Next: switch to key login'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Host Setup'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('the agent step says Pro only to users without it', (
    tester,
  ) async {
    final host = _host(keyId: 1, password: null);
    const probes = {
      3: HostSetupProbeResult(
        connectionId: 7,
        monkeyMuxInstalled: true,
        agentsDetected: false,
      ),
    };
    await pump(
      tester,
      host: host,
      probes: probes,
      child: const HostSetupChecklistSheet(hostId: 3),
    );
    expect(find.text('Open Agent Management (Pro)'), findsOneWidget);
  });

  testWidgets('the agent step drops the Pro tag for Pro users', (tester) async {
    final host = _host(keyId: 1, password: null);
    await pump(
      tester,
      host: host,
      probes: const {
        3: HostSetupProbeResult(
          connectionId: 7,
          monkeyMuxInstalled: true,
          agentsDetected: false,
        ),
      },
      monetization: _freeState.copyWith(
        entitlements: const MonetizationEntitlements.pro(),
      ),
      child: const HostSetupChecklistSheet(hostId: 3),
    );
    expect(find.text('Open Agent Management'), findsOneWidget);
    expect(find.text('Open Agent Management (Pro)'), findsNothing);
  });

  testWidgets('an SSH error while installing MonkeyMux is reported', (
    tester,
  ) async {
    final host = _host(keyId: 1, password: null);
    await pump(
      tester,
      host: host,
      connected: {7: host.id},
      probes: {
        host.id: const HostSetupProbeResult(
          connectionId: 7,
          monkeyMuxInstalled: false,
          agentsDetected: true,
        ),
      },
      installer: _FailingInstaller(),
      child: const HostSetupChecklistSheet(hostId: 3),
    );

    await tester.tap(find.text('Install MonkeyMux'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Couldn’t install MonkeyMux. Check the connection and try again.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('an agent chat started anywhere completes the sign-in step', (
    tester,
  ) async {
    final host = _host(keyId: 1, password: null);
    await tester.runAsync(
      () => HostSetupChecklistStore(SettingsService(db))
          .markDone(host.id, {HostSetupStep.monkeyMux, HostSetupStep.agents}),
    );
    await pump(
      tester,
      host: host,
      child: HostSetupChecklistLine(host: host),
    );
    expect(find.text('sign in to an agent'), findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(HostSetupChecklistLine)),
    );
    await tester.runAsync(
      () => container
          .read(acpRecentSessionsServiceProvider)
          .record(
            AcpRecentSessionRef(
              hostId: host.id,
              providerId: 'claude',
              bridgeId: 'bridge',
              acpSessionId: 'session',
              createdAt: DateTime(2026, 10),
              lastActivityAt: DateTime(2026, 10),
            ),
          ),
    );
    await tester.pumpAndSettle();

    expect(find.text('sign in to an agent'), findsNothing);
    expect(find.textContaining('/4 · '), findsNothing);
  });

  testWidgets('a key host stays quiet until a probe has run', (tester) async {
    final host = _host(keyId: 1, password: null);
    await pump(
      tester,
      host: host,
      child: HostSetupChecklistLine(host: host),
    );
    expect(find.textContaining('/4 · '), findsNothing);
  });

  testWidgets('probes a connected host once and shows the next step', (
    tester,
  ) async {
    var probes = 0;
    final host = _host(keyId: 1, password: null);
    await pump(
      tester,
      host: host,
      connected: {7: host.id},
      prober: HostSetupProber(
        probeMonkeyMux: (_) async {
          probes++;
          return false;
        },
        probeAgents: (_) async => true,
      ),
      child: HostSetupChecklistLine(host: host),
    );
    await tester.pumpAndSettle();

    expect(probes, 1);
    expect(find.text('2/4 · '), findsOneWidget);
    expect(find.text('install MonkeyMux'), findsOneWidget);
    final states = await tester.runAsync(
      () => HostSetupChecklistStore(SettingsService(db)).load(),
    );
    expect(states![3]!.done, {HostSetupStep.agents});

    // Rebuilding does not probe the same connection again.
    await tester.pump();
    await tester.pumpAndSettle();
    expect(probes, 1);
  });

  testWidgets('a reconnect probes again after a negative result', (
    tester,
  ) async {
    final probedConnections = <int>[];
    final host = _host(keyId: 1, password: null);
    final prober = HostSetupProber(
      probeMonkeyMux: (session) async {
        probedConnections.add(session.connectionId);
        return false;
      },
      probeAgents: (_) async => true,
    );
    await pump(
      tester,
      host: host,
      connected: {7: host.id},
      prober: prober,
      child: HostSetupChecklistLine(host: host),
    );
    expect(probedConnections, [7]);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(HostSetupChecklistLine)),
    );
    (container.read(activeSessionsProvider.notifier) as _Sessions).reconnect(
      8,
      host.id,
    );
    await tester.pumpAndSettle();
    expect(probedConnections, [7, 8]);
  });

  testWidgets('the card numbers the next step by its position', (tester) async {
    final host = _host(keyId: 1, password: null);
    await pump(
      tester,
      host: host,
      probes: {
        host.id: const HostSetupProbeResult(
          connectionId: 7,
          monkeyMuxInstalled: false,
          agentsDetected: true,
        ),
      },
      child: const HostSetupEmptyStateCard(),
    );
    // Agents are detected but MonkeyMux is missing: MonkeyMux is step 2.
    expect(find.text('Next: install MonkeyMux (step 2 of 4).'), findsOneWidget);
  });

  testWidgets('the empty-state card points at the next step', (tester) async {
    final host = _host();
    await pump(tester, host: host, child: const HostSetupEmptyStateCard());

    expect(
      find.textContaining('Finish setting up', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.text('Next: switch to key login (step 1 of 4).'),
      findsOneWidget,
    );
    await tester.tap(find.text('Continue Setup'));
    await tester.pumpAndSettle();
    expect(find.text('Host Setup'), findsOneWidget);
  });
}

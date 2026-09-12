// ignore_for_file: public_member_api_docs, avoid_positional_boolean_parameters
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:monkeyssh/app/routes.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/agent_usage.dart';
import 'package:monkeyssh/domain/models/agent_usage_rings.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/services/agent_management_service.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/providers/agent_usage_rings_provider.dart';
import 'package:monkeyssh/presentation/widgets/agent_usage_rings.dart';
import 'package:monkeyssh/presentation/widgets/agent_usage_rings_menu_item.dart';
import 'package:monkeyssh/presentation/widgets/premium_badge.dart';

MonetizationState access(bool pro) => MonetizationState(
  billingAvailability: MonetizationBillingAvailability.unavailable,
  entitlements: pro
      ? const MonetizationEntitlements.pro()
      : const MonetizationEntitlements.free(),
  offers: const [],
  debugUnlockAvailable: false,
  debugUnlocked: false,
);

class Session extends Fake implements SshSession {
  @override
  int get connectionId => 7;
}

class Connections extends ActiveSessionsNotifier {
  @override
  Map<int, SshConnectionState> build() => {7: SshConnectionState.connected};
  void markDisconnected() => state = {7: SshConnectionState.disconnected};
}

class Billing extends Fake implements MonetizationService {
  Billing(this.pro);
  bool pro;
  @override
  MonetizationState get currentState => access(pro);
  @override
  Future<bool> canUseFeature(MonetizationFeature feature) async => pro;
}

class Preference extends ShowUsageRingsNotifier {
  Preference(this.enabled);
  bool enabled;
  @override
  bool build() => enabled;
  @override
  Future<bool> initializedValue() async => state;
  @override
  Future<void> setEnabled({required bool enabled}) async =>
      state = this.enabled = enabled;
}

class Reader extends Fake implements AgentManagementService {
  int calls = 0;
  DateTime now = DateTime.utc(2026, 9, 8);
  Completer<AgentUsage?>? pending;
  final pendingByTool = <AgentLaunchTool, Completer<AgentUsage?>>{};
  DateTime? reset;
  AgentUsageStatus status = AgentUsageStatus.available;
  @override
  Future<AgentUsage?> readUsageForTool(
    SshSession session,
    AgentLaunchTool tool, {
    bool Function()? shouldContinue,
  }) async {
    calls++;
    if (pendingByTool[tool] case final pending?) return pending.future;
    if (pending != null) return pending!.future;
    return AgentUsage(
      status: status,
      checkedAt: now,
      windows: [
        AgentUsageWindow(
          label: '5 hours',
          usedPercent: tool == AgentLaunchTool.codex ? 70 : 42,
          resetsAt: reset,
        ),
        const AgentUsageWindow(label: 'Weekly', usedPercent: 18),
      ],
    );
  }
}

class RecordingRingCanvas extends Fake implements Canvas {
  final arcs =
      <({double start, double sweep, double strokeWidth, Color color})>[];

  @override
  void drawArc(
    Rect rect,
    double startAngle,
    double sweepAngle,
    bool useCenter,
    Paint paint,
  ) {
    arcs.add((
      start: startAngle,
      sweep: sweepAngle,
      strokeWidth: paint.strokeWidth,
      color: paint.color,
    ));
  }
}

void main() {
  testWidgets(
    'missing half is dashed, zero is empty, and weekly fill remains 77 percent',
    (tester) async {
      for (final shortTerm in <double?>[null, 0, 77, 100]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SplitUsageRing(
                rings: AgentUsageRings(shortTerm: shortTerm, weekly: 77),
                agentLabel: 'Codex',
                child: const Icon(Icons.code, size: 16),
              ),
            ),
          ),
        );
        final painter = tester
            .widget<CustomPaint>(find.byKey(const ValueKey('split-usage-ring')))
            .painter!;
        final canvas = RecordingRingCanvas();
        painter.paint(canvas, const Size(28, 28));
        final top = canvas.arcs.where((arc) => arc.start < 0).toList();
        final bottom = canvas.arcs.where((arc) => arc.start > 0).toList();
        const sweep = math.pi - 2 * math.pi / 22.5;
        expect(bottom, hasLength(2));
        expect(bottom[0].sweep, closeTo(sweep, 0.00001));
        expect(bottom[1].sweep, closeTo(sweep * .77, 0.00001));
        if (shortTerm == null) {
          expect(top, hasLength(6));
          expect(
            top.every(
              (arc) =>
                  (arc.strokeWidth - 1.2).abs() < 0.001 &&
                  arc.sweep < sweep / 6,
            ),
            isTrue,
          );
          final handle = tester.ensureSemantics();
          try {
            expect(
              tester.getSemantics(find.byType(SplitUsageRing)).value,
              '5-hour: not reported; weekly: 77 percent remaining',
            );
          } finally {
            handle.dispose();
          }
        } else if (shortTerm == 0) {
          expect(top, hasLength(1));
          expect(top.single.sweep, closeTo(sweep, 0.00001));
        } else {
          expect(top, hasLength(2));
          expect(top[1].sweep, closeTo(sweep * shortTerm / 100, 0.00001));
        }
      }
    },
  );

  testWidgets('split ring stays non-interactive and fits the existing bar', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: GestureDetector(
            onTap: () => taps++,
            child: const SizedBox(
              height: 44,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SplitUsageRing(
                    rings: AgentUsageRings(shortTerm: 0, weekly: 82),
                    agentLabel: 'Claude Code',
                    child: Icon(Icons.code, size: 16),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('split-usage-ring'))),
      const Size(28, 28),
    );
    await tester.tap(find.byKey(const ValueKey('split-usage-ring')));
    expect(taps, 1);
    final semantics = tester.ensureSemantics();
    try {
      expect(
        tester.getSemantics(find.byType(SplitUsageRing)).value,
        '5-hour: 0 percent remaining; weekly: 82 percent remaining',
      );
    } finally {
      semantics.dispose();
    }
    expect(tester.takeException(), isNull);
  });

  Future<ProviderContainer> pumpIcon(
    WidgetTester tester,
    Reader reader,
    Billing billing,
    Preference preference, {
    Stream<MonetizationState>? changes,
    Widget? body,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          agentManagementServiceProvider.overrideWithValue(reader),
          monetizationServiceProvider.overrideWithValue(billing),
          monetizationStateProvider.overrideWith(
            (ref) => changes ?? Stream.value(billing.currentState),
          ),
          showUsageRingsNotifierProvider.overrideWith(() => preference),
          activeSessionsProvider.overrideWith(Connections.new),
          agentUsageRingsClockProvider.overrideWithValue(() => reader.now),
        ],
        child: MaterialApp(
          home: Scaffold(
            body:
                body ??
                AgentUsageRingIcon(
                  session: Session(),
                  tool: AgentLaunchTool.claudeCode,
                  child: const Icon(Icons.code, size: 16),
                ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.byType(Scaffold)));
  }

  for (final pro in [false, true]) {
    testWidgets('no remote reads when ${pro ? 'disabled' : 'free'}', (
      tester,
    ) async {
      final reader = Reader();
      await pumpIcon(tester, reader, Billing(pro), Preference(!pro));
      expect(reader.calls, 0);
      expect(find.byType(SplitUsageRing), findsNothing);
      await tester.pump(const Duration(minutes: 3));
      expect(reader.calls, 0);
    });
  }
  testWidgets(
    'foreground refresh, opt-out, background, and reconnect stop reads',
    (tester) async {
      final reader = Reader();
      final preference = Preference(true);
      final container = await pumpIcon(
        tester,
        reader,
        Billing(true),
        preference,
      );
      expect(reader.calls, 1);
      expect(find.byType(SplitUsageRing), findsOneWidget);
      reader.now = reader.now.add(const Duration(minutes: 2));
      await tester.pump(const Duration(minutes: 2));
      await tester.pumpAndSettle();
      expect(reader.calls, 2);
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      // Paused Flutter apps do not render frames; polling must stop without a rebuild.
      await tester.pump(const Duration(minutes: 3));
      expect(reader.calls, 2);
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(reader.calls, 3);
      await preference.setEnabled(enabled: false);
      await tester.pumpAndSettle();
      expect(find.byType(SplitUsageRing), findsNothing);
      await tester.pump(const Duration(minutes: 3));
      expect(reader.calls, 3);
      await preference.setEnabled(enabled: true);
      await tester.pumpAndSettle();
      expect(reader.calls, 4);
      (container.read(activeSessionsProvider.notifier) as Connections)
          .markDisconnected();
      await tester.pumpAndSettle();
      expect(find.byType(SplitUsageRing), findsNothing);
      await tester.pump(const Duration(minutes: 3));
      expect(reader.calls, 4);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('revoked Pro cancels polling and ignores a late response', (
    tester,
  ) async {
    final reader = Reader()..pending = Completer<AgentUsage?>();
    final changes = StreamController<MonetizationState>();
    final billing = Billing(true);
    await pumpIcon(
      tester,
      reader,
      billing,
      Preference(true),
      changes: changes.stream,
    );
    expect(reader.calls, 1);
    billing.pro = false;
    changes.add(access(false));
    await tester.pumpAndSettle();
    reader.pending!.complete(
      AgentUsage(
        status: AgentUsageStatus.available,
        checkedAt: reader.now,
        windows: const [AgentUsageWindow(label: '5 hours', usedPercent: 42)],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SplitUsageRing), findsNothing);
    await tester.pump(const Duration(minutes: 3));
    expect(reader.calls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    unawaited(changes.close());
  });
  testWidgets('probe: two visible consumers share one remote request', (
    tester,
  ) async {
    final reader = Reader();
    final session = Session();
    await pumpIcon(
      tester,
      reader,
      Billing(true),
      Preference(true),
      body: Row(
        children: [
          for (var i = 0; i < 2; i++)
            AgentUsageRingIcon(
              session: session,
              tool: AgentLaunchTool.claudeCode,
              child: const Icon(Icons.code),
            ),
        ],
      ),
    );
    expect(reader.calls, 1);
    expect(find.byType(SplitUsageRing), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('probe: switching tools ignores the old window response', (
    tester,
  ) async {
    final reader = Reader();
    final old = Completer<AgentUsage?>();
    reader.pendingByTool[AgentLaunchTool.claudeCode] = old;
    final session = Session();
    var tool = AgentLaunchTool.claudeCode;
    late StateSetter update;
    await pumpIcon(
      tester,
      reader,
      Billing(true),
      Preference(true),
      body: StatefulBuilder(
        builder: (_, setState) {
          update = setState;
          return AgentUsageRingIcon(
            session: session,
            tool: tool,
            child: const Icon(Icons.code),
          );
        },
      ),
    );
    expect(reader.calls, 1);
    update(() => tool = AgentLaunchTool.codex);
    await tester.pumpAndSettle();
    expect(reader.calls, 2);
    expect(
      tester
          .widget<SplitUsageRing>(find.byType(SplitUsageRing))
          .rings
          .shortTerm,
      30,
    );
    old.complete(
      AgentUsage(
        status: AgentUsageStatus.available,
        checkedAt: reader.now,
        windows: const [AgentUsageWindow(label: '5 hours', usedPercent: 1)],
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SplitUsageRing>(find.byType(SplitUsageRing))
          .rings
          .shortTerm,
      30,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'probe: passed resets refresh once without refilling or looping',
    (tester) async {
      final reader = Reader();
      reader.reset = reader.now.add(const Duration(seconds: 30));
      await pumpIcon(tester, reader, Billing(true), Preference(true));
      expect(reader.calls, 1);
      reader.now = reader.now.add(const Duration(seconds: 30));
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(reader.calls, 2);
      final rings = tester
          .widget<SplitUsageRing>(find.byType(SplitUsageRing))
          .rings;
      expect(rings.shortTerm, isNull);
      expect(rings.weekly, 82);
      await tester.pump(const Duration(seconds: 60));
      expect(reader.calls, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('probe: provider throttling does not retry at an earlier reset', (
    tester,
  ) async {
    final reader = Reader()..status = AgentUsageStatus.rateLimited;
    reader.reset = reader.now.add(const Duration(seconds: 30));
    await pumpIcon(tester, reader, Billing(true), Preference(true));
    reader.now = reader.now.add(const Duration(seconds: 30));
    await tester.pump(const Duration(seconds: 30));
    expect(reader.calls, 1);
    expect(find.byType(SplitUsageRing), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('offstage ticker does not subscribe to remote usage', (
    tester,
  ) async {
    final reader = Reader();
    await pumpIcon(
      tester,
      reader,
      Billing(true),
      Preference(true),
      body: TickerMode(
        enabled: false,
        child: AgentUsageRingIcon(
          session: Session(),
          tool: AgentLaunchTool.claudeCode,
          child: const Icon(Icons.code),
        ),
      ),
    );
    expect(reader.calls, 0);
  });
  testWidgets(
    'covered terminal route stops polling until it becomes current again',
    (tester) async {
      final reader = Reader();
      await pumpIcon(tester, reader, Billing(true), Preference(true));
      final navigator = Navigator.of(
        tester.element(find.byType(AgentUsageRingIcon)),
      );
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Other screen')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      reader.now = reader.now.add(const Duration(minutes: 3));
      await tester.pump(const Duration(minutes: 3));
      expect(reader.calls, 1);
      navigator.pop();
      await tester.pumpAndSettle();
      expect(reader.calls, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('dismissed Options submenu still applies its checkbox action', (
    tester,
  ) async {
    final preference = Preference(true);
    await pumpIcon(
      tester,
      Reader(),
      Billing(true),
      preference,
      body: MenuAnchor(
        menuChildren: const [
          SubmenuButton(
            menuChildren: [AgentUsageRingsMenuItem()],
            child: Text('Options'),
          ),
        ],
        builder: (_, controller, _) => TextButton(
          onPressed: controller.open,
          child: const Text('Open menu'),
        ),
      ),
    );
    await tester.tap(find.text('Open menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show usage rings'));
    await tester.pumpAndSettle();
    expect(preference.enabled, isFalse);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Pro options checkbox toggles the actual persisted preference', (
    tester,
  ) async {
    final preference = Preference(true);
    await pumpIcon(
      tester,
      Reader(),
      Billing(true),
      preference,
      body: const AgentUsageRingsMenuItem(),
    );
    expect(find.text('Show usage rings'), findsOneWidget);
    expect(find.byType(PremiumBadge), findsNothing);
    expect(
      tester.widget<CheckboxMenuButton>(find.byType(CheckboxMenuButton)).value,
      isTrue,
    );
    await tester.tap(find.text('Show usage rings'));
    await tester.pumpAndSettle();
    expect(preference.enabled, isFalse);
    expect(
      tester.widget<CheckboxMenuButton>(find.byType(CheckboxMenuButton)).value,
      isFalse,
    );
  });
  testWidgets(
    'free option shows Pro and routes to the correct upgrade feature',
    (tester) async {
      final preference = Preference(true);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(body: AgentUsageRingsMenuItem()),
          ),
          GoRoute(
            path: '/upgrade',
            name: Routes.upgrade,
            builder: (_, state) => Scaffold(
              body: Text('Upgrade ${state.uri.queryParameters['feature']}'),
            ),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            monetizationServiceProvider.overrideWithValue(Billing(false)),
            monetizationStateProvider.overrideWith(
              (ref) => Stream.value(access(false)),
            ),
            showUsageRingsNotifierProvider.overrideWith(() => preference),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PremiumBadge), findsOneWidget);
      expect(
        tester
            .widget<CheckboxMenuButton>(find.byType(CheckboxMenuButton))
            .value,
        isFalse,
      );
      await tester.tap(find.text('Show usage rings'));
      await tester.pumpAndSettle();
      expect(find.text('Upgrade agentUsageRings'), findsOneWidget);
      expect(preference.enabled, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
    },
  );
}

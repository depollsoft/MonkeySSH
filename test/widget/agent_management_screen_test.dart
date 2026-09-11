// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/agent_runtime_info.dart';
import 'package:monkeyssh/domain/models/agent_usage.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/services/agent_management_service.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/screens/agent_management_screen.dart';

class _MockAgentManagementService extends Mock
    implements AgentManagementService {}

class _MockSshSession extends Mock implements SshSession {}

class _MockMonetizationService extends Mock implements MonetizationService {}

void main() {
  late _MockAgentManagementService service;
  late _MockSshSession session;
  late List<AgentRuntimeInfo> runtimes;
  late MonetizationState access;
  late _MockMonetizationService billing;

  setUp(() {
    access = const MonetizationState(
      billingAvailability: MonetizationBillingAvailability.available,
      entitlements: MonetizationEntitlements.pro(),
      offers: [],
      debugUnlockAvailable: false,
      debugUnlocked: false,
    );
    billing = _MockMonetizationService();
    when(() => billing.currentState).thenAnswer((_) => access);
    when(
      () => billing.canUseFeature(MonetizationFeature.agentManagement),
    ).thenAnswer((_) async => access.isProUnlocked);
    service = _MockAgentManagementService();

    session = _MockSshSession();
    when(() => service.readUsage(session, any())).thenAnswer((_) async => {});
    runtimes = [
      AgentRuntimeInfo(
        definition: agentCliRuntimeDefinitions.first,
        status: AgentRuntimeStatus.updateAvailable,
        installedVersion: '1.0.0',
        latestVersion: '1.1.0',
        executablePath: '/opt/homebrew/bin/claude',
        detectionSource: 'Homebrew',
        managedByPackageManager: true,
      ),
      AgentRuntimeInfo(
        definition: agentCliRuntimeDefinitions[1],
        status: AgentRuntimeStatus.notInstalled,
        latestVersion: '1.0.0',
      ),
      AgentRuntimeInfo(
        definition: agentStandaloneAcpRuntimeDefinitions.first,
        status: AgentRuntimeStatus.installed,
        installedVersion: '1.0.0',
        executablePath: '/usr/local/bin/copilot',
        detectionSource: 'npm or PATH',
      ),
    ];
    when(
      () =>
          service.refreshAll(session, onDiscovered: any(named: 'onDiscovered')),
    ).thenAnswer((_) async => runtimes);
  });

  Future<void> pumpScreen(
    WidgetTester tester, {
    Stream<MonetizationState>? states,
    TextScaler? textScaler,
    bool settle = true,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          monetizationServiceProvider.overrideWithValue(billing),
          monetizationStateProvider.overrideWith(
            (ref) => states ?? Stream.value(access),
          ),
        ],
        child: MaterialApp(
          builder: textScaler == null
              ? null
              : (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaler: textScaler),
                  child: child!,
                ),
          home: AgentManagementScreen(session: session, service: service),
        ),
      ),
    );
    if (settle) await tester.pumpAndSettle();
  }

  /// Advances frames while indeterminate spinners keep the tree from settling.
  Future<void> pumpFrames(WidgetTester tester, {int count = 8}) async {
    for (var i = 0; i < count; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Finder inRow(String id, Finder matching) => find.descendant(
    of: find.byKey(ValueKey('agent-runtime-$id')),
    matching: matching,
  );

  VoidCallback? refreshHandler(WidgetTester tester) => tester
      .widget<IconButton>(
        find.byKey(const ValueKey('agent-management-refresh')),
      )
      .onPressed;

  VoidCallback? recheckHandler(WidgetTester tester, String id) => tester
      .widget<IconButton>(find.byKey(ValueKey('agent-recheck-$id')))
      .onPressed;

  AgentRuntimeInfo installedFrom(AgentRuntimeInfo runtime) => AgentRuntimeInfo(
    definition: runtime.definition,
    status: AgentRuntimeStatus.installed,
    installedVersion: runtime.latestVersion,
    executablePath: runtime.executablePath,
    detectionSource: runtime.detectionSource,
    managedByPackageManager: true,
  );

  AgentRuntimeInfo secondUpdate({bool withMetadata = true}) => AgentRuntimeInfo(
    definition: agentCliRuntimeDefinitions[1],
    status: AgentRuntimeStatus.updateAvailable,
    installedVersion: '2.0.0',
    latestVersion: '2.1.0',
    executablePath: withMetadata ? '/usr/local/bin/copilot' : null,
    detectionSource: withMetadata ? 'npm global' : null,
    managedByPackageManager: true,
  );

  Future<AgentRuntimeActionResult> updateRuntime(AgentRuntimeInfo runtime) =>
      service.installOrUpdate(
        session,
        runtime.definition,
        update: true,
        current: runtime,
        onOutput: any(named: 'onOutput'),
      );

  void replaceRuntime(AgentRuntimeInfo runtime) {
    final index = runtimes.indexWhere(
      (entry) => entry.definition.id == runtime.definition.id,
    );
    runtimes[index] = runtime;
  }

  testWidgets('usage starts before upstream version metadata completes', (
    tester,
  ) async {
    final metadata = Completer<List<AgentRuntimeInfo>>();
    when(
      () =>
          service.refreshAll(session, onDiscovered: any(named: 'onDiscovered')),
    ).thenAnswer((invocation) {
      final callback =
          invocation.namedArguments[#onDiscovered]
              as void Function(List<AgentRuntimeInfo>);
      callback(runtimes);
      return metadata.future;
    });
    when(() => service.readUsage(session, any())).thenAnswer(
      (_) async => {
        runtimes.first.definition.id: const AgentUsage(
          status: AgentUsageStatus.available,
          windows: [AgentUsageWindow(label: 'Weekly', usedPercent: 25)],
        ),
      },
    );
    await pumpScreen(tester, settle: false);
    await pumpFrames(tester);
    expect(metadata.isCompleted, isFalse);
    expect(find.text('Weekly · 75% remaining'), findsOneWidget);
    metadata.complete(runtimes);
    await tester.pumpAndSettle();
    verify(() => service.readUsage(session, any())).called(1);
  });

  testWidgets('usage loads independently and refreshes with runtime checks', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final pending = Completer<Map<String, AgentUsage>>();
    when(
      () => service.readUsage(session, any()),
    ).thenAnswer((_) => pending.future);
    await pumpScreen(tester);
    expect(find.text('Checking usage…'), findsWidgets);
    final announcement = find.byKey(const ValueKey('agent-usage-announcement'));
    expect(
      tester.widget<Semantics>(announcement).properties.liveRegion,
      isTrue,
    );
    expect(
      tester.getSemantics(announcement).label,
      contains('Checking account usage.'),
    );
    expect(refreshHandler(tester), isNotNull);
    pending.complete({
      'cli:claude': AgentUsage(
        status: AgentUsageStatus.available,
        windows: [
          AgentUsageWindow(
            label: '5 hours',
            usedPercent: 100,
            resetsAt: DateTime.now().add(const Duration(hours: 1)),
          ),
        ],
      ),
    });
    await tester.pumpAndSettle();
    expect(find.text('5 hours · 0% remaining · Limit reached'), findsOneWidget);
    expect(
      tester.getSemantics(announcement).label,
      contains('Account usage checks complete.'),
    );
    await tester.tap(find.byKey(const ValueKey('agent-management-refresh')));
    await tester.pumpAndSettle();
    verify(() => service.readUsage(session, any())).called(2);
    semantics.dispose();
  });

  for (final id in ['cli:antigravity', 'cli:cursor', 'cli:grok']) {
    testWidgets('$id offers Install and runs the managed action', (
      tester,
    ) async {
      final definition = agentCliRuntimeDefinitions.singleWhere(
        (d) => d.id == id,
      );
      final missing = AgentRuntimeInfo(
        definition: definition,
        status: AgentRuntimeStatus.notInstalled,
      );
      runtimes = [missing];
      when(
        () => service.installOrUpdate(
          session,
          definition,
          update: false,
          current: missing,
          onOutput: any(named: 'onOutput'),
        ),
      ).thenAnswer((_) async {
        runtimes = [
          AgentRuntimeInfo(
            definition: definition,
            status: AgentRuntimeStatus.installed,
            installedVersion: '1.2.3',
          ),
        ];
        return const AgentRuntimeActionResult(
          succeeded: true,
          output: 'installed',
        );
      });
      await pumpScreen(tester);
      expect(find.text('Install'), findsOneWidget);
      final action = find.byKey(ValueKey('agent-action-$id'));
      expect(tester.widget<OutlinedButton>(action).onPressed, isNotNull);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(find.text('Installed v1.2.3'), findsOneWidget);
      verify(
        () => service.installOrUpdate(
          session,
          definition,
          update: false,
          current: missing,
          onOutput: any(named: 'onOutput'),
        ),
      ).called(1);
    });
  }

  testWidgets('free users cannot probe a directly opened manager', (
    tester,
  ) async {
    access = access.copyWith(
      entitlements: const MonetizationEntitlements.free(),
    );
    await pumpScreen(tester);
    expect(find.text('Agent Management requires Pro'), findsOneWidget);
    expect(find.text('Unlock Pro'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('agent-management-refresh')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('agent-update-all')), findsNothing);
    verifyNever(
      () =>
          service.refreshAll(session, onDiscovered: any(named: 'onDiscovered')),
    );
    await tester.tap(find.text('Unlock Pro'));
    await tester.pumpAndSettle();
    expect(find.text('Manage remote coding agents'), findsOneWidget);
    verifyNever(
      () =>
          service.refreshAll(session, onDiscovered: any(named: 'onDiscovered')),
    );
  });

  testWidgets('revoking Pro hides manager controls and blocks stale actions', (
    tester,
  ) async {
    final states = StreamController<MonetizationState>();
    addTearDown(states.close);
    await pumpScreen(tester, states: states.stream);
    final action = tester
        .widget<OutlinedButton>(
          find.byKey(const ValueKey('agent-action-cli:claude')),
        )
        .onPressed!;
    clearInteractions(service);
    access = access.copyWith(
      entitlements: const MonetizationEntitlements.free(),
    );
    action();
    states.add(access);
    await tester.pumpAndSettle();
    expect(find.text('Agent Management requires Pro'), findsOneWidget);
    expect(find.byKey(const ValueKey('agent-action-cli:claude')), findsNothing);
    verifyNever(
      () => service.installOrUpdate(
        session,
        runtimes.first.definition,
        update: true,
        current: runtimes.first,
        onOutput: any(named: 'onOutput'),
      ),
    );
    verifyNever(
      () =>
          service.refreshAll(session, onDiscovered: any(named: 'onDiscovered')),
    );
  });

  testWidgets('store capture redacts executable paths in rows and details', (
    tester,
  ) async {
    const redacted = bool.fromEnvironment('STORE_SCREENSHOT_REDACT_IDENTITIES');
    const path = '/Users/private-owner/.local/bin/claude';
    runtimes = [
      AgentRuntimeInfo(
        definition: agentCliRuntimeDefinitions.first,
        status: AgentRuntimeStatus.installed,
        installedVersion: '2.1.0',
        executablePath: path,
        detectionSource: 'PATH',
      ),
    ];
    await pumpScreen(tester);
    expect(
      find.text(redacted ? 'PATH · claude' : 'PATH · $path'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('agent-details-cli:claude')));
    await tester.pumpAndSettle();
    expect(find.text(redacted ? 'claude' : path), findsOneWidget);
    expect(
      find.textContaining('private-owner'),
      redacted ? findsNothing : findsWidgets,
    );
    expect(find.text('Installed v2.1.0'), findsOneWidget);
  });

  testWidgets('renders CLI and ACP status with source paths', (tester) async {
    await pumpScreen(tester);

    expect(find.text('Agent Management'), findsOneWidget);
    expect(find.text('agent CLIs'), findsOneWidget);
    expect(find.text('ACP adapters'), findsOneWidget);
    expect(find.text('Update v1.0.0 → v1.1.0'), findsOneWidget);
    expect(
      find.text(
        const bool.fromEnvironment('STORE_SCREENSHOT_REDACT_IDENTITIES')
            ? 'Homebrew · claude'
            : 'Homebrew · /opt/homebrew/bin/claude',
      ),
      findsOneWidget,
    );
    expect(find.text('Not installed · latest v1.0.0'), findsOneWidget);
    expect(find.text('Installed v1.0.0'), findsOneWidget);
  });

  testWidgets('compact rows avoid overflow on narrow phones', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    runtimes[0] = AgentRuntimeInfo(
      definition: agentCliRuntimeDefinitions.first,
      status: AgentRuntimeStatus.updateAvailable,
      installedVersion: '2026.08.12345',
      latestVersion: '2026.09.67890',
      executablePath:
          '/Users/developer/.local/share/version-manager/bin/claude-code',
      detectionSource: 'npm global package manager',
      managedByPackageManager: true,
    );

    await pumpScreen(tester);

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('agent-action-cli:claude')),
      findsOneWidget,
    );
  });

  testWidgets('repairs an agent with skipped install scripts', (tester) async {
    final broken = AgentRuntimeInfo(
      definition: agentCliRuntimeDefinitions.firstWhere(
        (definition) => definition.id == 'cli:opencode',
      ),
      status: AgentRuntimeStatus.needsRepair,
      executablePath: '/usr/local/bin/opencode',
      detectionSource: 'npm global',
      managedByPackageManager: true,
      message: 'Required setup scripts did not run.',
    );
    runtimes[1] = broken;
    when(
      () => service.installOrUpdate(
        session,
        broken.definition,
        update: false,
        current: broken,
        onOutput: any(named: 'onOutput'),
      ),
    ).thenAnswer((_) async {
      runtimes[1] = AgentRuntimeInfo(
        definition: broken.definition,
        status: AgentRuntimeStatus.installed,
        installedVersion: '0.5.2',
        executablePath: '/usr/local/bin/opencode',
        detectionSource: 'npm global',
        managedByPackageManager: true,
      );
      return const AgentRuntimeActionResult(
        succeeded: true,
        output: 'repaired',
      );
    });
    await pumpScreen(tester);

    expect(find.text('Needs repair'), findsOneWidget);
    await tester.tap(find.text('Repair'));
    await tester.pumpAndSettle();

    expect(find.text('OpenCode ready'), findsNothing);
    expect(find.text('Needs repair'), findsNothing);
    expect(find.text('Installed v0.5.2'), findsOneWidget);
    verify(
      () => service.installOrUpdate(
        session,
        broken.definition,
        update: false,
        current: broken,
        onOutput: any(named: 'onOutput'),
      ),
    ).called(1);
  });

  testWidgets('pull-to-refresh re-probes all runtimes', (tester) async {
    await pumpScreen(tester);
    clearInteractions(service);

    await tester.drag(
      find.byKey(const ValueKey('agent-management-list')),
      const Offset(0, 320),
    );
    await tester.pumpAndSettle();

    verify(
      () =>
          service.refreshAll(session, onDiscovered: any(named: 'onDiscovered')),
    ).called(1);
  });

  testWidgets('header refresh re-probes all runtimes', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.byKey(const ValueKey('agent-management-refresh')));
    await tester.pumpAndSettle();

    verify(
      () =>
          service.refreshAll(session, onDiscovered: any(named: 'onDiscovered')),
    ).called(2);
  });

  testWidgets(
    'installed CLI without an available update has no Update action',
    (tester) async {
      runtimes[0] = AgentRuntimeInfo(
        definition: agentCliRuntimeDefinitions.first,
        status: AgentRuntimeStatus.installed,
        executablePath: '/usr/local/bin/claude',
        detectionSource: 'PATH',
        managedByPackageManager: true,
      );
      await pumpScreen(tester);

      expect(find.text('Check & update'), findsNothing);
      expect(
        find.byKey(const ValueKey('agent-action-cli:claude')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('agent-recheck-cli:claude')),
        findsOneWidget,
      );
    },
  );

  testWidgets('Update all runs every confirmed update', (tester) async {
    final second = secondUpdate();
    runtimes[1] = second;
    final updates = [runtimes.first, second];
    for (final runtime in updates) {
      when(() => updateRuntime(runtime)).thenAnswer((_) async {
        replaceRuntime(installedFrom(runtime));
        return const AgentRuntimeActionResult(
          succeeded: true,
          output: 'updated',
        );
      });
    }
    await pumpScreen(tester);

    expect(find.text('2 updates available'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('agent-update-all')));
    await tester.pumpAndSettle();

    expect(find.text('All agents updated'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    for (final runtime in updates) {
      verify(() => updateRuntime(runtime)).called(1);
    }
  });

  for (final throws in [false, true]) {
    testWidgets(
      'Update all continues after ${throws ? 'an exception' : 'a failure'} '
      'and refreshes once',
      (tester) async {
        final first = runtimes.first;
        final second = secondUpdate(withMetadata: false);
        runtimes[1] = second;
        final started = <String>[];
        for (final runtime in [first, second]) {
          when(() => updateRuntime(runtime)).thenAnswer((_) async {
            started.add(runtime.definition.id);
            if (runtime == first && throws) {
              throw StateError('connection closed');
            }
            return AgentRuntimeActionResult(
              succeeded: runtime != first,
              output: 'finished',
            );
          });
        }
        await pumpScreen(tester);
        clearInteractions(service);
        await tester.tap(find.byKey(const ValueKey('agent-update-all')));
        await tester.pumpAndSettle();
        expect(started, [first.definition.id, second.definition.id]);
        expect(find.text('Some updates failed'), findsOneWidget);
        expect(
          find.text('Could not update ${first.definition.label}.'),
          findsOneWidget,
        );
        expect(find.byType(CircularProgressIndicator), findsNothing);
        verify(
          () => service.refreshAll(
            session,
            onDiscovered: any(named: 'onDiscovered'),
          ),
        ).called(1);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        expect(refreshHandler(tester), isNotNull);
      },
    );
  }

  testWidgets('action errors clear progress and show a failure dialog', (
    tester,
  ) async {
    when(
      () => service.installOrUpdate(
        session,
        agentCliRuntimeDefinitions.first,
        update: true,
        current: runtimes.first,
        onOutput: any(named: 'onOutput'),
      ),
    ).thenThrow(StateError('connection closed'));
    await pumpScreen(tester);

    await tester.tap(find.byKey(const ValueKey('agent-action-cli:claude')));
    await tester.pumpAndSettle();

    expect(find.text('Claude Code failed'), findsOneWidget);
    expect(find.textContaining('connection closed'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('agent-action-cli:claude')),
      findsOneWidget,
    );
  });

  testWidgets('successful update refreshes inline without a dialog', (
    tester,
  ) async {
    final current = runtimes.first;
    when(
      () => service.installOrUpdate(
        session,
        agentCliRuntimeDefinitions.first,
        update: true,
        current: current,
        onOutput: any(named: 'onOutput'),
      ),
    ).thenAnswer((invocation) async {
      final onOutput =
          invocation.namedArguments[#onOutput] as ValueChanged<String>?;
      onOutput?.call('updated package');
      runtimes[0] = AgentRuntimeInfo(
        definition: agentCliRuntimeDefinitions.first,
        status: AgentRuntimeStatus.installed,
        installedVersion: '1.1.0',
        executablePath: '/opt/homebrew/bin/claude',
        detectionSource: 'Homebrew',
        managedByPackageManager: true,
      );
      return const AgentRuntimeActionResult(
        succeeded: true,
        output: 'updated package',
        exitCode: 0,
      );
    });
    await pumpScreen(tester);

    await tester.tap(find.byKey(const ValueKey('agent-action-cli:claude')));
    await tester.pumpAndSettle();

    expect(find.text('Claude Code ready'), findsNothing);
    expect(find.text('updated package'), findsNothing);
    expect(find.text('Installed v1.1.0'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);

    verify(
      () => service.installOrUpdate(
        session,
        agentCliRuntimeDefinitions.first,
        update: true,
        current: current,
        onOutput: any(named: 'onOutput'),
      ),
    ).called(1);
    verify(
      () =>
          service.refreshAll(session, onDiscovered: any(named: 'onDiscovered')),
    ).called(2);
  });
  for (final returnsFailure in [false, true]) {
    testWidgets(
      'recheck ${returnsFailure ? 'returned failure' : 'exception'} shows an error dialog and restores the row',
      (tester) async {
        final acp = runtimes[2];
        final probe = Completer<AgentRuntimeInfo>();
        when(
          () => service.inspect(session, acp.definition),
        ).thenAnswer((_) => probe.future);
        await pumpScreen(tester);
        clearInteractions(service);
        final recheck = find.byKey(const ValueKey('agent-recheck-acp:claude'));

        await tester.ensureVisible(recheck);
        await tester.pumpAndSettle();
        await tester.tap(recheck);
        await pumpFrames(tester);

        expect(
          inRow('acp:claude', find.byType(CircularProgressIndicator)),
          findsOneWidget,
        );
        expect(inRow('acp:claude', find.text('Checking…')), findsOneWidget);
        expect(refreshHandler(tester), isNull);
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const ValueKey('agent-action-cli:claude')),
              )
              .onPressed,
          isNull,
        );

        if (returnsFailure) {
          probe.complete(
            AgentRuntimeInfo(
              definition: acp.definition,
              status: AgentRuntimeStatus.failed,
              message: 'probe timed out',
            ),
          );
        } else {
          probe.completeError(StateError('probe timed out'));
        }
        await pumpFrames(tester);

        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text('Claude Agent ACP failed'), findsOneWidget);
        expect(
          find.textContaining('Could not check this agent.'),
          findsOneWidget,
        );
        expect(find.textContaining('probe timed out'), findsOneWidget);

        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(
          inRow('acp:claude', find.text('Installed v1.0.0')),
          findsOneWidget,
        );
        expect(recheckHandler(tester, 'acp:claude'), isNotNull);
        expect(refreshHandler(tester), isNotNull);
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const ValueKey('agent-action-cli:claude')),
              )
              .onPressed,
          isNotNull,
        );
        verify(() => service.inspect(session, acp.definition)).called(1);
        verifyNever(
          () => service.refreshAll(
            session,
            onDiscovered: any(named: 'onDiscovered'),
          ),
        );

        when(() => service.inspect(session, acp.definition)).thenAnswer(
          (_) async => AgentRuntimeInfo(
            definition: acp.definition,
            status: AgentRuntimeStatus.installed,
            installedVersion: '1.2.0',
            executablePath: acp.executablePath,
            detectionSource: acp.detectionSource,
          ),
        );
        await tester.ensureVisible(recheck);
        await tester.pumpAndSettle();
        await tester.tap(recheck);
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsNothing);
        expect(
          inRow('acp:claude', find.text('Installed v1.2.0')),
          findsOneWidget,
        );
        verify(() => service.inspect(session, acp.definition)).called(1);
      },
    );
  }

  testWidgets('Update all queues later agents and locks competing commands', (
    tester,
  ) async {
    final second = secondUpdate();
    runtimes[1] = second;
    final updates = [runtimes.first, second];
    final started = <String>[];
    final completers = <String, Completer<AgentRuntimeActionResult>>{};
    for (final runtime in updates) {
      final id = runtime.definition.id;
      completers[id] = Completer<AgentRuntimeActionResult>();
      when(() => updateRuntime(runtime)).thenAnswer((_) {
        started.add(id);
        return completers[id]!.future;
      });
    }
    when(
      () =>
          service.refreshAll(session, onDiscovered: any(named: 'onDiscovered')),
    ).thenAnswer((_) async => runtimes.toList());
    await pumpScreen(tester);
    expect(find.text('2 updates available'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('agent-update-all')));
    await pumpFrames(tester);
    clearInteractions(service);

    expect(started, ['cli:claude']);
    expect(find.text('Updating 1 of 2'), findsOneWidget);
    final updateAll = tester.widget<FilledButton>(
      find.byKey(const ValueKey('agent-update-all')),
    );
    expect(updateAll.onPressed, isNull);
    expect(find.widgetWithText(FilledButton, 'Updating…'), findsOneWidget);
    expect(
      inRow('cli:claude', find.byType(CircularProgressIndicator)),
      findsOneWidget,
    );
    expect(inRow('cli:claude', find.text('Updating…')), findsOneWidget);
    expect(inRow('cli:copilot', find.text('Queued')), findsOneWidget);
    expect(inRow('cli:copilot', find.text('Updating…')), findsNothing);
    expect(
      inRow('cli:copilot', find.byType(CircularProgressIndicator)),
      findsNothing,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byKey(const ValueKey('agent-action-cli:claude')), findsNothing);
    expect(
      find.byKey(const ValueKey('agent-action-cli:copilot')),
      findsNothing,
    );
    expect(refreshHandler(tester), isNull);
    expect(recheckHandler(tester, 'acp:claude'), isNull);

    await tester.tap(find.byKey(const ValueKey('agent-management-refresh')));
    await tester.drag(
      find.byKey(const ValueKey('agent-management-list')),
      const Offset(0, 320),
    );
    await pumpFrames(tester, count: 30);
    final recheck = find.byKey(const ValueKey('agent-recheck-acp:claude'));
    await tester.ensureVisible(recheck);
    await pumpFrames(tester);
    await tester.tap(recheck);
    await pumpFrames(tester);
    verifyNever(
      () =>
          service.refreshAll(session, onDiscovered: any(named: 'onDiscovered')),
    );
    verifyNever(() => service.inspect(session, runtimes[2].definition));
    expect(started, ['cli:claude']);

    replaceRuntime(installedFrom(updates[0]));
    completers['cli:claude']!.complete(
      const AgentRuntimeActionResult(succeeded: true, output: 'updated'),
    );
    await pumpFrames(tester);

    expect(started, ['cli:claude', 'cli:copilot']);
    expect(find.text('Updating 2 of 2'), findsOneWidget);
    expect(
      inRow('cli:claude', find.text('Update v1.0.0 → v1.1.0')),
      findsOneWidget,
    );
    expect(
      inRow('cli:claude', find.byType(CircularProgressIndicator)),
      findsNothing,
    );
    expect(
      inRow('cli:copilot', find.byType(CircularProgressIndicator)),
      findsOneWidget,
    );
    expect(find.text('Queued'), findsNothing);
    expect(refreshHandler(tester), isNull);
    expect(recheckHandler(tester, 'acp:claude'), isNull);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('agent-update-all')))
          .onPressed,
      isNull,
    );
    verifyNever(
      () =>
          service.refreshAll(session, onDiscovered: any(named: 'onDiscovered')),
    );

    replaceRuntime(installedFrom(second));
    completers['cli:copilot']!.complete(
      const AgentRuntimeActionResult(succeeded: true, output: 'updated'),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Queued'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byKey(const ValueKey('agent-update-all')), findsNothing);
    expect(inRow('cli:copilot', find.text('Installed v2.1.0')), findsOneWidget);
    expect(refreshHandler(tester), isNotNull);
    expect(recheckHandler(tester, 'acp:claude'), isNotNull);
    verify(
      () =>
          service.refreshAll(session, onDiscovered: any(named: 'onDiscovered')),
    ).called(1);
  });

  testWidgets('revoking Pro mid-queue stops the remaining bulk updates', (
    tester,
  ) async {
    final states = StreamController<MonetizationState>();
    addTearDown(states.close);
    final second = secondUpdate();
    runtimes[1] = second;
    final first = runtimes.first;
    final firstUpdate = Completer<AgentRuntimeActionResult>();
    when(() => updateRuntime(first)).thenAnswer((_) => firstUpdate.future);
    await pumpScreen(tester, states: states.stream);

    await tester.tap(find.byKey(const ValueKey('agent-update-all')));
    await pumpFrames(tester);
    expect(inRow('cli:copilot', find.text('Queued')), findsOneWidget);

    access = access.copyWith(
      entitlements: const MonetizationEntitlements.free(),
    );
    firstUpdate.complete(
      const AgentRuntimeActionResult(succeeded: true, output: 'updated'),
    );
    states.add(access);
    await tester.pumpAndSettle();

    expect(find.text('Agent Management requires Pro'), findsOneWidget);
    expect(find.byKey(const ValueKey('agent-update-all')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    verifyNever(
      () => service.installOrUpdate(
        session,
        second.definition,
        update: any(named: 'update'),
        current: any(named: 'current'),
        onOutput: any(named: 'onOutput'),
      ),
    );
  });

  testWidgets('expanding a row exposes the full path and versions as '
      'selectable text', (tester) async {
    const path =
        '/Users/developer/.local/share/version-manager/installs/'
        'node/22.4.1/lib/node_modules/@anthropic-ai/claude-code/bin/claude';
    runtimes[0] = AgentRuntimeInfo(
      definition: agentCliRuntimeDefinitions.first,
      status: AgentRuntimeStatus.updateAvailable,
      installedVersion: '1.0.0',
      latestVersion: '1.1.0',
      executablePath: path,
      detectionSource: 'npm global',
      managedByPackageManager: true,
    );
    await pumpScreen(tester);

    const displayPath =
        bool.fromEnvironment('STORE_SCREENSHOT_REDACT_IDENTITIES')
        ? 'claude'
        : path;
    final collapsedSource = find.text('npm global · $displayPath');
    expect(collapsedSource, findsOneWidget);
    expect(
      tester.widget<Text>(collapsedSource).overflow,
      TextOverflow.ellipsis,
    );
    expect(find.byType(SelectableText), findsNothing);
    final material = tester
        .element(find.byKey(const ValueKey('agent-details-cli:claude')))
        .findAncestorWidgetOfExactType<Material>();
    expect(material!.shape, isA<RoundedRectangleBorder>());
    expect(material.clipBehavior, Clip.antiAlias);

    await tester.tap(find.byKey(const ValueKey('agent-details-cli:claude')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(collapsedSource, findsNothing);
    for (final label in [
      'Installed version',
      'Latest version',
      'Install source',
      'Executable',
    ]) {
      expect(inRow('cli:claude', find.text(label)), findsOneWidget);
    }
    for (final value in ['1.0.0', '1.1.0', 'npm global', displayPath]) {
      final selectable = inRow(
        'cli:claude',
        find.widgetWithText(SelectableText, value),
      );
      expect(selectable, findsOneWidget, reason: '$value should be selectable');
      expect(tester.widget<SelectableText>(selectable).maxLines, isNull);
    }
    expect(inRow('acp:claude', find.byType(SelectableText)), findsNothing);
    expect(
      inRow('cli:claude', find.text('Update v1.0.0 → v1.1.0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('agent-action-cli:claude')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('agent-details-cli:claude')));
    await tester.pumpAndSettle();

    expect(collapsedSource, findsOneWidget);
    expect(inRow('cli:claude', find.byType(SelectableText)), findsNothing);
  });

  const layouts = <String, Size>{
    'phone portrait': Size(390, 844),
    'phone landscape': Size(844, 390),
    'tablet portrait': Size(820, 1180),
    'tablet landscape': Size(1180, 820),
  };
  for (final layout in layouts.entries) {
    for (final scale in const [1.0, 2.0]) {
      testWidgets('${layout.key} at ${scale}x text has no overflow and keeps '
          'Update all reachable', (tester) async {
        final size = layout.value;
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        runtimes[0] = AgentRuntimeInfo(
          definition: agentCliRuntimeDefinitions.first,
          status: AgentRuntimeStatus.updateAvailable,
          installedVersion: '2026.08.12345',
          latestVersion: '2026.09.67890',
          executablePath:
              '/Users/developer/.local/share/version-manager/installs/'
              'node/22.4.1/lib/node_modules/@anthropic-ai/claude-code/'
              'bin/claude',
          detectionSource: 'npm global package manager',
          managedByPackageManager: true,
        );
        runtimes[1] = AgentRuntimeInfo(
          definition: agentCliRuntimeDefinitions[1],
          status: AgentRuntimeStatus.needsRepair,
          executablePath: '/usr/local/bin/copilot',
          detectionSource: 'npm global',
          managedByPackageManager: true,
          message:
              'Required setup scripts did not run because the package '
              'was installed with --ignore-scripts.',
        );

        await pumpScreen(
          tester,
          textScaler: scale == 1.0 ? null : TextScaler.linear(scale),
        );

        expect(tester.takeException(), isNull);
        final updateAll = find.byKey(const ValueKey('agent-update-all'));
        expect(updateAll, findsOneWidget);
        expect(tester.widget<FilledButton>(updateAll).onPressed, isNotNull);
        final bar = tester.getRect(updateAll);
        expect(bar.top, greaterThanOrEqualTo(0));
        expect(bar.left, greaterThanOrEqualTo(0));
        expect(bar.right, lessThanOrEqualTo(size.width));
        expect(bar.bottom, lessThanOrEqualTo(size.height));
        expect(updateAll.hitTestable(), findsOneWidget);

        final lastRow = find.byKey(const ValueKey('agent-runtime-acp:claude'));
        await tester.scrollUntilVisible(
          lastRow,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        // The center of a tall row need not be visible at large text scales.
        // Check that its actual recheck control is reachable below.
        expect(lastRow, findsOneWidget);
        expect(updateAll.hitTestable(), findsOneWidget);
        final recheck = find.byKey(const ValueKey('agent-recheck-acp:claude'));
        await tester.ensureVisible(recheck);
        await tester.pumpAndSettle();
        expect(recheck.hitTestable(), findsOneWidget);
        expect(updateAll.hitTestable(), findsOneWidget);

        final details = find.byKey(const ValueKey('agent-details-cli:claude'));
        await tester.scrollUntilVisible(
          details,
          -200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(details);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(inRow('cli:claude', find.text('Executable')), findsOneWidget);
        expect(updateAll.hitTestable(), findsOneWidget);
        expect(
          tester.getRect(updateAll).bottom,
          lessThanOrEqualTo(size.height),
        );
      });
    }
  }

  testWidgets('Update all skips updates MonkeySSH cannot manage', (
    tester,
  ) async {
    final managed = runtimes.first;
    final unmanaged = AgentRuntimeInfo(
      definition: agentCliRuntimeDefinitions[1],
      status: AgentRuntimeStatus.updateAvailable,
      installedVersion: '2.0.0',
      latestVersion: '2.1.0',
      executablePath: '/opt/copilot/bin/copilot',
      detectionSource: 'manual install',
    );
    const unsupported = AgentRuntimeInfo(
      definition: AgentRuntimeDefinition(
        id: 'cli:unknown',
        label: 'Unknown',
        kind: AgentRuntimeKind.cli,
        executableNames: ['unknown'],
      ),
      status: AgentRuntimeStatus.updateAvailable,
      installedVersion: '0.9.0',
      latestVersion: '1.0.0',
      executablePath: '/usr/local/bin/cursor-agent',
      detectionSource: 'PATH',
    );
    final unavailable = AgentRuntimeInfo(
      definition: agentStandaloneAcpRuntimeDefinitions.first,
      status: AgentRuntimeStatus.unavailable,
      latestVersion: '1.0.0',
      message: 'Requires a supported platform.',
    );
    runtimes
      ..clear()
      ..addAll([managed, unmanaged, unsupported, unavailable]);
    when(
      () => service.installOrUpdate(
        session,
        managed.definition,
        update: true,
        current: managed,
        onOutput: any(named: 'onOutput'),
      ),
    ).thenAnswer((_) async {
      replaceRuntime(installedFrom(managed));
      return const AgentRuntimeActionResult(succeeded: true, output: 'ok');
    });
    await pumpScreen(tester);

    expect(find.byKey(const ValueKey('agent-update-all')), findsOneWidget);
    expect(find.text('3 updates available'), findsOneWidget);
    expect(find.text('2 require a manual update on the host.'), findsOneWidget);
    expect(find.text('Update 1'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('agent-action-cli:copilot')),
      findsNothing,
    );
    expect(
      find.byKey(ValueKey('agent-action-${unsupported.definition.id}')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('agent-action-acp:claude')), findsNothing);
    expect(
      find.byKey(const ValueKey('agent-recheck-cli:copilot')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('agent-details-cli:copilot')));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Update this installation on the host, then re-check its version.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('agent-update-all')));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(inRow('cli:claude', find.text('Installed v1.1.0')), findsOneWidget);
    expect(find.text('2 updates available'), findsOneWidget);
    expect(find.text('2 require a manual update on the host.'), findsOneWidget);
    expect(find.byKey(const ValueKey('agent-update-all')), findsNothing);
    expect(
      inRow('cli:copilot', find.text('Update v2.0.0 → v2.1.0')),
      findsOneWidget,
    );
    verify(
      () => service.installOrUpdate(
        session,
        managed.definition,
        update: true,
        current: managed,
        onOutput: any(named: 'onOutput'),
      ),
    ).called(1);
    for (final excluded in [unmanaged, unsupported, unavailable]) {
      verifyNever(
        () => service.installOrUpdate(
          session,
          excluded.definition,
          update: any(named: 'update'),
          current: any(named: 'current'),
          onOutput: any(named: 'onOutput'),
        ),
      );
    }
  });
}

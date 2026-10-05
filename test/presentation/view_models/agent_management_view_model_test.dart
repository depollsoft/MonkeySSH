import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/agent_runtime_info.dart';
import 'package:monkeyssh/domain/models/agent_usage.dart';
import 'package:monkeyssh/domain/services/agent_management_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/screens/agent_management_presentation.dart';
import 'package:monkeyssh/presentation/view_models/agent_management_view_model.dart';

class _Service extends Mock implements AgentManagementService {}

class _Session extends Mock implements SshSession {}

void main() {
  late _Service service;
  late _Session session;
  late AgentManagementViewModel model;
  late List<AgentRuntimeInfo> runtimes;
  late bool permitted;
  late List<String> failures;
  late List<String> bulkFailures;
  setUp(() {
    service = _Service();
    session = _Session();
    permitted = true;
    failures = [];
    bulkFailures = [];
    runtimes = [
      for (final definition in agentCliRuntimeDefinitions.take(2))
        AgentRuntimeInfo(
          definition: definition,
          status: AgentRuntimeStatus.updateAvailable,
          installedVersion: '1.0',
          latestVersion: '2.0',
          managedByPackageManager: true,
        ),
    ];
    when(
      () =>
          service.refreshAll(session, onDiscovered: any(named: 'onDiscovered')),
    ).thenAnswer((_) async => runtimes);
    when(() => service.readUsage(session, any())).thenAnswer((_) async => {});
    model = AgentManagementViewModel(
      session: () {
        expect(
          model.mounted,
          isTrue,
          reason: 'Do not read the dismissed screen',
        );
        return session;
      },
      service: () {
        expect(
          model.mounted,
          isTrue,
          reason: 'Do not read the dismissed screen',
        );
        return service;
      },
      canManageAgents: () async => permitted,
      onRuntimesRefreshed: (_) {},
      onProvidersRefreshed: () {},
      showActionResult: (_, result) async => failures.add(result.output),
      showBulkFailures: (labels) async => bulkFailures.addAll(labels),
    );
    // refresh() initializes the data without starting the UI's periodic clock.
  });
  tearDown(() {
    if (model.mounted) model.dispose();
  });

  test('usage starts on discovery before version metadata completes', () async {
    final metadata = Completer<List<AgentRuntimeInfo>>();
    final usageStarted = Completer<void>();
    when(
      () =>
          service.refreshAll(session, onDiscovered: any(named: 'onDiscovered')),
    ).thenAnswer((invocation) {
      (invocation.namedArguments[#onDiscovered]
          as void Function(List<AgentRuntimeInfo>))(runtimes);
      return metadata.future;
    });
    when(() => service.readUsage(session, any())).thenAnswer((_) async {
      usageStarted.complete();
      return {
        runtimes.first.definition.id: const AgentUsage(
          status: AgentUsageStatus.available,
        ),
      };
    });
    final refresh = model.refresh();
    await usageStarted.future;
    expect(metadata.isCompleted, isFalse);
    expect(model.refreshing, isTrue);
    metadata.complete(runtimes);
    await refresh;
    expect(
      model.usage[runtimes.first.definition.id]?.status,
      AgentUsageStatus.available,
    );
    expect(model.refreshing, isFalse);
    verify(() => service.readUsage(session, any())).called(1);
  });

  test(
    'opens on the cached probe and quotas instead of placeholders',
    () async {
      final usage = {
        runtimes.first.definition.id: const AgentUsage(
          status: AgentUsageStatus.available,
        ),
      };
      final pending = Completer<List<AgentRuntimeInfo>>();
      when(() => service.cachedState(session))
          .thenReturn((runtimes: runtimes, usage: usage));
      when(
        () => service.refreshAll(
          session,
          onDiscovered: any(named: 'onDiscovered'),
        ),
      ).thenAnswer((_) => pending.future);

      model.initialize();

      expect(model.runtimes, runtimes);
      expect(model.runtimes, isNot(same(runtimes)));
      expect(model.usage, usage);
      pending.complete(runtimes);
      await pumpEventQueue();
    },
  );

  test('a cached probe that failed everywhere is not shown', () async {
    when(() => service.cachedState(session)).thenReturn((
      runtimes: [
        for (final runtime in runtimes)
          AgentRuntimeInfo(
            definition: runtime.definition,
            status: AgentRuntimeStatus.failed,
          ),
      ],
      usage: const {},
    ));
    final pending = Completer<List<AgentRuntimeInfo>>();
    when(
      () =>
          service.refreshAll(session, onDiscovered: any(named: 'onDiscovered')),
    ).thenAnswer((_) => pending.future);

    model.initialize();

    expect(
      model.runtimes.map((runtime) => runtime.status),
      everyElement(AgentRuntimeStatus.checking),
    );
    pending.complete(runtimes);
    await pumpEventQueue();
  });

  test(
    'discovery keeps known updates until the full result replaces them',
    () async {
      await model.refresh();
      final unchanged = runtimes.first;
      final changed = runtimes[1];
      final metadata = Completer<List<AgentRuntimeInfo>>();
      when(
        () => service.refreshAll(
          session,
          onDiscovered: any(named: 'onDiscovered'),
        ),
      ).thenAnswer((invocation) {
        (invocation.namedArguments[#onDiscovered]
            as void Function(List<AgentRuntimeInfo>))([
          // Registry metadata is not known yet, so discovery says "installed".
          AgentRuntimeInfo(
            definition: unchanged.definition,
            status: AgentRuntimeStatus.installed,
            installedVersion: unchanged.installedVersion,
          ),
          AgentRuntimeInfo(
            definition: changed.definition,
            status: AgentRuntimeStatus.installed,
            installedVersion: '2.0',
          ),
        ]);
        return metadata.future;
      });

      final refresh = model.refresh();
      await pumpEventQueue();

      expect(model.runtimes.first, same(unchanged));
      expect(model.runtimes[1].installedVersion, '2.0');
      expect(model.runtimes[1].hasUpdate, isFalse);

      final result = [
        AgentRuntimeInfo(
          definition: unchanged.definition,
          status: AgentRuntimeStatus.installed,
          installedVersion: unchanged.installedVersion,
        ),
        model.runtimes[1],
      ];
      metadata.complete(result);
      await refresh;
      // The full result is authoritative, even when it drops a known update.
      expect(model.runtimes, result);
    },
  );

  test(
    'recheck replaces the list instead of mutating the service copy',
    () async {
      await model.refresh();
      final before = model.runtimes;
      final updated = AgentRuntimeInfo(
        definition: runtimes.first.definition,
        status: AgentRuntimeStatus.installed,
        installedVersion: '2.0',
      );
      when(() => service.inspect(session, runtimes.first.definition))
          .thenAnswer((_) async => updated);

      await model.recheck(runtimes.first);

      expect(model.runtimes.first, same(updated));
      expect(model.runtimes, isNot(same(before)));
      expect(before.first, isNot(same(updated)));
    },
  );

  test('revoked access prevents probing and stale actions', () async {
    await model.refresh();
    permitted = false;
    clearInteractions(service);
    await model.refresh();
    await model.runAction(runtimes.first);
    await model.updateAll();
    verifyZeroInteractions(service);
  });

  test('disposing during discovery suppresses state publication', () async {
    final metadata = Completer<List<AgentRuntimeInfo>>();
    final started = Completer<void>();
    when(
      () =>
          service.refreshAll(session, onDiscovered: any(named: 'onDiscovered')),
    ).thenAnswer((_) {
      started.complete();
      return metadata.future;
    });
    final refresh = model.refresh();
    await started.future;
    var changes = 0;
    model
      ..addListener(() => changes++)
      ..dispose();
    metadata.complete(runtimes);
    await refresh;
    expect(changes, 0);
    verifyNever(() => service.readUsage(session, any()));
  });

  test(
    'bulk updates continue after an action throws and clear queue state',
    () async {
      await model.refresh();
      final calls = <String>[];
      for (final runtime in runtimes) {
        when(
          () => service.installOrUpdate(
            session,
            runtime.definition,
            update: true,
            current: runtime,
            onOutput: any(named: 'onOutput'),
          ),
        ).thenAnswer((_) async {
          calls.add(runtime.definition.id);
          if (runtime == runtimes.first) throw StateError('failed command');
          return const AgentRuntimeActionResult(
            succeeded: true,
            output: 'done',
          );
        });
      }
      await model.updateAll();
      expect(calls, runtimes.map((runtime) => runtime.definition.id));
      expect(bulkFailures, [runtimes.first.definition.label]);
      expect(model.completedUpdates, 2);
      expect(model.runningActions, isEmpty);
      expect(model.queuedActions, isEmpty);
      expect(model.busy, isFalse);
    },
  );

  for (final outcome in ['success', 'failure', 'access revoked']) {
    test(
      'dismissed bulk updates preserve the queue and access checks: $outcome',
      () async {
        await model.refresh();
        final firstStarted = Completer<void>();
        final firstResult = Completer<AgentRuntimeActionResult>();
        final calls = <String>[];
        late void Function(String) output;
        for (final runtime in runtimes) {
          when(
            () => service.installOrUpdate(
              session,
              runtime.definition,
              update: true,
              current: runtime,
              onOutput: any(named: 'onOutput'),
            ),
          ).thenAnswer((invocation) {
            calls.add(runtime.definition.id);
            output =
                invocation.namedArguments[#onOutput] as void Function(String);
            if (runtime == runtimes.first) {
              firstStarted.complete();
              return firstResult.future;
            }
            output('second update output');
            return Future.value(
              const AgentRuntimeActionResult(succeeded: true, output: 'done'),
            );
          });
        }
        final batch = model.updateAll();
        await firstStarted.future;
        var notifications = 0;
        model
          ..addListener(() => notifications++)
          ..dispose();
        output('output after dismissal');
        if (outcome == 'access revoked') permitted = false;
        if (outcome == 'failure') {
          firstResult.completeError(StateError('failed command'));
        } else {
          firstResult.complete(
            const AgentRuntimeActionResult(succeeded: true, output: 'done'),
          );
        }
        await batch;
        expect(
          calls,
          (outcome == 'access revoked' ? runtimes.take(1) : runtimes).map(
            (runtime) => runtime.definition.id,
          ),
        );
        expect(notifications, 0);
        expect(failures, isEmpty);
        expect(bulkFailures, isEmpty);
        // Dismissal stops UI probes and dialogs, not the remote commands.
        verify(
          () => service.refreshAll(
            session,
            onDiscovered: any(named: 'onDiscovered'),
          ),
        ).called(1);
      },
    );
  }

  test(
    'a single update finishes without UI callbacks after dismissal',
    () async {
      await model.refresh();
      final runtime = runtimes.first;
      final started = Completer<void>();
      final result = Completer<AgentRuntimeActionResult>();
      late void Function(String) output;
      when(
        () => service.installOrUpdate(
          session,
          runtime.definition,
          update: true,
          current: runtime,
          onOutput: any(named: 'onOutput'),
        ),
      ).thenAnswer((invocation) {
        output = invocation.namedArguments[#onOutput] as void Function(String);
        started.complete();
        return result.future;
      });
      final action = model.runAction(runtime);
      await started.future;
      var notifications = 0;
      model
        ..addListener(() => notifications++)
        ..dispose();
      output('late output');
      result.complete(
        const AgentRuntimeActionResult(succeeded: false, output: 'failed'),
      );
      await action;
      expect(notifications, 0);
      expect(failures, isEmpty);
      expect(bulkFailures, isEmpty);
      verify(
        () => service.refreshAll(
          session,
          onDiscovered: any(named: 'onDiscovered'),
        ),
      ).called(1);
    },
  );

  test('output keeps only the latest 1200 characters', () async {
    await model.refresh();
    final runtime = runtimes.first;
    when(
      () => service.installOrUpdate(
        session,
        runtime.definition,
        update: true,
        current: runtime,
        onOutput: any(named: 'onOutput'),
      ),
    ).thenAnswer((invocation) async {
      final output =
          invocation.namedArguments[#onOutput] as void Function(String);
      output('x' * 1200);
      output('end');
      return const AgentRuntimeActionResult(succeeded: true, output: 'done');
    });
    await model.runAction(runtime);
    expect(model.actionOutput[runtime.definition.id], '${'x' * 1197}end');
    expect(failures, isEmpty);
    expect(model.busy, isFalse);
  });

  test('presentation keeps version fallbacks and source paths', () {
    final scheme = ColorScheme.fromSeed(seedColor: Colors.blue);
    final installed = AgentRuntimeInfo(
      definition: runtimes.first.definition,
      status: AgentRuntimeStatus.installed,
      executablePath: '/opt/bin/agent',
      detectionSource: 'PATH',
    );
    expect(agentStatusPresentation(installed, scheme).label, 'Installed');
    expect(agentSourceLine(installed), 'PATH · /opt/bin/agent');
    expect(displayAgentExecutablePath('/opt/bin/agent'), '/opt/bin/agent');
    expect(agentSourceLine(runtimes.first), isNull);
    expect(
      agentStatusPresentation(runtimes.first, scheme).label,
      'Update v1.0 → v2.0',
    );
    final unknown = AgentRuntimeInfo(
      definition: runtimes.first.definition,
      status: AgentRuntimeStatus.updateAvailable,
    );
    expect(agentStatusPresentation(unknown, scheme).label, 'Update v? → v?');
  });
}

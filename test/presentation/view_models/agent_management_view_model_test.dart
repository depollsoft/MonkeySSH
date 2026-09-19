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
      session: () => session,
      service: () => service,
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

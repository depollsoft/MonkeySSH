// ignore_for_file: public_member_api_docs

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/agent_worktree.dart';
import 'package:monkeyssh/domain/services/agent_worktree_launcher.dart';
import 'package:monkeyssh/domain/services/agent_worktree_registry.dart';
import 'package:monkeyssh/domain/services/agent_worktree_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/screens/terminal/terminal_agent_worktree_launch.dart';

class _MockSshClient extends Mock implements SSHClient {}

class _FakeService extends AgentWorktreeService {
  _FakeService({this.createError});

  final AgentWorktreeException? createError;
  final created = <AgentWorktreeRecord>[];
  final removed = <AgentWorktreeRecord>[];

  @override
  Future<AgentWorktreeRecord> create(
    AgentWorktreeShell shell, {
    required int hostId,
    required String repository,
    required String baseRef,
    required AgentWorktreeTarget target,
    DateTime? now,
  }) async {
    if (createError case final error?) throw error;
    final record = AgentWorktreeRecord(
      hostId: hostId,
      repository: '/srv/app',
      path: '/srv/app.worktrees/agent',
      startDirectory: '/srv/app.worktrees/agent/pkg',
      branch: target.branch,
      baseCommit: 'abc',
      createdAt: DateTime.utc(2026),
    );
    created.add(record);
    return record;
  }

  @override
  Future<AgentWorktreeRemoval> remove(
    AgentWorktreeShell shell,
    AgentWorktreeRecord record,
  ) async {
    removed.add(record);
    return const AgentWorktreeRemoval(branchDeleted: true);
  }
}

class _MemoryRegistry implements AgentWorktreeRegistry {
  final records = <AgentWorktreeRecord>[];

  @override
  Future<void> add(AgentWorktreeRecord record) async => records.add(record);

  @override
  Future<void> remove(AgentWorktreeRecord record) async =>
      records.remove(record);

  @override
  Future<AgentWorktreeRecord?> findContaining(
    int hostId,
    String? directory,
  ) async => records.where((record) => record.contains(directory)).firstOrNull;

  @override
  Future<List<AgentWorktreeRecord>> recordsForHost(int hostId) async => records;
}

SshSession _session({String version = 'SSH-2.0-OpenSSH_9.6'}) {
  final client = _MockSshClient();
  when(() => client.remoteVersion).thenReturn(version);
  return SshSession(
    connectionId: 3,
    hostId: 5,
    client: client,
    config: const SshConnectionConfig(
      hostname: 'example.com',
      port: 22,
      username: 'dev',
    ),
  );
}

const _preset = AgentLaunchPreset(
  tool: AgentLaunchTool.codex,
  workingDirectory: '~/src/app/pkg',
  tmuxSessionName: 'agents',
  worktree: AgentWorktreeLaunchOptions(),
);

void main() {
  late _FakeService service;
  late _MemoryRegistry registry;

  Future<TerminalAgentWorktreeLaunch?> prepare(
    WidgetTester tester, {
    AgentLaunchPreset preset = _preset,
    SshSession? session,
    Future<bool> Function()? sessionExists,
  }) async {
    TerminalAgentWorktreeLaunch? launch;
    final launcher = AgentWorktreeLauncher(
      service: service,
      registry: registry,
      wait: (_) async {},
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [agentWorktreeLauncherProvider.overrideWithValue(launcher)],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () async {
                  launch = await prepareTerminalAgentWorktreeLaunch(
                    context: context,
                    ref: ref,
                    session: session ?? _session(),
                    preset: preset,
                    sessionExists: sessionExists,
                  );
                },
                child: const Text('launch'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('launch'));
    await tester.pumpAndSettle();
    return launch;
  }

  setUp(() {
    service = _FakeService();
    registry = _MemoryRegistry();
  });

  testWidgets('presets without a worktree launch unchanged', (tester) async {
    const plain = AgentLaunchPreset(
      tool: AgentLaunchTool.codex,
      workingDirectory: '~/src/app',
    );

    final launch = await prepare(tester, preset: plain);

    expect(launch?.preset, same(plain));
    expect(launch?.worktree, isNull);
    expect(service.created, isEmpty);
  });

  testWidgets(
    'attaching to a running session reuses its windows and creates nothing',
    (tester) async {
      final launch = await prepare(tester, sessionExists: () async => true);

      expect(launch?.preset, same(_preset));
      expect(launch?.worktree, isNull);
      expect(service.created, isEmpty);
    },
  );

  testWidgets('creates the worktree and launches the agent inside it', (
    tester,
  ) async {
    final launch = await prepare(tester, sessionExists: () async => false);

    expect(launch!.preset.workingDirectory, '/srv/app.worktrees/agent/pkg');
    expect(launch.preset.launchesInNewWorktree, isFalse);
    expect(launch.preset.tmuxSessionName, 'agents');
    expect(service.created, hasLength(1));
    expect(registry.records, service.created);
  });

  testWidgets('a failed session probe still creates the worktree', (
    tester,
  ) async {
    final launch = await prepare(
      tester,
      sessionExists: () async => throw StateError('probe failed'),
    );

    expect(launch?.worktree, isNotNull);
  });

  testWidgets('does not start the agent when the worktree fails', (
    tester,
  ) async {
    service = _FakeService(
      createError: const AgentWorktreeException(
        AgentWorktreeErrorKind.notRepository,
      ),
    );

    final launch = await prepare(tester);

    expect(launch, isNull);
    expect(
      find.text(
        'Agent not started: The repository folder is not a git repository.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('refuses Windows hosts with an explanation', (tester) async {
    final launch = await prepare(
      tester,
      session: _session(version: 'SSH-2.0-OpenSSH_for_Windows_9.5'),
    );

    expect(launch, isNull);
    expect(find.textContaining('macOS or Linux'), findsOneWidget);
    expect(service.created, isEmpty);
  });

  testWidgets('an abandoned launch rolls its worktree back once', (
    tester,
  ) async {
    final launch = await prepare(tester);

    launch!
      ..abandon()
      ..abandon()
      ..launched();
    await tester.pumpAndSettle();

    expect(service.removed, service.created);
    expect(registry.records, isEmpty);
  });

  testWidgets('a launch whose window runs in the worktree keeps it', (
    tester,
  ) async {
    final launch = await prepare(tester);

    launch!.launched(
      windowDirectories: () async => ['/srv/app.worktrees/agent/pkg'],
    );
    await tester.pumpAndSettle();

    expect(service.removed, isEmpty);
    expect(registry.records, hasLength(1));
  });
}

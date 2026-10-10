// ignore_for_file: public_member_api_docs

import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/agent_worktree.dart';
import 'package:monkeyssh/domain/services/agent_worktree_registry.dart';
import 'package:monkeyssh/domain/services/agent_worktree_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/widgets/agent_worktree_removal.dart';

class _MockSshClient extends Mock implements SSHClient {}

class _FakeService extends AgentWorktreeService {
  _FakeService(this.state);

  AgentWorktreeStatus state;
  final removed = <AgentWorktreeRecord>[];

  @override
  Future<AgentWorktreeStatus> status(
    AgentWorktreeShell shell,
    AgentWorktreeRecord record,
  ) async => state;

  @override
  Future<AgentWorktreeRemoval> remove(
    AgentWorktreeShell shell,
    AgentWorktreeRecord record,
  ) async {
    if (state.isDirty) {
      throw const AgentWorktreeException(AgentWorktreeErrorKind.dirty);
    }
    removed.add(record);
    return const AgentWorktreeRemoval(branchDeleted: false);
  }
}

const _clean = AgentWorktreeStatus(
  exists: true,
  changedFiles: 0,
  ignoredEntries: 0,
  branchHasNewCommits: true,
);

final _record = AgentWorktreeRecord(
  hostId: 1,
  repository: '/srv/app',
  path: '/srv/app.worktrees/agent-claude-1',
  branch: 'agent/claude-1',
  baseCommit: 'abc',
  createdAt: DateTime.utc(2026, 10, 9),
);

/// Opens the dialog and returns a reader for its result.
Future<bool? Function()> _open(
  WidgetTester tester,
  AgentWorktreeStatus status,
) async {
  bool? result;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              result = await showAgentWorktreeRemovalDialog(
                context: context,
                record: _record,
                status: status,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return () => result;
}

void main() {
  testWidgets('refuses a dirty worktree with an explanation', (tester) async {
    await _open(
      tester,
      const AgentWorktreeStatus(
        exists: true,
        changedFiles: 3,
        ignoredEntries: 0,
        branchHasNewCommits: false,
      ),
    );

    expect(find.text('Worktree kept'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.textContaining('3 uncommitted changes'), findsOneWidget);
    expect(find.text('agent/claude-1'), findsOneWidget);
    expect(find.byKey(agentWorktreeRemoveButtonKey), findsNothing);

    await tester.tap(find.byKey(agentWorktreeKeepButtonKey));
    await tester.pumpAndSettle();
    expect(find.text('Worktree kept'), findsNothing);
  });

  testWidgets('confirms removing a clean worktree', (tester) async {
    final removed = await _open(
      tester,
      const AgentWorktreeStatus(
        exists: true,
        changedFiles: 0,
        ignoredEntries: 2,
        branchHasNewCommits: true,
      ),
    );

    expect(find.text('Remove worktree?'), findsOneWidget);
    expect(find.text('The branch keeps its commits.'), findsOneWidget);
    expect(find.textContaining('2 ignored items'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(agentWorktreeRemoveButtonKey)).height,
      greaterThanOrEqualTo(40),
    );

    await tester.tap(find.byKey(agentWorktreeRemoveButtonKey));
    await tester.pumpAndSettle();
    expect(removed(), isTrue);
  });

  testWidgets('keeping a clean worktree returns false', (tester) async {
    final removed = await _open(
      tester,
      const AgentWorktreeStatus(
        exists: true,
        changedFiles: 0,
        ignoredEntries: 0,
        branchHasNewCommits: false,
      ),
    );

    expect(
      find.text('The branch has no new commits, so it is deleted too.'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(agentWorktreeKeepButtonKey));
    await tester.pumpAndSettle();
    expect(removed(), isFalse);
  });

  group('offerAgentWorktreeRemoval', () {
    late AppDatabase database;
    late AgentWorktreeRegistry registry;
    late SshSession session;

    setUp(() async {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      registry = AgentWorktreeRegistry(SettingsService(database));
      await registry.add(_record);
      final client = _MockSshClient();
      when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.6');
      session = SshSession(
        connectionId: 9,
        hostId: 1,
        client: client,
        config: const SshConnectionConfig(
          hostname: 'example.com',
          port: 22,
          username: 'dev',
        ),
      );
    });

    tearDown(() async {
      await database.close();
    });

    Future<void> offer(
      WidgetTester tester,
      _FakeService service, {
      required String? closed,
      List<String?> remaining = const [],
      Future<Iterable<String?>> Function()? live,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            agentWorktreeRegistryProvider.overrideWithValue(registry),
            agentWorktreeServiceProvider.overrideWithValue(service),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () => offerAgentWorktreeRemoval(
                    context: context,
                    ref: ref,
                    session: session,
                    closedWindowDirectory: closed,
                    remainingWindowDirectories: remaining,
                    liveWindowDirectories: live,
                  ),
                  child: const Text('close'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('close'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
    }

    testWidgets('ignores folders MonkeySSH did not create', (tester) async {
      await offer(tester, _FakeService(_clean), closed: '/srv/app');

      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('waits while another window still uses the worktree', (
      tester,
    ) async {
      await offer(
        tester,
        _FakeService(_clean),
        closed: _record.path,
        remaining: ['${_record.path}/lib'],
      );

      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('removes the worktree only after confirmation', (tester) async {
      final service = _FakeService(_clean);
      await offer(tester, service, closed: '${_record.path}/lib');

      expect(find.text('Remove worktree?'), findsOneWidget);
      expect(service.removed, isEmpty);

      await tester.runAsync(() async {
        await tester.tap(find.byKey(agentWorktreeRemoveButtonKey));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      expect(service.removed, [_record]);
      expect(
        find.text('Worktree removed. Its branch keeps the commits.'),
        findsOneWidget,
      );
      expect(await tester.runAsync(() => registry.recordsForHost(1)), isEmpty);
    });

    testWidgets('forgets a folder that is no longer the recorded worktree', (
      tester,
    ) async {
      final service = _FakeService(
        const AgentWorktreeStatus(
          exists: true,
          changedFiles: 0,
          ignoredEntries: 0,
          branchHasNewCommits: false,
          stale: true,
        ),
      );
      await offer(tester, service, closed: _record.path);

      expect(find.byType(AlertDialog), findsNothing);
      expect(service.removed, isEmpty);
      expect(await tester.runAsync(() => registry.recordsForHost(1)), isEmpty);
    });

    testWidgets('keeps a worktree another window entered during the dialog', (
      tester,
    ) async {
      final service = _FakeService(_clean);
      await offer(
        tester,
        service,
        closed: _record.path,
        live: () async => ['${_record.path}/lib'],
      );

      await tester.runAsync(() async {
        await tester.tap(find.byKey(agentWorktreeRemoveButtonKey));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      expect(service.removed, isEmpty);
      expect(
        find.text('Worktree not removed. Another window is using it.'),
        findsOneWidget,
      );
    });

    testWidgets('a failed live check does not block removal', (tester) async {
      final service = _FakeService(_clean);
      await offer(
        tester,
        service,
        closed: _record.path,
        live: () async => throw StateError('session ended'),
      );

      await tester.runAsync(() async {
        await tester.tap(find.byKey(agentWorktreeRemoveButtonKey));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      expect(service.removed, [_record]);
    });

    testWidgets('never removes a dirty worktree', (tester) async {
      final service = _FakeService(
        const AgentWorktreeStatus(
          exists: true,
          changedFiles: 1,
          ignoredEntries: 0,
          branchHasNewCommits: false,
        ),
      );
      await offer(tester, service, closed: _record.path);

      expect(find.text('Worktree kept'), findsOneWidget);
      await tester.tap(find.byKey(agentWorktreeKeepButtonKey));
      await tester.pumpAndSettle();

      expect(service.removed, isEmpty);
      expect(await tester.runAsync(() => registry.recordsForHost(1)), [
        _record,
      ]);
    });
  });

  group('kept reasons', () {
    test('name the work removal would lose and the fix', () {
      expect(
        agentWorktreeKeptReason(
          const AgentWorktreeStatus(
            exists: true,
            changedFiles: 1,
            ignoredEntries: 0,
            branchHasNewCommits: false,
          ),
        ),
        startsWith('It has 1 uncommitted change,'),
      );
      expect(
        agentWorktreeKeptReason(
          const AgentWorktreeStatus(
            exists: true,
            changedFiles: 0,
            ignoredEntries: 0,
            branchHasNewCommits: false,
            unsavedCommits: true,
          ),
        ),
        allOf(
          contains('commits that are not on any branch'),
          contains('Put them on a branch'),
        ),
      );
      expect(
        agentWorktreeKeptReason(
          const AgentWorktreeStatus(
            exists: true,
            changedFiles: 0,
            ignoredEntries: 0,
            branchHasNewCommits: false,
            operationInProgress: 'rebase-merge',
          ),
        ),
        allOf(contains('A rebase is in progress'), contains('Finish or abort')),
      );
    });
  });

  testWidgets('a detached worktree with unsaved commits offers no removal', (
    tester,
  ) async {
    await _open(
      tester,
      const AgentWorktreeStatus(
        exists: true,
        changedFiles: 0,
        ignoredEntries: 0,
        branchHasNewCommits: false,
        unsavedCommits: true,
      ),
    );

    expect(find.text('Worktree kept'), findsOneWidget);
    expect(find.byKey(agentWorktreeRemoveButtonKey), findsNothing);
    expect(find.textContaining('not on any branch'), findsOneWidget);
    expect(find.textContaining('no new commits'), findsNothing);
  });
}

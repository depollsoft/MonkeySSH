// ignore_for_file: public_member_api_docs

import 'dart:math';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/agent_worktree.dart';
import 'package:monkeyssh/domain/services/agent_worktree_launcher.dart';
import 'package:monkeyssh/domain/services/agent_worktree_registry.dart';
import 'package:monkeyssh/domain/services/agent_worktree_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

class _NoShell implements AgentWorktreeShell {
  @override
  Future<AgentWorktreeExecResult> run(
    String script, {
    required Duration timeout,
  }) => throw UnimplementedError();
}

class _FakeService extends AgentWorktreeService {
  _FakeService();

  final created =
      <({String repository, String baseRef, AgentWorktreeTarget target})>[];
  final removed = <AgentWorktreeRecord>[];
  AgentWorktreeException? removeError;

  @override
  Future<AgentWorktreeRecord> create(
    AgentWorktreeShell shell, {
    required int hostId,
    required String repository,
    required String baseRef,
    required AgentWorktreeTarget target,
    DateTime? now,
  }) async {
    created.add((repository: repository, baseRef: baseRef, target: target));
    return AgentWorktreeRecord(
      hostId: hostId,
      repository: '/srv/app',
      path: '/srv/app.worktrees/${target.branch.replaceAll('/', '-')}',
      branch: target.branch,
      baseCommit: 'abc',
      createdAt: now ?? DateTime.utc(2026),
    );
  }

  @override
  Future<AgentWorktreeRemoval> remove(
    AgentWorktreeShell shell,
    AgentWorktreeRecord record,
  ) async {
    if (removeError case final error?) throw error;
    removed.add(record);
    return const AgentWorktreeRemoval(branchDeleted: true);
  }
}

void main() {
  late AppDatabase database;
  late AgentWorktreeRegistry registry;
  late _FakeService service;
  late AgentWorktreeLauncher launcher;
  final shell = _NoShell();
  const preset = AgentLaunchPreset(
    tool: AgentLaunchTool.claudeCode,
    workingDirectory: '~/src/app',
    worktree: AgentWorktreeLaunchOptions(baseRef: 'origin/main'),
  );

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    registry = AgentWorktreeRegistry(SettingsService(database));
    service = _FakeService();
    launcher = AgentWorktreeLauncher(
      service: service,
      registry: registry,
      clock: () => DateTime(2026, 10, 9, 8, 30),
      random: Random(4),
      wait: (_) async {},
    );
  });

  tearDown(() async {
    await database.close();
  });

  Future<AgentWorktreeErrorKind?> createError(
    AgentLaunchPreset preset, {
    bool windowsHost = false,
  }) async {
    try {
      await launcher.create(
        shell,
        hostId: 1,
        preset: preset,
        windowsHost: windowsHost,
      );
    } on AgentWorktreeException catch (error) {
      return error.kind;
    }
    return null;
  }

  group('create', () {
    test(
      'renders the branch from the preset and records the worktree',
      () async {
        final record = await launcher.create(
          shell,
          hostId: 1,
          preset: preset,
          windowsHost: false,
        );

        final request = service.created.single;
        expect(request.repository, '~/src/app');
        expect(request.baseRef, 'origin/main');
        expect(request.target.branch, startsWith('agent/claude-20261009-'));
        expect(await registry.findContaining(1, record.path), record);
      },
    );

    test(
      'refuses Windows hosts and invalid options before running git',
      () async {
        expect(
          await createError(preset, windowsHost: true),
          AgentWorktreeErrorKind.unsupportedHost,
        );
        expect(
          await createError(
            const AgentLaunchPreset(
              tool: AgentLaunchTool.codex,
              worktree: AgentWorktreeLaunchOptions(),
            ),
          ),
          AgentWorktreeErrorKind.invalidOptions,
        );
        expect(
          await createError(
            const AgentLaunchPreset(
              tool: AgentLaunchTool.codex,
              workingDirectory: '/srv/app',
              worktree: AgentWorktreeLaunchOptions(branchTemplate: 'a..{id}'),
            ),
          ),
          AgentWorktreeErrorKind.invalidOptions,
        );
        expect(service.created, isEmpty);
      },
    );
  });

  group('confirm', () {
    late AgentWorktreeRecord record;

    setUp(() async {
      record = await launcher.create(
        shell,
        hostId: 1,
        preset: preset,
        windowsHost: false,
      );
    });

    test('keeps the worktree once a window runs in it', () async {
      var polls = 0;
      final outcome = await launcher.confirm(
        shell,
        record,
        windowDirectories: () async => [
          '/home/me',
          if (++polls >= 2) '${record.path}/lib',
        ],
      );

      expect(outcome, AgentWorktreeLaunchOutcome.confirmed);
      expect(polls, 2);
      expect(service.removed, isEmpty);
      expect(await registry.findContaining(1, record.path), isNotNull);
    });

    test('rolls back when no window ever runs in the worktree', () async {
      var polls = 0;
      final outcome = await launcher.confirm(
        shell,
        record,
        windowDirectories: () async {
          polls++;
          if (polls.isOdd) throw StateError('session not started');
          return ['/srv/app'];
        },
      );

      expect(outcome, AgentWorktreeLaunchOutcome.rolledBack);
      expect(polls, agentWorktreeLaunchCheckSchedule.length);
      expect(service.removed, [record]);
      expect(await registry.recordsForHost(1), isEmpty);
    });

    test('keeps the record when git refuses the rollback', () async {
      service.removeError = const AgentWorktreeException(
        AgentWorktreeErrorKind.dirty,
      );

      final outcome = await launcher.confirm(
        shell,
        record,
        windowDirectories: () async => const [],
        schedule: const [Duration.zero],
      );

      expect(outcome, AgentWorktreeLaunchOutcome.kept);
      expect(await registry.findContaining(1, record.path), record);
    });
  });
}

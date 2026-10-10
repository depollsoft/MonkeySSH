// ignore_for_file: public_member_api_docs

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/agent_worktree.dart';
import 'package:monkeyssh/domain/services/agent_worktree_launcher.dart';
import 'package:monkeyssh/domain/services/agent_worktree_service.dart';

import '../../support/fake_agent_worktree.dart';

class _NoShell implements AgentWorktreeShell {
  @override
  Future<AgentWorktreeExecResult> run(
    String script, {
    required Duration timeout,
  }) => throw UnimplementedError();
}

void main() {
  late MemoryAgentWorktreeRegistry registry;
  late FakeAgentWorktreeService service;
  late AgentWorktreeLauncher launcher;
  final shell = _NoShell();
  const preset = AgentLaunchPreset(
    tool: AgentLaunchTool.claudeCode,
    workingDirectory: '~/src/app',
    tmuxSessionName: 'agents',
    worktree: AgentWorktreeLaunchOptions(baseRef: 'origin/main'),
  );

  setUp(() {
    registry = MemoryAgentWorktreeRegistry();
    service = FakeAgentWorktreeService();
    launcher = AgentWorktreeLauncher(
      service: service,
      registry: registry,
      clock: () => DateTime(2026, 10, 9, 8, 30),
      random: Random(4),
      wait: (_) async {},
    );
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

        expect(
          service.targets.single.branch,
          startsWith('agent/claude-20261009-'),
        );
        expect(registry.records, [record]);
        expect(record.pending, isFalse);
      },
    );

    test('names the branch after the agent actually launched', () async {
      await launcher.create(
        shell,
        hostId: 1,
        preset: preset,
        windowsHost: false,
        tool: AgentLaunchTool.codex,
      );

      expect(service.targets.single.branch, startsWith('agent/codex-'));
    });

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
        expect(service.targets, isEmpty);
      },
    );

    test('forgets the pending record when git refuses', () async {
      service.addError = const AgentWorktreeException(
        AgentWorktreeErrorKind.addFailed,
      );

      expect(await createError(preset), AgentWorktreeErrorKind.addFailed);
      expect(registry.records, isEmpty);
    });

    test('keeps the pending record when git does not answer', () async {
      service.addError = const AgentWorktreeException(
        AgentWorktreeErrorKind.unavailable,
      );

      expect(await createError(preset), AgentWorktreeErrorKind.unavailable);
      expect(registry.records.single.pending, isTrue);
    });

    test('removes the new worktree when recording it fails', () async {
      registry.failAdd = (record) => !record.pending;

      expect(await createError(preset), AgentWorktreeErrorKind.unavailable);
      expect(service.removed, service.created);
      expect(service.created, hasLength(1));
    });
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
      expect(registry.records, [record]);
    });

    test('rolls back once a listing shows no window in the worktree', () async {
      var polls = 0;
      final outcome = await launcher.confirm(
        shell,
        record,
        windowDirectories: () async {
          polls++;
          if (polls.isOdd) throw StateError('control channel busy');
          return ['/srv/app'];
        },
      );

      expect(outcome, AgentWorktreeLaunchOutcome.rolledBack);
      expect(polls, agentWorktreeLaunchCheckSchedule.length);
      expect(service.removed, [record]);
      expect(registry.records, isEmpty);
    });

    test('rolls back when the session is gone', () async {
      final outcome = await launcher.confirm(
        shell,
        record,
        windowDirectories: () async => const <String>[],
        schedule: const [Duration.zero],
      );

      expect(outcome, AgentWorktreeLaunchOutcome.rolledBack);
    });

    test('keeps the worktree when no listing ever succeeds', () async {
      final outcome = await launcher.confirm(
        shell,
        record,
        windowDirectories: () async => throw StateError('control timed out'),
      );

      expect(outcome, AgentWorktreeLaunchOutcome.kept);
      expect(service.removed, isEmpty);
      expect(registry.records, [record]);
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
      expect(registry.records, [record]);
    });

    test('forgets a record whose folder is someone else’s now', () async {
      service.removeError = const AgentWorktreeException(
        AgentWorktreeErrorKind.stale,
      );

      final outcome = await launcher.rollBack(shell, record);

      expect(outcome, AgentWorktreeLaunchOutcome.kept);
      expect(registry.records, isEmpty);
    });
  });
}

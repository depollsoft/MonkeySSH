// ignore_for_file: public_member_api_docs

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/agent_worktree.dart';

void main() {
  const values = AgentWorktreeTemplateValues(
    tool: 'codex',
    date: '20261009',
    time: '0905',
    id: 'abc123',
  );

  group('renderAgentWorktreeTarget', () {
    test('renders the defaults beside the repository', () {
      final target = renderAgentWorktreeTarget(
        const AgentWorktreeLaunchOptions(),
        values,
      );

      expect(target.branch, 'agent/codex-20261009-abc123');
      expect(target.pathIsRepositoryRelative, isTrue);
      expect(target.path, '.worktrees/agent-codex-20261009-abc123');
      expect(
        target.displayPath,
        '{repo}.worktrees/agent-codex-20261009-abc123',
      );
    });

    test('renders absolute and home-relative path templates', () {
      final target = renderAgentWorktreeTarget(
        const AgentWorktreeLaunchOptions(
          branchTemplate: 'wip/{date}-{time}',
          pathTemplate: '~/wt/{branch}',
        ),
        values,
      );

      expect(target.branch, 'wip/20261009-0905');
      expect(target.pathIsRepositoryRelative, isFalse);
      expect(target.path, '~/wt/wip/20261009-0905');
    });

    test('drops trailing slashes so suffixes stay siblings', () {
      expect(
        renderAgentWorktreeTarget(
          const AgentWorktreeLaunchOptions(
            pathTemplate: '{repo}.worktrees/{tool}//',
          ),
          values,
        ).path,
        '.worktrees/codex',
      );
      expect(
        renderAgentWorktreeTarget(
          const AgentWorktreeLaunchOptions(pathTemplate: '~/wt/{name}/'),
          values,
        ).path,
        '~/wt/agent-codex-20261009-abc123',
      );
    });

    test('rejects unknown and misplaced placeholders', () {
      expect(
        () => renderAgentWorktreeTarget(
          const AgentWorktreeLaunchOptions(branchTemplate: 'agent/{prompt}'),
          values,
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('{prompt}'),
          ),
        ),
      );
      expect(
        () => renderAgentWorktreeTarget(
          const AgentWorktreeLaunchOptions(pathTemplate: '~/x/{repo}'),
          values,
        ),
        throwsFormatException,
      );
      expect(
        () => renderAgentWorktreeTarget(
          const AgentWorktreeLaunchOptions(branchTemplate: 'agent/{id'),
          values,
        ),
        throwsFormatException,
      );
    });

    test('rejects branch names git would refuse', () {
      for (final template in [
        '-{id}',
        'agent/{id}..x',
        'agent {id}',
        'agent/{id}.lock',
        'agent/.{id}',
        'agent/{id}/',
        'agent@{{id}',
        r'agent\{id}',
        'agent/{id}:x',
      ]) {
        expect(
          () => renderAgentWorktreeTarget(
            AgentWorktreeLaunchOptions(branchTemplate: template),
            values,
          ),
          throwsFormatException,
          reason: template,
        );
      }
    });

    test('rejects relative or multi-line paths', () {
      for (final template in ['wt/{name}', '~user/{name}', '/tmp/a\n{name}']) {
        expect(
          () => renderAgentWorktreeTarget(
            AgentWorktreeLaunchOptions(pathTemplate: template),
            values,
          ),
          throwsFormatException,
          reason: template,
        );
      }
    });
  });

  test('template values use a date, time and short random id', () {
    final launch = AgentWorktreeTemplateValues.forLaunch(
      tool: 'claude',
      now: DateTime(2026, 3, 4, 5, 6),
      random: Random(1),
    );

    expect(launch.date, '20260304');
    expect(launch.time, '0506');
    expect(launch.id, matches(RegExp(r'^[a-z0-9]{6}$')));
  });

  group('validate', () {
    test('falls back to the working directory for the repository', () {
      const options = AgentWorktreeLaunchOptions();

      expect(options.validate(workingDirectory: '~/src/app'), isNull);
      expect(options.validate(), contains('repository'));
      expect(
        const AgentWorktreeLaunchOptions(repositoryPath: 'src/app')
            .validate(workingDirectory: '~/src/app'),
        contains('absolute'),
      );
    });

    test('names the field each problem belongs to', () {
      AgentWorktreeField? fieldOf(AgentWorktreeLaunchOptions options) =>
          options.problem(workingDirectory: '~/src/app')?.field;

      expect(
        const AgentWorktreeLaunchOptions().problem()?.field,
        AgentWorktreeField.repository,
      );
      expect(
        fieldOf(const AgentWorktreeLaunchOptions(repositoryPath: 'rel')),
        AgentWorktreeField.repository,
      );
      expect(
        fieldOf(const AgentWorktreeLaunchOptions(baseRef: '-x')),
        AgentWorktreeField.baseRef,
      );
      expect(
        fieldOf(const AgentWorktreeLaunchOptions(branchTemplate: 'a b')),
        AgentWorktreeField.branchTemplate,
      );
      expect(
        fieldOf(const AgentWorktreeLaunchOptions(pathTemplate: 'rel/{id}')),
        AgentWorktreeField.pathTemplate,
      );
      expect(fieldOf(const AgentWorktreeLaunchOptions()), isNull);
    });

    test('rejects option-like and spaced base refs', () {
      expect(validateAgentWorktreeBaseRef('origin/main'), isNull);
      expect(validateAgentWorktreeBaseRef('main~2'), isNull);
      expect(validateAgentWorktreeBaseRef('--upload-pack=x'), isNotNull);
      expect(validateAgentWorktreeBaseRef('main x'), isNotNull);
      expect(
        const AgentWorktreeLaunchOptions(baseRef: '-x')
            .validate(workingDirectory: '/srv/app'),
        contains('Base ref'),
      );
    });
  });

  group('preset JSON', () {
    test('round-trips worktree options and the initial prompt', () {
      const preset = AgentLaunchPreset(
        tool: AgentLaunchTool.claudeCode,
        workingDirectory: '~/src/app',
        tmuxSessionName: 'agents',
        worktree: AgentWorktreeLaunchOptions(
          baseRef: 'origin/main',
          branchTemplate: 'feature/{id}',
        ),
        initialPrompt: 'Read AGENTS.md and summarise the open tasks.',
      );

      final decoded = AgentLaunchPreset.tryFromJson(preset.toJson())!;

      expect(decoded.launchesInNewWorktree, isTrue);
      expect(decoded.worktree, preset.worktree);
      expect(
        decoded.worktree!.effectivePathTemplate,
        '{repo}.worktrees/{name}',
      );
      expect(decoded.initialPrompt, preset.initialPrompt);
      expect(decoded.hasInitialPrompt, isTrue);
    });

    test('a worktree preset with only defaults stays enabled', () {
      const preset = AgentLaunchPreset(
        tool: AgentLaunchTool.codex,
        worktree: AgentWorktreeLaunchOptions(),
      );

      final json = preset.toJson();

      expect(json['worktree'], isEmpty);
      expect(
        AgentLaunchPreset.tryFromJson(json)!.launchesInNewWorktree,
        isTrue,
      );
    });

    test('presets saved before worktrees still decode without them', () {
      final decoded = AgentLaunchPreset.tryFromJson({
        'tool': 'codex',
        'workingDirectory': '~/src/app',
      })!;

      expect(decoded.launchesInNewWorktree, isFalse);
      expect(decoded.hasInitialPrompt, isFalse);
    });

    test('launchingIn drops the worktree and keeps the rest', () {
      const preset = AgentLaunchPreset(
        tool: AgentLaunchTool.codex,
        workingDirectory: '~/src/app',
        tmuxSessionName: 'agents',
        additionalArguments: '--model x',
        worktree: AgentWorktreeLaunchOptions(),
      );

      final launch = preset.launchingIn('/srv/app.worktrees/agent-1');

      expect(launch.launchesInNewWorktree, isFalse);
      expect(launch.workingDirectory, '/srv/app.worktrees/agent-1');
      expect(launch.tmuxSessionName, 'agents');
      expect(launch.additionalArguments, '--model x');
    });
  });

  group('AgentWorktreeRecord', () {
    final record = AgentWorktreeRecord(
      hostId: 3,
      repository: '/srv/app',
      path: '/srv/app.worktrees/agent-1',
      alternatePath: '/home/me/app.worktrees/agent-1',
      branch: 'agent/1',
      baseCommit: 'abc',
      createdAt: DateTime.utc(2026, 10, 9),
      startDirectory: '/srv/app.worktrees/agent-1/pkg',
    );

    test('matches its root and subdirectories through either spelling', () {
      expect(record.contains('/srv/app.worktrees/agent-1'), isTrue);
      expect(record.contains('/srv/app.worktrees/agent-1/'), isTrue);
      expect(record.contains('/srv/app.worktrees/agent-1/lib'), isTrue);
      expect(record.contains('/home/me/app.worktrees/agent-1/lib'), isTrue);
      expect(record.contains('/srv/app.worktrees/agent-10'), isFalse);
      expect(record.contains('/srv/app'), isFalse);
      expect(record.contains(null), isFalse);
    });

    test('round-trips through JSON under its host key', () {
      final decoded = AgentWorktreeRecord.tryFromJson(
        record.toJson(),
        hostId: 3,
      )!;

      expect(decoded, record);
      expect(decoded.startDirectory, record.startDirectory);
      expect(decoded.alternatePath, record.alternatePath);
      expect(decoded.createdAt, record.createdAt);
      expect(
        AgentWorktreeRecord.tryFromJson({'path': '/x'}, hostId: 3),
        isNull,
      );
    });

    test('keeps the pending flag through JSON', () {
      final pending = AgentWorktreeRecord(
        hostId: 3,
        repository: '/srv/app',
        path: '/srv/app.worktrees/agent-2',
        branch: 'agent/2',
        baseCommit: 'abc',
        createdAt: DateTime.utc(2026),
        pending: true,
      );

      expect(pending.toJson()['pending'], isTrue);
      expect(record.toJson().containsKey('pending'), isFalse);
      expect(
        AgentWorktreeRecord.tryFromJson(pending.toJson(), hostId: 3)!.pending,
        isTrue,
      );
    });
  });
}

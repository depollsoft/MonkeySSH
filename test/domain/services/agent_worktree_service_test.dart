// ignore_for_file: public_member_api_docs

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/agent_worktree.dart';
import 'package:monkeyssh/domain/services/agent_worktree_registry.dart';
import 'package:monkeyssh/domain/services/agent_worktree_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

/// Runs worktree scripts with the local POSIX shell, standing in for SSH.
class _LocalShell implements AgentWorktreeShell {
  _LocalShell(this.executable, {this.home});

  final String executable;
  final String? home;
  final scripts = <String>[];

  @override
  Future<AgentWorktreeExecResult> run(
    String script, {
    required Duration timeout,
  }) async {
    scripts.add(script);
    final result = await Process.run(
      executable,
      ['-c', script],
      environment: {'HOME': ?home},
    ).timeout(timeout);
    return AgentWorktreeExecResult(
      stdout: result.stdout as String,
      exitCode: result.exitCode,
    );
  }
}

class _FixedShell implements AgentWorktreeShell {
  _FixedShell(this.stdout);

  final String stdout;

  @override
  Future<AgentWorktreeExecResult> run(
    String script, {
    required Duration timeout,
  }) async => AgentWorktreeExecResult(stdout: stdout, exitCode: 0);
}

Future<String> _git(String directory, List<String> args) async {
  final result = await Process.run('git', [
    '-c',
    'user.email=test@example.com',
    '-c',
    'user.name=Test',
    '-c',
    'commit.gpgsign=false',
    '-C',
    directory,
    ...args,
  ]);
  if (result.exitCode != 0) {
    throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
  }
  return (result.stdout as String).trim();
}

/// Login shells SSH exec channels commonly run scripts with.
List<String> _availableShells() => [
  for (final path in ['/bin/sh', '/bin/bash', '/bin/zsh'])
    if (File(path).existsSync()) path,
];

const _values = AgentWorktreeTemplateValues(
  tool: 'claude',
  date: '20261009',
  time: '1200',
  id: 'abc123',
);

void main() {
  test('quotes paths so the shell evaluates nothing but a leading ~', () {
    expect(
      quoteAgentWorktreeShellWord(r"it's $(rm -rf ~)"),
      r"'it'\''s $(rm -rf ~)'",
    );
    expect(quoteAgentWorktreeRemotePath('~'), r'"$HOME"');
    expect(
      quoteAgentWorktreeRemotePath(r'~/src/$app'),
      r'"$HOME"/'
      r"'src/$app'",
    );
    expect(quoteAgentWorktreeRemotePath('/srv/a b'), "'/srv/a b'");
  });

  test('parses the last marker line and ignores profile noise', () {
    expect(
      parseAgentWorktreeOutput(
        'Welcome!\nMSSH_WT\x1ferror\x1fno_git\x1f\nMSSH_WT\x1fstatus\x1f2\x1f0\x1fno\n',
      ),
      ['status', '2', '0', 'no'],
    );
    expect(parseAgentWorktreeOutput('no marker here'), isNull);
  });

  test('maps unreadable output to an unavailable error', () async {
    await expectLater(
      const AgentWorktreeService().tmuxSessionExists(_FixedShell(''), 'x'),
      throwsA(
        isA<AgentWorktreeException>().having(
          (error) => error.kind,
          'kind',
          AgentWorktreeErrorKind.unavailable,
        ),
      ),
    );
  });

  for (final shellPath in _availableShells()) {
    group('against a real repository with $shellPath', skip: Platform.isWindows, () {
      late Directory root;
      late String repository;
      late _LocalShell shell;
      const service = AgentWorktreeService();

      setUp(() async {
        root = await Directory.systemTemp.createTemp('mssh-worktree-');
        final resolvedRoot = root.resolveSymbolicLinksSync();
        repository = '$resolvedRoot/repo';
        await Directory('$repository/packages/app').create(recursive: true);
        await _git(resolvedRoot, ['init', '-q', 'repo']);
        await File('$repository/packages/app/README').writeAsString('hi\n');
        await _git(repository, ['add', '.']);
        await _git(repository, ['commit', '-q', '-m', 'init']);
        shell = _LocalShell(shellPath, home: resolvedRoot);
      });

      tearDown(() async {
        await root.delete(recursive: true);
      });

      Future<AgentWorktreeRecord> create({
        String? repositoryPath,
        String baseRef = 'HEAD',
        AgentWorktreeLaunchOptions options = const AgentWorktreeLaunchOptions(),
      }) => service.create(
        shell,
        hostId: 7,
        repository: repositoryPath ?? repository,
        baseRef: baseRef,
        target: renderAgentWorktreeTarget(options, _values),
      );

      test(
        'creates a worktree on a new branch beside the repository',
        () async {
          final record = await create();

          expect(record.branch, 'agent/claude-20261009-abc123');
          expect(record.repository, repository);
          expect(
            record.path,
            '$repository.worktrees/agent-claude-20261009-abc123',
          );
          expect(record.startDirectory, record.path);
          expect(
            record.baseCommit,
            await _git(repository, ['rev-parse', 'HEAD']),
          );
          expect(
            await _git(record.path, ['rev-parse', '--abbrev-ref', 'HEAD']),
            record.branch,
          );
          expect(
            File('${record.path}/packages/app/README').existsSync(),
            isTrue,
          );
        },
      );

      test(
        'starts in the subdirectory the repository path points at',
        () async {
          final record = await create(
            repositoryPath: '$repository/packages/app',
          );

          expect(record.repository, repository);
          expect(record.startDirectory, '${record.path}/packages/app');
        },
      );

      test('expands a leading ~ to the host home directory', () async {
        final record = await create(
          repositoryPath: '~/repo',
          options: const AgentWorktreeLaunchOptions(
            pathTemplate: '~/trees/{name}',
          ),
        );

        expect(
          record.path,
          '${root.resolveSymbolicLinksSync()}/trees/agent-claude-20261009-abc123',
        );
      });

      test('suffixes names when the branch or folder already exists', () async {
        final first = await create();
        await _git(repository, ['branch', 'agent/claude-20261009-abc123-2']);
        final second = await create();
        await Directory('$repository.worktrees/agent-claude-20261009-abc123-4')
            .create(recursive: true);
        final third = await create();

        expect(first.branch, 'agent/claude-20261009-abc123');
        expect(second.branch, 'agent/claude-20261009-abc123-3');
        expect(second.path, endsWith('agent-claude-20261009-abc123-3'));
        expect(third.branch, 'agent/claude-20261009-abc123-5');
      });

      test('branches from a resolved base ref without tracking it', () async {
        final firstCommit = await _git(repository, ['rev-parse', 'HEAD']);
        await File('$repository/second').writeAsString('2\n');
        await _git(repository, ['add', '.']);
        await _git(repository, ['commit', '-q', '-m', 'second']);

        final record = await create(baseRef: 'HEAD~1');

        expect(record.baseCommit, firstCommit);
        expect(await _git(record.path, ['rev-parse', 'HEAD']), firstCommit);
      });

      test('reports bad inputs without creating anything', () async {
        Future<AgentWorktreeErrorKind> kindOf(Future<Object?> future) async {
          try {
            await future;
          } on AgentWorktreeException catch (error) {
            return error.kind;
          }
          fail('expected an AgentWorktreeException');
        }

        expect(
          await kindOf(create(baseRef: 'no-such-ref')),
          AgentWorktreeErrorKind.invalidBase,
        );
        expect(
          await kindOf(create(repositoryPath: '${root.path}/missing')),
          AgentWorktreeErrorKind.repositoryMissing,
        );
        await Directory('${root.path}/plain').create();
        expect(
          await kindOf(create(repositoryPath: '${root.path}/plain')),
          AgentWorktreeErrorKind.notRepository,
        );
        expect(
          await kindOf(
            service.create(
              shell,
              hostId: 7,
              repository: repository,
              baseRef: 'HEAD',
              target: const AgentWorktreeTarget(
                branch: 'bad..name',
                path: '.worktrees/x',
                pathIsRepositoryRelative: true,
              ),
            ),
          ),
          AgentWorktreeErrorKind.invalidBranch,
        );
        expect(Directory('$repository.worktrees').existsSync(), isFalse);
        expect(
          await _git(repository, ['branch', '--list', 'agent/*']),
          isEmpty,
        );
      });

      test('treats hostile text in names as literal data', () async {
        final marker = File('${root.path}/pwned');
        final record = await service.create(
          shell,
          hostId: 7,
          repository: repository,
          baseRef: 'HEAD',
          target: AgentWorktreeTarget(
            branch: r"agent/$(touch-pwned)'x",
            path:
                "${root.path}/wt/\$(touch ${marker.path})'; touch ${marker.path}",
            pathIsRepositoryRelative: false,
          ),
        );

        expect(marker.existsSync(), isFalse);
        expect(record.branch, r"agent/$(touch-pwned)'x");
        expect(Directory(record.path).existsSync(), isTrue);
      });

      test('removes a clean worktree and its untouched branch', () async {
        final record = await create();

        final status = await service.status(shell, record);
        final removal = await service.remove(shell, record);

        expect(status.exists, isTrue);
        expect(status.isDirty, isFalse);
        expect(status.branchHasNewCommits, isFalse);
        expect(removal.branchDeleted, isTrue);
        expect(Directory(record.path).existsSync(), isFalse);
        expect(
          await _git(repository, ['branch', '--list', record.branch]),
          isEmpty,
        );
      });

      test('refuses to remove a worktree with uncommitted changes', () async {
        final record = await create();
        await File('${record.path}/notes.txt').writeAsString('work\n');
        await File('${record.path}/packages/app/README')
            .writeAsString('edit\n');

        final status = await service.status(shell, record);

        expect(status.isDirty, isTrue);
        expect(status.changedFiles, 2);
        await expectLater(
          service.remove(shell, record),
          throwsA(
            isA<AgentWorktreeException>().having(
              (error) => error.kind,
              'kind',
              AgentWorktreeErrorKind.dirty,
            ),
          ),
        );
        expect(File('${record.path}/notes.txt').existsSync(), isTrue);
      });

      test('keeps a branch that has new commits', () async {
        final record = await create();
        await File('${record.path}/feature').writeAsString('done\n');
        await _git(record.path, ['add', '.']);
        await _git(record.path, ['commit', '-q', '-m', 'feature']);

        final status = await service.status(shell, record);
        final removal = await service.remove(shell, record);

        expect(status.branchHasNewCommits, isTrue);
        expect(removal.branchDeleted, isFalse);
        expect(Directory(record.path).existsSync(), isFalse);
        expect(
          await _git(repository, ['branch', '--list', record.branch]),
          contains(record.branch),
        );
      });

      test('counts ignored files that removal would delete', () async {
        await File('$repository/.gitignore').writeAsString('build/\n');
        await _git(repository, ['add', '.']);
        await _git(repository, ['commit', '-q', '-m', 'ignore']);
        final record = await create();
        await Directory('${record.path}/build').create();
        await File('${record.path}/build/out').writeAsString('x');

        final status = await service.status(shell, record);

        expect(status.isDirty, isFalse);
        expect(status.ignoredEntries, 1);
      });

      test('forgets a worktree folder that is already gone', () async {
        final record = await create();
        await Directory(record.path).delete(recursive: true);

        final status = await service.status(shell, record);
        final removal = await service.remove(shell, record);

        expect(status.exists, isFalse);
        expect(removal.branchDeleted, isTrue);
        expect(
          await _git(repository, ['worktree', 'list']),
          isNot(contains('.worktrees')),
        );
      });
    });
  }

  group('AgentWorktreeRegistry', () {
    late AppDatabase database;
    late AgentWorktreeRegistry registry;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      registry = AgentWorktreeRegistry(SettingsService(database));
    });

    tearDown(() async {
      await database.close();
    });

    AgentWorktreeRecord record(int hostId, String path) => AgentWorktreeRecord(
      hostId: hostId,
      repository: '/srv/app',
      path: path,
      branch: 'agent/${path.split('/').last}',
      baseCommit: 'abc',
      createdAt: DateTime.utc(2026),
    );

    test('finds the record that contains a window directory', () async {
      await registry.add(record(1, '/srv/wt/a'));
      await registry.add(record(1, '/srv/wt/b'));
      await registry.add(record(2, '/srv/wt/c'));

      expect(
        (await registry.findContaining(1, '/srv/wt/b/lib'))?.path,
        '/srv/wt/b',
      );
      expect(await registry.findContaining(1, '/srv/wt/c'), isNull);
      expect((await registry.recordsForHost(1)).map((entry) => entry.path), [
        '/srv/wt/b',
        '/srv/wt/a',
      ]);
    });

    test('removes one record and clears empty hosts', () async {
      final first = record(1, '/srv/wt/a');
      await registry.add(first);
      await registry.add(record(1, '/srv/wt/b'));

      await registry.remove(first);
      expect((await registry.recordsForHost(1)).single.path, '/srv/wt/b');

      await registry.remove(record(1, '/srv/wt/b'));
      expect(
        await SettingsService(database).getJson(SettingKeys.agentWorktrees),
        isNull,
      );
    });
  });
}

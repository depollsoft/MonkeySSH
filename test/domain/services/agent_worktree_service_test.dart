// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
// SSHChannel is only exported from the implementation library.
// ignore: implementation_imports
import 'package:dartssh2/src/ssh_channel.dart';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/agent_worktree.dart';
import 'package:monkeyssh/domain/services/agent_worktree_launcher.dart';
import 'package:monkeyssh/domain/services/agent_worktree_registry.dart';
import 'package:monkeyssh/domain/services/agent_worktree_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

import '../../support/fake_agent_worktree.dart';

/// System directories every test process may use. The scripts add their own
/// git and tmux locations on top.
const _systemPath = '/usr/bin:/bin:/usr/sbin:/sbin';

/// A login shell name the scripts do not ask for a PATH, so a test controls
/// exactly which tools they find.
const _noLoginShell = '/nonexistent/fish';

/// Runs worktree scripts the way the SSH transport does: a fixed `-s`
/// command line with the script on stdin.
///
/// The process gets only the variables set here: a throwaway HOME and a
/// system PATH, so no real profile, dotfile or tool configuration is read.
class _LocalShell implements AgentWorktreeShell {
  _LocalShell(this.executable, {required this.home, String? loginShell})
    : loginShell = loginShell ?? executable;

  final String executable;
  final String home;
  final String loginShell;

  /// Throws after a script containing this text has run, as if the SSH
  /// channel timed out while the command kept going on the host.
  String? timeOutAfter;

  @override
  Future<AgentWorktreeExecResult> run(
    String script, {
    required Duration timeout,
  }) async {
    final process = await Process.start(
      executable,
      ['-s'],
      environment: {
        'HOME': home,
        'PATH': _systemPath,
        'SHELL': loginShell,
        'LANG': 'C',
        'TMPDIR': home,
      },
      includeParentEnvironment: false,
    );
    final stdout = process.stdout.transform(utf8.decoder).join();
    final stderr = process.stderr.drain<void>();
    process.stdin.add(utf8.encode(buildAgentWorktreeStdinPayload(script)));
    await process.stdin.close();
    final exitCode = await process.exitCode.timeout(timeout);
    await stderr;
    if (timeOutAfter case final marker? when script.contains(marker)) {
      throw TimeoutException('simulated', timeout);
    }
    return AgentWorktreeExecResult(stdout: await stdout, exitCode: exitCode);
  }
}

class _MockSshClient extends Mock implements SSHClient {}

class _MockExecSession extends Mock implements SSHSession {}

class _MockChannel extends Mock implements SSHChannel {}

class _FixedShell implements AgentWorktreeShell {
  _FixedShell(this.stdout);

  final String stdout;

  @override
  Future<AgentWorktreeExecResult> run(
    String script, {
    required Duration timeout,
  }) async => AgentWorktreeExecResult(stdout: stdout, exitCode: 0);
}

/// Runs git for test setup with the same isolated environment.
Future<String> _git(String home, String directory, List<String> args) async {
  final result = await Process.run(
    'git',
    [
      '-c',
      'user.email=test@example.com',
      '-c',
      'user.name=Test',
      '-c',
      'commit.gpgsign=false',
      '-c',
      'init.defaultBranch=main',
      '-C',
      directory,
      ...args,
    ],
    environment: {'HOME': home, 'PATH': _systemPath, 'LANG': 'C'},
    includeParentEnvironment: false,
  );
  if (result.exitCode != 0) {
    throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
  }
  return (result.stdout as String).trim();
}

/// Where test repositories live: `MSSH_WORKTREE_TEST_ROOT` when set,
/// otherwise the system temporary directory.
Future<Directory> _createRoot() {
  final configured = Platform.environment['MSSH_WORKTREE_TEST_ROOT'];
  final parent = configured == null || configured.isEmpty
      ? Directory.systemTemp
      : Directory(configured);
  return parent.createTemp('mssh-worktree-');
}

/// Shells a host's `/bin/sh` commonly is.
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

Matcher _throwsKind(AgentWorktreeErrorKind kind) => throwsA(
  isA<AgentWorktreeException>().having((error) => error.kind, 'kind', kind),
);

SSHSession _exec(String stdout, StreamController<Uint8List> input) {
  final exec = _MockExecSession();
  when(() => exec.channel).thenReturn(_MockChannel());
  when(() => exec.stdin).thenReturn(input.sink);
  when(() => exec.stdout)
      .thenAnswer((_) => Stream<Uint8List>.value(utf8.encode(stdout)));
  when(() => exec.stderr).thenAnswer((_) => const Stream.empty());
  when(() => exec.done).thenAnswer((_) async {});
  when(() => exec.exitCode).thenReturn(0);
  when(exec.close).thenReturn(null);
  return exec;
}

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

  test(
    'sends user content on stdin, never on the login shell command line',
    () async {
      final client = _MockSshClient();
      final received = <int>[];
      final inputs = <StreamController<Uint8List>>[];
      final replies = [
        'MSSH_WT\x1fplan\x1fbranch\x1f/w\x1fabc\x1f/r\x1f\n',
        'MSSH_WT\x1fok\x1f/w\x1f/w\x1f/w\n',
      ];
      final commands = <String>[];
      when(() => client.execute(any(), pty: any(named: 'pty')))
          .thenAnswer((invocation) async {
            commands.add(invocation.positionalArguments.first as String);
            final input = StreamController<Uint8List>();
            inputs.add(input);
            input.stream.listen(received.addAll);
            return _exec(replies.removeAt(0), input);
          });
      final session = SshSession(
        connectionId: 41,
        hostId: 7,
        client: client,
        config: const SshConnectionConfig(
          hostname: 'example.com',
          port: 22,
          username: 'dev',
        ),
      );
      const hostile = r"x'; rm -rf ~; echo \' $(id) `id`";

      await const AgentWorktreeService().create(
        SshAgentWorktreeShell(session),
        hostId: 7,
        repository: '/srv/$hostile',
        baseRef: 'main',
        target: const AgentWorktreeTarget(
          branch: 'agent/$hostile',
          path: '/srv/wt/$hostile',
          pathIsRepositoryRelative: false,
        ),
      );

      expect(commands, [agentWorktreeExecCommand, agentWorktreeExecCommand]);
      expect(commands.join(), isNot(contains('rm -rf')));
      final script = utf8.decode(received);
      expect(script, contains('rm -rf'));
      expect(script, startsWith('mssh_main() {'));
      expect(script, endsWith('mssh_main </dev/null\n'));
      for (final input in inputs) {
        await input.close();
      }
    },
  );

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
      const AgentWorktreeService().tmuxSessionDirectories(_FixedShell(''), 'x'),
      _throwsKind(AgentWorktreeErrorKind.unavailable),
    );
  });

  for (final shellPath in _availableShells()) {
    group(
      'against a real repository with $shellPath',
      skip: Platform.isWindows,
      () {
        late Directory root;
        late String home;
        late String repository;
        late _LocalShell shell;
        const service = AgentWorktreeService();

        Future<String> git(String directory, List<String> args) =>
            _git(home, directory, args);

        setUp(() async {
          root = await _createRoot();
          home = root.resolveSymbolicLinksSync();
          repository = '$home/repo';
          await Directory('$repository/packages/app').create(recursive: true);
          await git(home, ['init', '-q', 'repo']);
          await File('$repository/packages/app/README').writeAsString('hi\n');
          await git(repository, ['add', '.']);
          await git(repository, ['commit', '-q', '-m', 'init']);
          shell = _LocalShell(shellPath, home: home);
        });

        tearDown(() async {
          await root.delete(recursive: true);
        });

        var launches = 0;
        Future<AgentWorktreeRecord> create({
          String? repositoryPath,
          String baseRef = 'HEAD',
          AgentWorktreeLaunchOptions options =
              const AgentWorktreeLaunchOptions(),
          bool withLaunchId = true,
        }) => service.create(
          shell,
          hostId: 7,
          repository: repositoryPath ?? repository,
          baseRef: baseRef,
          target: renderAgentWorktreeTarget(options, _values),
          launchId: withLaunchId ? 'launch-${++launches}' : null,
        );

        Future<void> commit(
          String directory,
          String file,
          String message,
        ) async {
          await File('$directory/$file').writeAsString('$message\n');
          await git(directory, ['add', '.']);
          await git(directory, ['commit', '-q', '-m', message]);
        }

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
            expect(record.pending, isFalse);
            expect(
              record.baseCommit,
              await git(repository, ['rev-parse', 'HEAD']),
            );
            expect(
              await git(record.path, ['rev-parse', '--abbrev-ref', 'HEAD']),
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

          expect(record.path, '$home/trees/agent-claude-20261009-abc123');
        });

        test(
          'suffixes names when the branch or folder already exists',
          () async {
            final first = await create();
            await git(repository, ['branch', 'agent/claude-20261009-abc123-2']);
            final second = await create();
            await Directory(
              '$repository.worktrees/agent-claude-20261009-abc123-4',
            ).create(recursive: true);
            final third = await create();

            expect(first.branch, 'agent/claude-20261009-abc123');
            expect(second.branch, 'agent/claude-20261009-abc123-3');
            expect(second.path, endsWith('agent-claude-20261009-abc123-3'));
            expect(third.branch, 'agent/claude-20261009-abc123-5');
          },
        );

        test(
          'suffixes a branch that would collide with nested branches',
          () async {
            await git(repository, [
              'branch',
              'agent/claude-20261009-abc123/sub',
            ]);

            final record = await create();

            expect(record.branch, 'agent/claude-20261009-abc123-2');
          },
        );

        test('explains a branch that blocks the branch template', () async {
          await git(repository, ['branch', 'agent']);

          await expectLater(
            create(),
            _throwsKind(AgentWorktreeErrorKind.branchConflict),
          );
          expect(Directory('$repository.worktrees').existsSync(), isFalse);
        });

        test(
          'keeps collision suffixes beside a folder template ending in /',
          () async {
            const options = AgentWorktreeLaunchOptions(
              branchTemplate: 'agent/{tool}-{id}',
              pathTemplate: '{repo}.worktrees/{tool}/',
            );
            final first = await create(options: options);
            final second = await create(
              options: const AgentWorktreeLaunchOptions(
                branchTemplate: 'agent/{tool}-{id}-b',
                pathTemplate: '{repo}.worktrees/{tool}/',
              ),
            );

            expect(first.path, '$repository.worktrees/claude');
            expect(second.path, '$repository.worktrees/claude-2');
            expect((await service.status(shell, first)).isDirty, isFalse);
          },
        );

        test('branches from a resolved base ref without tracking it', () async {
          final firstCommit = await git(repository, ['rev-parse', 'HEAD']);
          await commit(repository, 'second', 'second');

          final record = await create(baseRef: 'HEAD~1');

          expect(record.baseCommit, firstCommit);
          expect(await git(record.path, ['rev-parse', 'HEAD']), firstCommit);
        });

        test('reports bad inputs without creating anything', () async {
          await expectLater(
            create(baseRef: 'no-such-ref'),
            _throwsKind(AgentWorktreeErrorKind.invalidBase),
          );
          await expectLater(
            create(repositoryPath: '$home/missing'),
            _throwsKind(AgentWorktreeErrorKind.repositoryMissing),
          );
          await Directory('$home/plain').create();
          await expectLater(
            create(repositoryPath: '$home/plain'),
            _throwsKind(AgentWorktreeErrorKind.notRepository),
          );
          await expectLater(
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
            _throwsKind(AgentWorktreeErrorKind.invalidBranch),
          );
          expect(Directory('$repository.worktrees').existsSync(), isFalse);
          expect(
            await git(repository, ['branch', '--list', 'agent/*']),
            isEmpty,
          );
        });

        test('treats hostile text in names as literal data', () async {
          final marker = File('$home/pwned');
          final record = await service.create(
            shell,
            hostId: 7,
            repository: repository,
            baseRef: 'HEAD',
            target: AgentWorktreeTarget(
              branch: r"agent/$(touch-pwned)'x",
              path: "$home/wt/\$(touch ${marker.path})'; touch ${marker.path}",
              pathIsRepositoryRelative: false,
            ),
          );

          expect(marker.existsSync(), isFalse);
          expect(record.branch, r"agent/$(touch-pwned)'x");
          expect(Directory(record.path).existsSync(), isTrue);
        });

        test('does not run repository hooks while checking out', () async {
          final marker = File('$home/hook-ran');
          final hook = File('$repository/.git/hooks/post-checkout');
          await hook.writeAsString('#!/bin/sh\ntouch "${marker.path}"\n');
          await Process.run('chmod', ['+x', hook.path]);

          await create();

          expect(marker.existsSync(), isFalse);
        });

        test('finds tmux through the login shell PATH', () async {
          // Only reachable through ~/.profile, which also prints noise.
          final bin = Directory('$home/custom-bin')..createSync();
          File('${bin.path}/tmux').writeAsStringSync(
            '#!/bin/sh\n'
            r'case "$1" in has-session) exit 0 ;; list-panes) echo /from/profile ;; *) exit 2 ;; esac'
            '\n',
          );
          await Process.run('chmod', ['+x', '${bin.path}/tmux']);
          File('$home/.profile').writeAsStringSync(
            'echo "profile noise"\n'
            r'PATH="$HOME/custom-bin:$PATH"; export PATH'
            '\n',
          );
          final loginShell = _LocalShell(
            shellPath,
            home: home,
            loginShell: '/bin/sh',
          );

          expect(await service.tmuxSessionDirectories(loginShell, 'agents'), [
            '/from/profile',
          ]);
        });

        test('removes a clean worktree and its untouched branch', () async {
          final record = await create();

          final status = await service.status(shell, record);
          final removal = await service.remove(shell, record);

          expect(status.exists, isTrue);
          expect(status.blocksRemoval, isFalse);
          expect(status.branchHasNewCommits, isFalse);
          expect(removal.branchDeleted, isTrue);
          expect(Directory(record.path).existsSync(), isFalse);
          expect(
            await git(repository, ['branch', '--list', record.branch]),
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
            _throwsKind(AgentWorktreeErrorKind.dirty),
          );
          expect(File('${record.path}/notes.txt').existsSync(), isTrue);
        });

        test('refuses to drop commits made on a detached HEAD', () async {
          final record = await create();
          await git(record.path, ['checkout', '-q', '--detach']);
          await commit(record.path, 'detached', 'detached work');
          final detached = await git(record.path, ['rev-parse', 'HEAD']);

          final status = await service.status(shell, record);

          expect(status.isDirty, isFalse);
          expect(status.unsavedCommits, isTrue);
          expect(status.blocksRemoval, isTrue);
          await expectLater(
            service.remove(shell, record),
            _throwsKind(AgentWorktreeErrorKind.unsavedCommits),
          );
          expect(Directory(record.path).existsSync(), isTrue);
          expect(await git(repository, ['cat-file', '-t', detached]), 'commit');
        });

        test(
          'removes a detached worktree whose commits are on a branch',
          () async {
            final record = await create();
            await git(record.path, ['checkout', '-q', '--detach']);
            await commit(record.path, 'saved', 'saved work');
            await git(record.path, ['branch', 'saved-work']);

            final status = await service.status(shell, record);
            await service.remove(shell, record);

            expect(status.unsavedCommits, isFalse);
            expect(Directory(record.path).existsSync(), isFalse);
            expect(
              await git(repository, ['branch', '--list', 'saved-work']),
              contains('saved-work'),
            );
          },
        );

        test(
          'refuses to remove a worktree stopped part-way through a rebase',
          () async {
            final record = await create();
            await commit(record.path, 'one', 'one');
            await commit(record.path, 'two', 'two');
            final editor = File('$home/sequence-editor')
              ..writeAsStringSync(
                "#!/bin/sh\nsed -i.bak '1s/^pick/edit/' \"\$1\"\n",
              );
            await Process.run('chmod', ['+x', editor.path]);
            await git(record.path, [
              '-c',
              'sequence.editor=${editor.path}',
              'rebase',
              '-i',
              'HEAD~2',
            ]);

            final status = await service.status(shell, record);

            expect(status.isDirty, isFalse);
            expect(status.operationInProgress, 'rebase-merge');
            await expectLater(
              service.remove(shell, record),
              _throwsKind(AgentWorktreeErrorKind.operationInProgress),
            );
            expect(Directory(record.path).existsSync(), isTrue);
          },
        );

        test(
          'leaves alone a different worktree made at a recorded path',
          () async {
            final record = await create();
            await service.remove(shell, record);
            await git(repository, [
              'worktree',
              'add',
              '-q',
              '-b',
              'mine',
              record.path,
            ]);

            final status = await service.status(shell, record);

            expect(status.stale, isTrue);
            await expectLater(
              service.remove(shell, record),
              _throwsKind(AgentWorktreeErrorKind.stale),
            );
            expect(Directory(record.path).existsSync(), isTrue);
          },
        );

        test('treats a plain folder at a recorded path as stale', () async {
          final record = await create();
          await service.remove(shell, record);
          await Directory(record.path).create(recursive: true);
          await File('${record.path}/keep').writeAsString('mine');

          expect((await service.status(shell, record)).stale, isTrue);
          await expectLater(
            service.remove(shell, record),
            _throwsKind(AgentWorktreeErrorKind.stale),
          );
          expect(File('${record.path}/keep').existsSync(), isTrue);
        });

        test(
          'keeps a worktree recorded through a branch switch and rename',
          () async {
            final record = await create();
            await git(record.path, ['checkout', '-q', '-b', 'feature/x']);

            var status = await service.status(shell, record);
            expect(status.stale, isFalse);
            expect(status.currentBranch, 'feature/x');
            expect(status.branchHasNewCommits, isTrue);

            await git(record.path, [
              'branch',
              '-m',
              'feature/x',
              'feat/pretty',
            ]);
            status = await service.status(shell, record);
            expect(status.stale, isFalse);
            expect(status.currentBranch, 'feat/pretty');

            await service.remove(shell, record);
            expect(Directory(record.path).existsSync(), isFalse);
            expect(
              await git(repository, ['branch', '--list', 'feat/pretty']),
              contains('feat/pretty'),
            );
            expect(
              await git(repository, ['branch', '--list', record.branch]),
              isEmpty,
            );
          },
        );

        test('records without a launch id fall back to the branch', () async {
          final record = await create(withLaunchId: false);
          await git(record.path, ['checkout', '-q', '-b', 'feature/x']);

          expect((await service.status(shell, record)).stale, isTrue);
        });

        test('does not count per-worktree refs as keeping a commit', () async {
          final record = await create();
          await git(record.path, ['checkout', '-q', '--detach']);
          await commit(record.path, 'kept', 'kept by a worktree ref');
          await git(record.path, ['update-ref', 'refs/worktree/keep', 'HEAD']);

          expect((await service.status(shell, record)).unsavedCommits, isTrue);
          await expectLater(
            service.remove(shell, record),
            _throwsKind(AgentWorktreeErrorKind.unsavedCommits),
          );
          expect(Directory(record.path).existsSync(), isTrue);
        });

        test('keeps a branch that has new commits', () async {
          final record = await create();
          await commit(record.path, 'feature', 'feature');

          final status = await service.status(shell, record);
          final removal = await service.remove(shell, record);

          expect(status.branchHasNewCommits, isTrue);
          expect(removal.branchDeleted, isFalse);
          expect(Directory(record.path).existsSync(), isFalse);
          expect(
            await git(repository, ['branch', '--list', record.branch]),
            contains(record.branch),
          );
        });

        test(
          'counts ignored files even when untracked files are hidden',
          () async {
            await File('$repository/.gitignore').writeAsString('build/\n');
            await git(repository, ['add', '.']);
            await git(repository, ['commit', '-q', '-m', 'ignore']);
            await git(repository, [
              'config',
              'status.showUntrackedFiles',
              'no',
            ]);
            final record = await create();
            await Directory('${record.path}/build').create();
            await File('${record.path}/build/out').writeAsString('x');

            final status = await service.status(shell, record);

            expect(status.isDirty, isFalse);
            expect(status.ignoredEntries, 1);
          },
        );

        test('forgets a worktree folder that is already gone', () async {
          final record = await create();
          await Directory(record.path).delete(recursive: true);

          final status = await service.status(shell, record);
          final removal = await service.remove(shell, record);

          expect(status.exists, isFalse);
          expect(removal.branchDeleted, isTrue);
          expect(
            await git(repository, ['worktree', 'list', '--porcelain']),
            isNot(contains('worktree ${record.path}')),
          );
        });

        group('launcher', () {
          late MemoryAgentWorktreeRegistry registry;
          var now = DateTime.utc(2026, 10, 9, 12);
          AgentLaunchPreset launchPreset() => AgentLaunchPreset(
            tool: AgentLaunchTool.claudeCode,
            workingDirectory: repository,
            tmuxSessionName: 'agents',
            worktree: const AgentWorktreeLaunchOptions(),
          );

          AgentWorktreeLauncher launcher() => AgentWorktreeLauncher(
            service: service,
            registry: registry,
            clock: () => now,
          );

          setUp(() {
            registry = MemoryAgentWorktreeRegistry();
            now = DateTime.utc(2026, 10, 9, 12);
          });

          test('a create that times out stays recorded and a later launch cleans it up', () async {
            shell.timeOutAfter = 'worktree add';

            await expectLater(
              launcher().create(
                shell,
                hostId: 7,
                preset: launchPreset(),
                windowsHost: false,
              ),
              _throwsKind(AgentWorktreeErrorKind.unavailable),
            );
            final orphan = registry.records.single;
            expect(orphan.pending, isTrue);
            expect(Directory(orphan.path).existsSync(), isTrue);

            shell.timeOutAfter = null;
            now = now.add(const Duration(minutes: 11));
            final record = await launcher().create(
              shell,
              hostId: 7,
              preset: launchPreset(),
              windowsHost: false,
            );

            expect(Directory(orphan.path).existsSync(), isFalse);
            expect(
              await git(repository, ['branch', '--list', orphan.branch]),
              isEmpty,
            );
            expect(registry.records, [record]);
          });

          test(
            'a fresh pending record from another launch is left alone',
            () async {
              shell.timeOutAfter = 'worktree add';
              await expectLater(
                launcher().create(
                  shell,
                  hostId: 7,
                  preset: launchPreset(),
                  windowsHost: false,
                ),
                _throwsKind(AgentWorktreeErrorKind.unavailable),
              );
              final inFlight = registry.records.single;
              shell.timeOutAfter = null;

              await launcher().create(
                shell,
                hostId: 7,
                preset: launchPreset(),
                windowsHost: false,
              );

              expect(Directory(inFlight.path).existsSync(), isTrue);
              expect(registry.records, contains(inFlight));
            },
          );

          test('undoes the worktree when recording it fails', () async {
            registry.failAdd = (record) => !record.pending;

            await expectLater(
              launcher().create(
                shell,
                hostId: 7,
                preset: launchPreset(),
                windowsHost: false,
              ),
              _throwsKind(AgentWorktreeErrorKind.unavailable),
            );

            expect(Directory('$repository.worktrees').listSync(), isEmpty);
            expect(
              await git(repository, ['branch', '--list', 'agent/*']),
              isEmpty,
            );
          });
        });
      },
    );
  }

  group('tmux session probe', skip: Platform.isWindows, () {
    late Directory root;
    late String home;
    late _LocalShell shell;
    const service = AgentWorktreeService();

    setUp(() async {
      root = await _createRoot();
      home = root.resolveSymbolicLinksSync();
      // First on the scripts' PATH, ahead of any real tmux.
      final bin = Directory('$home/.local/bin')..createSync(recursive: true);
      File('${bin.path}/tmux').writeAsStringSync(
        '#!/bin/sh\n'
        r'state="$HOME/panes"'
        '\n'
        r'case "$1" in'
        '\n'
        r'  has-session) if [ -f "$state.err" ]; then cat "$state.err" >&2; exit 1; fi'
        '\n'
        r'    if [ -f "$HOME/want-tmpdir" ] && [ "${TMUX_TMPDIR-}" != "$(cat "$HOME/want-tmpdir")" ]; then echo "no server running on x" >&2; exit 1; fi'
        '\n'
        r'''    [ -f "$state" ] || { echo "can't find session: agents" >&2; exit 1; } ;;'''
        '\n'
        r'  list-panes) [ ! -f "$state.fail" ] && cat "$state" ;;'
        '\n'
        '  *) exit 2 ;;\n'
        'esac\n',
      );
      await Process.run('chmod', ['+x', '${bin.path}/tmux']);
      shell = _LocalShell('/bin/sh', home: home, loginShell: _noLoginShell);
    });

    tearDown(() async {
      final pid = File('$home/sleep.pid');
      if (pid.existsSync()) {
        Process.killPid(int.parse(pid.readAsStringSync().trim()));
      }
      await root.delete(recursive: true);
    });

    test(
      'treats an unexpected tmux error as unknown, not as no session',
      () async {
        File('$home/panes.err')
            .writeAsStringSync('error connecting to x (Permission denied)\n');

        await expectLater(
          service.tmuxSessionDirectories(shell, 'agents'),
          _throwsKind(AgentWorktreeErrorKind.unavailable),
        );
      },
    );

    test('looks for the server where the login profile points tmux', () async {
      File('$home/panes').writeAsStringSync('/srv/a\n');
      File('$home/want-tmpdir').writeAsStringSync('$home/sockets');
      File('$home/.profile').writeAsStringSync(
        // The fake tmux stays first on the login PATH, ahead of any real one.
        r'PATH="$HOME/.local/bin:$PATH"; export PATH'
        '\n'
        r'TMUX_TMPDIR="$HOME/sockets"; export TMUX_TMPDIR'
        '\n',
      );
      final loginShell = _LocalShell(
        '/bin/sh',
        home: home,
        loginShell: '/bin/sh',
      );

      expect(await service.tmuxSessionDirectories(loginShell, 'agents'), [
        '/srv/a',
      ]);
    });

    test(
      'a background job in the login profile does not stall scripts',
      () async {
        File('$home/.profile').writeAsStringSync(
          r'PATH="$HOME/.local/bin:$PATH"; export PATH'
          '\n'
          r'sleep 5 & echo $! > "$HOME/sleep.pid"'
          '\n',
        );
        final loginShell = _LocalShell(
          '/bin/sh',
          home: home,
          loginShell: '/bin/sh',
        );
        final stopwatch = Stopwatch()..start();

        await service.tmuxSessionDirectories(loginShell, 'agents');

        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
      },
    );

    test('reports a missing session as null', () async {
      expect(await service.tmuxSessionDirectories(shell, 'agents'), isNull);
    });

    test('lists each pane directory of a running session', () async {
      File('$home/panes').writeAsStringSync('/srv/a b\n/srv/c\n');

      expect(await service.tmuxSessionDirectories(shell, 'agents'), [
        '/srv/a b',
        '/srv/c',
      ]);
    });

    test('treats a listing failure as unknown, not as no session', () async {
      File('$home/panes').writeAsStringSync('/srv/a\n');
      File('$home/panes.fail').writeAsStringSync('');

      await expectLater(
        service.tmuxSessionDirectories(shell, 'agents'),
        _throwsKind(AgentWorktreeErrorKind.unavailable),
      );
    });
  });

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

    AgentWorktreeRecord record(
      int hostId,
      String path, {
      bool pending = false,
    }) => AgentWorktreeRecord(
      hostId: hostId,
      repository: '/srv/app',
      path: path,
      branch: 'agent/${path.split('/').last}',
      baseCommit: 'abc',
      createdAt: DateTime.utc(2026),
      pending: pending,
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

    test('never offers a pending record for removal', () async {
      await registry.add(record(1, '/srv/wt/p', pending: true));

      expect(await registry.findContaining(1, '/srv/wt/p'), isNull);
      expect((await registry.recordsForHost(1)).single.pending, isTrue);
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

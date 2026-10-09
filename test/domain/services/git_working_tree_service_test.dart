// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/git_working_tree.dart';
import 'package:monkeyssh/domain/services/git_working_tree_service.dart';
import 'package:monkeyssh/domain/services/ssh_exec_queue.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

import '../../helpers/mock_ssh_exec_session.dart';

const _marker = '__MSSH_GIT_test__';

/// Runs a script the way sshd would: [loginShell] parses only
/// [kGitHostCommandLine] and the script arrives on stdin. Real git runs with
/// global and system config ignored so the developer's config cannot leak in.
GitCommandRunner _localRunner({
  required String home,
  String loginShell = '/bin/sh',
  String? workingDirectory,
  Map<String, String> environment = const {},
}) => (script, {required maxBytes, required timeout}) async {
  final process = await Process.start(
    loginShell,
    ['-c', kGitHostCommandLine],
    workingDirectory: workingDirectory,
    environment: {
      'HOME': home,
      'GIT_CONFIG_GLOBAL': '/dev/null',
      'GIT_CONFIG_NOSYSTEM': '1',
      ...environment,
    },
  );
  process.stdin.add(utf8.encode(script));
  await process.stdin.close();
  final bytes = BytesBuilder(copy: false);
  var truncated = false;
  final stderr = process.stderr.drain<void>();
  await for (final chunk in process.stdout) {
    final remaining = maxBytes - bytes.length;
    if (chunk.length > remaining) {
      bytes.add(chunk.sublist(0, remaining));
      truncated = true;
      process.kill();
      break;
    }
    bytes.add(chunk);
  }
  await process.exitCode.timeout(timeout);
  await stderr;
  return GitCommandOutput(
    stdout: const Utf8Decoder(allowMalformed: true).convert(bytes.takeBytes()),
    truncated: truncated,
  );
};

/// Wraps [runner] so every script reads at most [cap] bytes.
GitCommandRunner _capped(GitCommandRunner runner, int cap) =>
    (script, {required maxBytes, required timeout}) =>
        runner(script, maxBytes: cap, timeout: timeout);

/// File names built to break out of shell quoting. Each tries to create a
/// `CANARY*` file through command substitution, a backtick, `;`, or the
/// backslash-quote sequences fish reads differently from POSIX shells.
const _hostileNames = [
  r"q'$(touch CANARY1)'.txt",
  r"b\'$(touch CANARY2)\'.txt",
  r'n"$(touch CANARY3)".txt',
  't`touch CANARY4`.txt',
  's;touch CANARY5;.txt',
  r"e\';touch CANARY6;'\.txt",
];

/// Records what an SSH session was asked to run and what reached stdin.
class _RecordingSshSession extends Fake implements SshSession {
  _RecordingSshSession(this.reply);

  /// Builds stdout for a script.
  final String Function(String script) reply;
  final commandLines = <String>[];
  final scripts = <String>[];

  @override
  Future<T> runQueuedExec<T>(
    Future<T> Function() operation, {
    SshExecPriority priority = SshExecPriority.normal,
  }) => operation();

  @override
  Future<SSHSession> execute(String command, {SSHPtyConfig? pty}) async {
    commandLines.add(command);
    final exec = MockSessionWithChannel();
    // Closed by the code under test once the script is written.
    // ignore: close_sinks
    final stdin = StreamController<Uint8List>();
    final stdout = StreamController<Uint8List>();
    final done = Completer<void>();
    final received = BytesBuilder();
    stdin.stream.listen(
      received.add,
      onDone: () {
        final script = utf8.decode(received.takeBytes());
        scripts.add(script);
        stdout.add(Uint8List.fromList(utf8.encode(reply(script))));
        unawaited(stdout.close());
        done.complete();
      },
    );
    when(() => exec.stdin).thenReturn(stdin.sink);
    when(() => exec.stdout).thenAnswer((_) => stdout.stream);
    when(() => exec.stderr).thenAnswer((_) => const Stream.empty());
    when(() => exec.done).thenAnswer((_) => done.future);
    when(exec.close).thenReturn(null);
    when(exec.channel.destroy).thenReturn(null);
    return exec;
  }
}

Future<void> _git(Directory repo, List<String> args) async {
  final result = await Process.run(
    'git',
    [
      '-c',
      'user.email=test@example.com',
      '-c',
      'user.name=Test',
      '-c',
      'init.defaultBranch=main',
      '-c',
      'commit.gpgsign=false',
      ...args,
    ],
    workingDirectory: repo.path,
    environment: {'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_NOSYSTEM': '1'},
  );
  if (result.exitCode != 0) {
    fail('git ${args.join(' ')} failed: ${result.stderr}');
  }
}

void _write(Directory repo, String path, String contents) {
  File('${repo.path}/$path')
    ..createSync(recursive: true)
    ..writeAsStringSync(contents);
}

GitChangedFile _file(
  GitWorkingTreeSnapshot snapshot,
  GitChangeGroup group,
  String path,
) => snapshot.files.singleWhere(
  (file) => file.group == group && file.path == path,
);

void main() {
  group('parseGitNumstatZ', () {
    test('reads text, binary, and rename entries', () {
      final counts = parseGitNumstatZ(
        [
          '3\t1\tlib/a.dart',
          '-\t-\tassets/logo.png',
          '0\t0\t',
          'old name.txt',
          'new name.txt',
          '2\t0\tst.txt',
          '',
        ].join('\u0000'),
      );
      expect(counts['lib/a.dart'], const GitLineCounts(added: 3, removed: 1));
      expect(counts['assets/logo.png'], const GitLineCounts.binary());
      expect(counts['new name.txt'], const GitLineCounts(added: 0, removed: 0));
      expect(counts.containsKey('old name.txt'), isFalse);
      expect(counts['st.txt'], const GitLineCounts(added: 2, removed: 0));
    });

    test('keeps the last entry for a repeated unmerged path', () {
      final counts = parseGitNumstatZ('0\t0\tf\u00004\t0\tf\u0000');
      expect(counts['f'], const GitLineCounts(added: 4, removed: 0));
    });

    test('ignores empty and malformed output', () {
      expect(parseGitNumstatZ(''), isEmpty);
      expect(parseGitNumstatZ('nonsense\u0000x\ty\tz\u0000'), isEmpty);
    });
  });

  group('parseGitStatusPorcelainV2Z', () {
    const oid = '0000000000000000000000000000000000000000';
    String ordinary(String code, String path, {String sub = 'N...'}) =>
        '1 $code $sub 100644 100644 100644 $oid $oid $path';

    test('splits staged, unstaged, untracked, renamed and conflicts', () {
      final parsed = parseGitStatusPorcelainV2Z(
        [
          '# branch.oid abc',
          '# branch.head feature/x',
          ordinary('.M', 'lib/a dart.dart'),
          ordinary('AM', 'st.txt'),
          '2 R. N... 100644 100644 100644 $oid $oid R100 renamed.txt',
          'sp ace.txt',
          'u UU N... 100644 100644 100644 100644 $oid $oid $oid conflict.txt',
          '? new dir/file.txt',
          ordinary('.M', 'vendor/lib', sub: 'SC..'),
          '',
        ].join('\u0000'),
      );
      expect(parsed.branch, 'feature/x');
      expect(parsed.detached, isFalse);
      expect(parsed.truncated, isFalse);
      expect(
        [
          for (final file in parsed.files)
            '${file.group.name}:${file.kind.name}:${file.path}',
        ],
        [
          'conflicted:conflicted:conflict.txt',
          'staged:renamed:renamed.txt',
          'staged:added:st.txt',
          'unstaged:modified:lib/a dart.dart',
          'unstaged:modified:st.txt',
          'unstaged:modified:vendor/lib',
          'untracked:untracked:new dir/file.txt',
        ],
      );
      final renamed = parsed.files.firstWhere((f) => f.path == 'renamed.txt');
      expect(renamed.originalPath, 'sp ace.txt');
      final conflict = parsed.files.first;
      expect(conflict.statusCode, 'UU');
      expect(
        parsed.files.singleWhere((f) => f.path == 'vendor/lib').isSubmodule,
        isTrue,
      );
    });

    test('reports a detached HEAD', () {
      final parsed = parseGitStatusPorcelainV2Z(
        '# branch.oid abc\u0000# branch.head (detached)\u0000',
      );
      expect(parsed.detached, isTrue);
      expect(parsed.branch, isNull);
      expect(parsed.files, isEmpty);
    });

    test('drops a partial trailing entry from cut-off output', () {
      final parsed = parseGitStatusPorcelainV2Z(
        '? one.txt\u0000? two.txt\u0000? thr',
        complete: false,
      );
      expect(parsed.files.map((f) => f.path), ['one.txt', 'two.txt']);
      expect(parsed.truncated, isTrue);
    });

    test('caps the number of entries', () {
      final parsed = parseGitStatusPorcelainV2Z(
        [for (var i = 0; i < 10; i++) '? f$i.txt', ''].join('\u0000'),
        maxEntries: 4,
      );
      expect(parsed.files, hasLength(4));
      expect(parsed.truncated, isTrue);
    });
  });

  group('parseGitWorkingTreeOutput', () {
    final at = DateTime(2026, 10, 9, 14, 3, 12);

    for (final (section, state) in [
      ('no-git', GitWorkingTreeState.gitUnavailable),
      ('no-dir', GitWorkingTreeState.missingDirectory),
      ('unsafe', GitWorkingTreeState.unsafeRepository),
      ('not-repo', GitWorkingTreeState.notRepository),
    ]) {
      test('maps $section to $state', () {
        final snapshot = parseGitWorkingTreeOutput(
          '$_marker:$section\n',
          marker: _marker,
          outputTruncated: false,
          refreshedAt: at,
        );
        expect(snapshot.state, state);
        expect(snapshot.refreshedAt, at);
      });
    }

    test('reports a failing git status with its exit code', () {
      final snapshot = parseGitWorkingTreeOutput(
        '$_marker:root\n/r\n$_marker:unstaged\n\n$_marker:staged\n\n'
        '$_marker:status\n\n$_marker:status-exit:128\n',
        marker: _marker,
        outputTruncated: false,
        refreshedAt: at,
      );
      expect(snapshot.state, GitWorkingTreeState.failed);
      expect(snapshot.exitCode, 128);
    });

    test('drops a cut-off numstat path instead of misattributing it', () {
      const oid = '0000000000000000000000000000000000000000';
      final snapshot = parseGitWorkingTreeOutput(
        [
          '$_marker:root\n/r\n',
          '$_marker:status\n',
          '1 .M N... 100644 100644 100644 $oid $oid src/a\u0000',
          '1 .M N... 100644 100644 100644 $oid $oid src/ab\u0000',
          '\n$_marker:status-exit:0\n',
          // The cap cut `src/ab` short, leaving a name that matches `src/a`.
          '$_marker:unstaged\n1\t1\tsrc/a\u00009\t9\tsrc/a',
        ].join(),
        marker: _marker,
        outputTruncated: true,
        refreshedAt: at,
      );
      expect(snapshot.state, GitWorkingTreeState.ready);
      expect(snapshot.truncated, isTrue);
      final counts = {
        for (final file in snapshot.files) file.path: file.counts,
      };
      expect(counts['src/a'], const GitLineCounts(added: 1, removed: 1));
      expect(counts['src/ab'], isNull);
    });

    test('is truncated when the status section never finished', () {
      final snapshot = parseGitWorkingTreeOutput(
        [
          '$_marker:root\n/r\n$_marker:unstaged\n1\t0\ta\u0000\n',
          '$_marker:staged\n\n$_marker:status\n# branch.head main\u0000',
          '1 .M N... 100644 100644 100644 x y a\u0000? b',
        ].join(),
        marker: _marker,
        outputTruncated: true,
        refreshedAt: at,
      );
      expect(snapshot.state, GitWorkingTreeState.ready);
      expect(snapshot.truncated, isTrue);
      expect(snapshot.repositoryRoot, '/r');
      expect(
        snapshot.files.single.counts,
        const GitLineCounts(added: 1, removed: 0),
      );
    });
  });

  group('parseGitUnifiedDiff', () {
    test('splits header lines and hunks with line numbers', () {
      final diff = parseGitUnifiedDiff(
        'diff --git a/f b/f\n'
        'index 1..2 100644\n'
        '--- a/f\n'
        '+++ b/f\n'
        '@@ -1,3 +1,4 @@ void main()\n'
        ' a\n'
        '-b\n'
        '+B\n'
        ' c\n'
        '+d\n'
        '@@ -20 +21,2 @@\n'
        ' x\n'
        '+y\n',
        truncated: false,
      );
      expect(diff.headerLines, hasLength(4));
      expect(diff.binary, isFalse);
      expect(diff.hunks, hasLength(2));
      final first = diff.hunks.first;
      expect(first.header, '@@ -1,3 +1,4 @@ void main()');
      expect(first.lines, [' a', '-b', '+B', ' c', '+d']);
      expect(
        (first.oldStart, first.oldCount, first.newStart, first.newCount),
        (1, 3, 1, 4),
      );
      final second = diff.hunks.last;
      expect((second.oldStart, second.oldCount), (20, 1));
      expect((second.newStart, second.newCount), (21, 2));
      expect(gitUnchangedLinesBetween(null, first), 0);
      expect(gitUnchangedLinesBetween(first, second), 16);
    });

    test('reads combined conflict hunks', () {
      final diff = parseGitUnifiedDiff(
        'diff --cc f\n@@@ -1,2 -1,2 +1,6 @@@\n  a\n++<<<<<<< HEAD\n',
        truncated: false,
      );
      expect(diff.hunks.single.newStart, 1);
      expect(diff.hunks.single.newCount, 6);
      expect(diff.hunks.single.lines, ['  a', '++<<<<<<< HEAD']);
    });

    test('flags binary changes', () {
      final diff = parseGitUnifiedDiff(
        'diff --git a/x b/x\nBinary files a/x and b/x differ\n',
        truncated: false,
      );
      expect(diff.binary, isTrue);
      expect(diff.hunks, isEmpty);
    });
  });

  group('buildGitHunkPrompt', () {
    const file = GitChangedFile(
      path: 'lib/a.dart',
      group: GitChangeGroup.unstaged,
      kind: GitChangeKind.modified,
    );

    test('quotes the hunk in a diff fence and leaves room to type', () {
      final prompt = buildGitHunkPrompt(
        file: file,
        hunk: GitDiffHunk(header: '@@ -1 +1 @@', lines: const ['-a', '+b']),
      );
      expect(
        prompt,
        'About this hunk in lib/a.dart (an unstaged change in the working '
        'tree):\n\n```diff\n@@ -1 +1 @@\n-a\n+b\n```\n\n',
      );
    });

    test('lengthens the fence past backticks in the hunk', () {
      final prompt = buildGitHunkPrompt(
        file: file,
        hunk: GitDiffHunk(header: '@@ -1 +1 @@', lines: const ['+```dart']),
      );
      expect(prompt, contains('````diff\n'));
      expect(prompt, contains('\n````\n'));
    });

    test('cuts long hunks and says how much is missing', () {
      final prompt = buildGitHunkPrompt(
        file: file,
        hunk: GitDiffHunk(
          header: '@@ -1,500 +1,500 @@',
          lines: [for (var i = 0; i < 500; i++) '+line $i'],
        ),
      );
      expect(prompt, contains('+line 199'));
      expect(prompt, isNot(contains('+line 200\n')));
      expect(prompt, contains('(300 more lines of this hunk not shown)'));
    });
  });

  group('gitShellPathArgument', () {
    test('expands a leading tilde through HOME and quotes the rest', () {
      expect(gitShellPathArgument('~'), r'"$HOME"');
      const expected =
          r'"$HOME"'
          r"'/it'\''s here'";
      expect(gitShellPathArgument("~/it's here"), expected);
      expect(gitShellPathArgument('/srv/a b'), "'/srv/a b'");
      expect(gitShellPathArgument('-x'), "'./-x'");
    });
  });

  group('collectCappedSshExecOutput', () {
    late MockSessionWithChannel exec;
    late StreamController<Uint8List> stdout;
    late Completer<void> done;
    // Closed by the code under test.
    // ignore: close_sinks
    late StreamController<Uint8List> stdin;
    late List<int> stdinBytes;

    setUp(() {
      exec = MockSessionWithChannel();
      stdout = StreamController<Uint8List>();
      stdin = StreamController<Uint8List>();
      stdinBytes = <int>[];
      stdin.stream.listen(stdinBytes.addAll);
      done = Completer<void>();
      when(() => exec.stdin).thenReturn(stdin.sink);
      when(() => exec.stdout).thenAnswer((_) => stdout.stream);
      when(() => exec.stderr).thenAnswer((_) => const Stream.empty());
      when(() => exec.done).thenAnswer((_) => done.future);
      when(exec.close).thenReturn(null);
      when(() => exec.channel.destroy()).thenReturn(null);
    });

    tearDown(() async {
      await stdout.close();
    });

    test('returns all output and closes the channel normally', () async {
      final result = collectCappedSshExecOutput(
        exec,
        stdin: utf8.encode('echo hi\n'),
        maxBytes: 64,
        timeout: const Duration(seconds: 5),
      );
      await pumpEventQueue();
      expect(utf8.decode(stdinBytes), 'echo hi\n');
      expect(stdin.isClosed, isTrue);
      stdout
        ..add(Uint8List.fromList(utf8.encode('hello ')))
        ..add(Uint8List.fromList(utf8.encode('world')));
      await stdout.close();
      done.complete();
      final output = await result;
      expect(output.stdout, 'hello world');
      expect(output.truncated, isFalse);
      verify(exec.close).called(1);
      verifyNever(() => exec.channel.destroy());
    });

    test('stops at the cap and destroys the channel', () async {
      final result = collectCappedSshExecOutput(
        exec,
        maxBytes: 5,
        timeout: const Duration(seconds: 5),
      );
      stdout.add(Uint8List.fromList(utf8.encode('hello world')));
      final output = await result;
      expect(output.stdout, 'hello');
      expect(output.truncated, isTrue);
      verify(() => exec.channel.destroy()).called(1);
    });

    test('times out and destroys the channel', () async {
      await expectLater(
        collectCappedSshExecOutput(
          exec,
          maxBytes: 5,
          timeout: const Duration(milliseconds: 10),
        ),
        throwsA(isA<TimeoutException>()),
      );
      verify(() => exec.channel.destroy()).called(1);
    });
  });

  group('GitWorkingTreeService.ssh', () {
    test('the login shell only ever sees the fixed command line', () async {
      final session = _RecordingSshSession((script) {
        final marker = RegExp(
          r"^m='([^']+)'$",
          multiLine: true,
        ).firstMatch(script)!.group(1)!;
        if (script.contains(':diff')) {
          return '$marker:diff\n\n$marker:exit:0\n';
        }
        if (script.contains(':counts')) {
          return '$marker:counts\n\n$marker:end\n';
        }
        return '$marker:not-repo\n';
      });
      final service = GitWorkingTreeService.ssh(session);
      const directory = r"/srv/x'$(touch CANARY)'\\";

      expect(
        (await service.loadStatus(directory)).state,
        GitWorkingTreeState.notRepository,
      );
      for (final name in _hostileNames) {
        await service.loadDiff(
          directory,
          GitChangedFile(
            path: name,
            group: GitChangeGroup.untracked,
            kind: GitChangeKind.untracked,
          ),
        );
      }
      await service.loadUntrackedCounts(directory, _hostileNames);

      // Every exec request is the constant line; paths only travel on stdin.
      expect(session.commandLines, hasLength(_hostileNames.length + 2));
      expect(session.commandLines.toSet(), {kGitHostCommandLine});
      expect(session.scripts, hasLength(session.commandLines.length));
      for (final script in session.scripts) {
        expect(script, contains(gitShellPathArgument(directory)));
      }
      final scripts = session.scripts.join();
      for (final name in _hostileNames) {
        expect(scripts, contains(gitShellPathArgument(name)));
      }
    });
  });

  group('GitWorkingTreeService against real git', () {
    late Directory temp;
    late Directory repo;
    late GitWorkingTreeService service;

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('git_working_tree_test');
      repo = Directory('${temp.path}/repo')..createSync();
      service = GitWorkingTreeService(
        _localRunner(home: temp.path),
        markerFactory: () => _marker,
      );
      await _git(repo, ['init', '-q']);
      _write(repo, 'f1.txt', 'a\nb\nc\n');
      _write(repo, 'sp ace.txt', 'x\n');
      _write(repo, 'gone.txt', 'bye\n');
      _write(repo, '[a]*.txt', 'glob\n');
      _write(repo, 'a.txt', 'plain\n');
      await _git(repo, ['add', '.']);
      await _git(repo, ['commit', '-qm', 'init']);

      _write(repo, 'f1.txt', 'a\nB\nc\nd\n');
      await _git(repo, ['mv', 'sp ace.txt', 'renamed.txt']);
      File('${repo.path}/gone.txt').deleteSync();
      _write(repo, 'st.txt', 'staged\n');
      await _git(repo, ['add', 'st.txt']);
      _write(repo, 'st.txt', 'staged\nmore\n');
      _write(repo, '[a]*.txt', 'glob\nchanged\n');
      _write(repo, 'a.txt', 'plain\nalso changed\n');
      _write(repo, 'untracked.txt', 'u1\nu2');
      _write(repo, 'd/new.md', 'deep\n');
      _write(repo, 'ünï.txt', 'unicode\n');
      File('${repo.path}/bin.dat').writeAsBytesSync([0, 1, 2, 0, 3]);
    });

    tearDown(() {
      temp.deleteSync(recursive: true);
    });

    test('lists every changed file with correct counts', () async {
      final snapshot = await service.loadStatus('${repo.path}/d');
      expect(snapshot.state, GitWorkingTreeState.ready);
      expect(snapshot.branch, 'main');
      expect(snapshot.truncated, isFalse);
      expect(
        File(snapshot.repositoryRoot!).resolveSymbolicLinksSync(),
        repo.resolveSymbolicLinksSync(),
      );
      expect(
        [
          for (final file in snapshot.files)
            '${file.group.name}:${file.kind.name}:${file.path}',
        ],
        [
          'staged:renamed:renamed.txt',
          'staged:added:st.txt',
          'unstaged:modified:[a]*.txt',
          'unstaged:modified:a.txt',
          'unstaged:modified:f1.txt',
          'unstaged:deleted:gone.txt',
          'unstaged:modified:st.txt',
          'untracked:untracked:bin.dat',
          'untracked:untracked:d/new.md',
          'untracked:untracked:untracked.txt',
          'untracked:untracked:ünï.txt',
        ],
      );
      expect(
        _file(snapshot, GitChangeGroup.staged, 'renamed.txt').originalPath,
        'sp ace.txt',
      );
      expect(
        _file(snapshot, GitChangeGroup.staged, 'renamed.txt').counts,
        const GitLineCounts(added: 0, removed: 0),
      );
      expect(
        _file(snapshot, GitChangeGroup.staged, 'st.txt').counts,
        const GitLineCounts(added: 1, removed: 0),
      );
      expect(
        _file(snapshot, GitChangeGroup.unstaged, 'st.txt').counts,
        const GitLineCounts(added: 1, removed: 0),
      );
      expect(
        _file(snapshot, GitChangeGroup.unstaged, 'f1.txt').counts,
        const GitLineCounts(added: 2, removed: 1),
      );
      expect(
        _file(snapshot, GitChangeGroup.unstaged, 'gone.txt').counts,
        const GitLineCounts(added: 0, removed: 1),
      );

      final untracked = snapshot.filesIn(GitChangeGroup.untracked);
      final counts = await service.loadUntrackedCounts(
        snapshot.repositoryRoot!,
        [for (final file in untracked) file.path],
      );
      expect(
        counts['untracked.txt'],
        const GitLineCounts(added: 2, removed: 0),
      );
      expect(counts['d/new.md'], const GitLineCounts(added: 1, removed: 0));
      expect(counts['ünï.txt'], const GitLineCounts(added: 1, removed: 0));
      expect(counts['bin.dat'], const GitLineCounts.binary());
    });

    test('never writes the index while reading', () async {
      final index = File('${repo.path}/.git/index');
      // Touching a tracked file leaves stale stat data that a plain
      // `git status` would refresh by rewriting the index.
      File('${repo.path}/renamed.txt')
          .setLastModifiedSync(DateTime.now().add(const Duration(minutes: 1)));
      final before = index.readAsBytesSync();
      final beforeModified = index.lastModifiedSync();

      final snapshot = await service.loadStatus(repo.path);
      for (final file in snapshot.files) {
        await service.loadDiff(snapshot.repositoryRoot!, file);
      }

      expect(index.readAsBytesSync(), before);
      expect(index.lastModifiedSync(), beforeModified);
      expect(File('${repo.path}/.git/index.lock').existsSync(), isFalse);
    });

    test('loads per-file diffs for each kind of change', () async {
      final snapshot = await service.loadStatus(repo.path);
      final root = snapshot.repositoryRoot!;

      final modified = await service.loadDiff(
        root,
        _file(snapshot, GitChangeGroup.unstaged, 'f1.txt'),
      );
      expect(modified.failed, isFalse);
      expect(modified.hunks.single.lines, [' a', '-b', '+B', ' c', '+d']);

      final renamed = await service.loadDiff(
        root,
        _file(snapshot, GitChangeGroup.staged, 'renamed.txt'),
      );
      expect(renamed.hunks, isEmpty);
      expect(renamed.headerLines, contains('rename from sp ace.txt'));
      expect(renamed.headerLines, contains('rename to renamed.txt'));

      final untracked = await service.loadDiff(
        root,
        _file(snapshot, GitChangeGroup.untracked, 'untracked.txt'),
      );
      expect(untracked.failed, isFalse);
      expect(untracked.hunks.single.lines, [
        '+u1',
        '+u2',
        r'\ No newline at end of file',
      ]);

      final binary = await service.loadDiff(
        root,
        _file(snapshot, GitChangeGroup.untracked, 'bin.dat'),
      );
      expect(binary.binary, isTrue);

      // A glob-like name must not also match `a.txt`.
      final glob = await service.loadDiff(
        root,
        _file(snapshot, GitChangeGroup.unstaged, '[a]*.txt'),
      );
      expect(glob.headerLines.first, contains('[a]*.txt'));
      expect(
        glob.headerLines.where((l) => l.startsWith('diff ')),
        hasLength(1),
      );
      expect(glob.hunks.single.lines, contains('+changed'));
    });

    test('an untracked file that vanished fails its diff', () async {
      final snapshot = await service.loadStatus(repo.path);
      final file = _file(snapshot, GitChangeGroup.untracked, 'untracked.txt');
      File('${repo.path}/untracked.txt').deleteSync();

      final diff = await service.loadDiff(snapshot.repositoryRoot!, file);
      expect(diff.failed, isTrue);

      // An empty untracked file also exits 1, but with a diff header.
      _write(repo, 'empty.txt', '');
      final empty = await service.loadDiff(
        snapshot.repositoryRoot!,
        const GitChangedFile(
          path: 'empty.txt',
          group: GitChangeGroup.untracked,
          kind: GitChangeKind.untracked,
        ),
      );
      expect(empty.failed, isFalse);
      expect(empty.hunks, isEmpty);
      expect(empty.headerLines, contains('new file mode 100644'));
    });

    test('reports conflicts with their porcelain code', () async {
      await _git(repo, ['add', '-A']);
      await _git(repo, ['commit', '-qm', 'base']);
      await _git(repo, ['checkout', '-qb', 'other']);
      _write(repo, 'f1.txt', 'theirs\n');
      await _git(repo, ['commit', '-qam', 'other']);
      await _git(repo, ['checkout', '-q', 'main']);
      _write(repo, 'f1.txt', 'ours\n');
      await _git(repo, ['commit', '-qam', 'ours']);
      await Process.run(
        'git',
        ['-c', 'user.email=t@e', '-c', 'user.name=T', 'merge', 'other'],
        workingDirectory: repo.path,
        environment: {
          'GIT_CONFIG_GLOBAL': '/dev/null',
          'GIT_CONFIG_NOSYSTEM': '1',
        },
      );

      final snapshot = await service.loadStatus(repo.path);
      final conflict = _file(snapshot, GitChangeGroup.conflicted, 'f1.txt');
      expect(conflict.statusCode, 'UU');
      final diff = await service.loadDiff(snapshot.repositoryRoot!, conflict);
      expect(diff.failed, isFalse);
      expect(diff.hunks, isNotEmpty);
    });

    test('a clean tree is ready with no files', () async {
      final clean = Directory('${temp.path}/clean')..createSync();
      await _git(clean, ['init', '-q']);
      _write(clean, 'a', 'a\n');
      await _git(clean, ['add', '.']);
      await _git(clean, ['commit', '-qm', 'a']);
      final snapshot = await service.loadStatus(clean.path);
      expect(snapshot.state, GitWorkingTreeState.ready);
      expect(snapshot.files, isEmpty);
    });

    test('reports non-repositories and missing directories', () async {
      final plain = Directory('${temp.path}/plain')..createSync();
      expect(
        (await service.loadStatus(plain.path)).state,
        GitWorkingTreeState.notRepository,
      );
      expect(
        (await service.loadStatus('${temp.path}/missing')).state,
        GitWorkingTreeState.missingDirectory,
      );
    });

    test('expands a tilde directory through HOME', () async {
      final snapshot = await service.loadStatus('~/repo');
      expect(snapshot.state, GitWorkingTreeState.ready);
      expect(snapshot.files, isNotEmpty);
    });

    test('caps output and marks the result as truncated', () async {
      for (var i = 0; i < 50; i++) {
        _write(repo, 'many/file_$i.txt', 'x\n');
      }
      _write(repo, 'f1.txt', List.filled(5000, 'line').join('\n'));
      final capped = GitWorkingTreeService(
        _capped(_localRunner(home: temp.path), 1200),
        markerFactory: () => _marker,
      );
      final snapshot = await capped.loadStatus(repo.path);
      expect(snapshot.state, GitWorkingTreeState.ready);
      expect(snapshot.truncated, isTrue);
      expect(snapshot.files, isNotEmpty);

      final diff = await capped.loadDiff(
        snapshot.repositoryRoot!,
        const GitChangedFile(
          path: 'f1.txt',
          group: GitChangeGroup.unstaged,
          kind: GitChangeKind.modified,
        ),
      );
      expect(diff.truncated, isTrue);
      expect(diff.failed, isFalse);
      expect(diff.hunks, isNotEmpty);
    });

    test('never runs a configured fsmonitor hook', () async {
      final ran = File('${temp.path}/fsmonitor-ran');
      final hook = File('${temp.path}/fsmonitor-hook')
        ..writeAsStringSync('#!/bin/sh\ntouch "${ran.path}"\nexit 1\n');
      await Process.run('chmod', ['+x', hook.path]);
      await _git(repo, ['config', 'core.fsmonitor', hook.path]);

      final snapshot = await service.loadStatus(repo.path);
      await service.loadDiff(
        snapshot.repositoryRoot!,
        _file(snapshot, GitChangeGroup.unstaged, 'f1.txt'),
      );
      await service.loadDiff(
        snapshot.repositoryRoot!,
        _file(snapshot, GitChangeGroup.staged, 'st.txt'),
      );

      expect(snapshot.state, GitWorkingTreeState.ready);
      expect(ran.existsSync(), isFalse);
    });

    test('keeps the file list when line counts overflow the cap', () async {
      final big = Directory('${temp.path}/big')..createSync();
      await _git(big, ['init', '-q']);
      // Long names and both staged and unstaged edits make numstat larger
      // than status, so a cap between them drops only counts.
      final names = [for (var i = 0; i < 60; i++) '${'n' * 180}_$i.txt'];
      for (final name in names) {
        _write(big, name, 'a\n');
      }
      await _git(big, ['add', '.']);
      await _git(big, ['commit', '-qm', 'base']);
      for (final name in names) {
        _write(big, name, 'a\nb\n');
      }
      await _git(big, ['add', '.']);
      for (final name in names) {
        _write(big, name, 'a\nb\nc\n');
      }

      final runner = _localRunner(home: temp.path);
      final full = await runner(
        buildGitWorkingTreeStatusScript(big.path, marker: _marker),
        maxBytes: kGitStatusMaxBytes,
        timeout: const Duration(seconds: 20),
      );
      expect(full.truncated, isFalse);
      final capped = GitWorkingTreeService(
        _capped(runner, full.stdout.length ~/ 2),
        markerFactory: () => _marker,
      );

      final snapshot = await capped.loadStatus(big.path);

      expect(snapshot.state, GitWorkingTreeState.ready);
      expect(snapshot.truncated, isTrue);
      expect(snapshot.files, hasLength(names.length * 2));
      expect(snapshot.files.where((file) => file.counts == null), isNotEmpty);
    });

    test('recognises an untrusted repository in any locale', () async {
      final localized = GitWorkingTreeService(
        _localRunner(
          home: temp.path,
          environment: const {
            'GIT_TEST_ASSUME_DIFFERENT_OWNER': '1',
            'LANGUAGE': 'de',
            'LANG': 'de_DE.UTF-8',
            'LC_ALL': 'de_DE.UTF-8',
          },
        ),
        markerFactory: () => _marker,
      );
      expect(
        (await localized.loadStatus(repo.path)).state,
        GitWorkingTreeState.unsafeRepository,
      );
    });

    for (final loginShell in [
      '/bin/sh',
      '/bin/bash',
      '/bin/zsh',
      '/bin/dash',
      '/bin/csh',
      '/bin/tcsh',
      '/usr/bin/fish',
      '/usr/local/bin/fish',
      '/opt/homebrew/bin/fish',
    ]) {
      test(
        'hostile file names stay inert under a $loginShell login shell',
        () async {
          final hostileRepo = Directory('${temp.path}/hostile')..createSync();
          await _git(hostileRepo, ['init', '-q']);
          for (final name in _hostileNames) {
            _write(hostileRepo, name, 'one\ntwo\n');
          }
          final shellService = GitWorkingTreeService(
            _localRunner(
              home: temp.path,
              loginShell: loginShell,
              workingDirectory: temp.path,
            ),
            markerFactory: () => _marker,
          );

          final snapshot = await shellService.loadStatus(hostileRepo.path);
          expect(snapshot.state, GitWorkingTreeState.ready);
          expect(
            snapshot.files.map((file) => file.path).toSet(),
            _hostileNames.toSet(),
          );
          final counts = await shellService.loadUntrackedCounts(
            snapshot.repositoryRoot!,
            _hostileNames,
          );
          for (final name in _hostileNames) {
            expect(counts[name], const GitLineCounts(added: 2, removed: 0));
            final diff = await shellService.loadDiff(
              snapshot.repositoryRoot!,
              _file(snapshot, GitChangeGroup.untracked, name),
            );
            expect(diff.failed, isFalse);
            expect(diff.hunks.single.lines, ['+one', '+two']);
          }
          final canaries = [
            for (final dir in [temp, hostileRepo])
              ...dir
                  .listSync()
                  .map(
                    (entity) => entity.uri.pathSegments.lastWhere(
                      (segment) => segment.isNotEmpty,
                    ),
                  )
                  .where((name) => name.startsWith('CANARY')),
          ];
          expect(canaries, isEmpty);
        },
        skip: File(loginShell).existsSync()
            ? false
            : '$loginShell is not installed',
      );
    }
  }, skip: Platform.isWindows ? 'Needs /bin/sh and git' : false);
}

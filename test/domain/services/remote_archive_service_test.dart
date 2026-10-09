import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/services/remote_archive_service.dart';
import 'package:monkeyssh/domain/services/ssh_exec_queue.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

import '../../helpers/mock_ssh_exec_session.dart';

/// Directory tree standing in for the host, with just what extraction uses.
class _TreeSftp extends Fake implements SftpClient {
  _TreeSftp({Set<String>? directories, Set<String>? files})
    : directories = {'/', '/srv', ...?directories},
      files = {...?files};

  final Set<String> directories;
  final Set<String> files;

  /// Mode requested for each created or changed folder.
  final modes = <String, int>{};

  static Never _missing() =>
      // ignore: only_throw_errors, dartssh2 models protocol errors this way.
      throw SftpStatusError(SftpStatusCode.noSuchFile, 'No such file');

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async {
    if (directories.contains(path)) {
      return SftpFileAttrs(mode: const SftpFileMode.value(0x41ED));
    }
    if (files.contains(path)) {
      return SftpFileAttrs(mode: const SftpFileMode.value(0x81A4));
    }
    _missing();
  }

  @override
  Future<void> mkdir(String path, [SftpFileAttrs? attrs]) async {
    if (directories.contains(path) || files.contains(path)) {
      // ignore: only_throw_errors, dartssh2 models protocol errors this way.
      throw SftpStatusError(SftpStatusCode.failure, 'Failure');
    }
    directories.add(path);
    if (attrs?.mode case final mode?) modes[path] = mode.value;
  }

  @override
  Future<void> setStat(String path, SftpFileAttrs attrs) async {
    if (attrs.mode case final mode?) modes[path] = mode.value;
  }

  @override
  Future<List<SftpName>> listdir(String path) async {
    if (!directories.contains(path)) _missing();
    final prefix = '$path/';
    return [
      for (final entry in {...directories, ...files})
        if (entry.startsWith(prefix) &&
            !entry.substring(prefix.length).contains('/'))
          SftpName(
            filename: entry.substring(prefix.length),
            longname: entry,
            attr: await stat(entry),
          ),
    ];
  }

  @override
  Future<void> rename(String oldPath, String newPath) async {
    Iterable<String> moved(Set<String> set) =>
        set.where((p) => p == oldPath || p.startsWith('$oldPath/')).toList();
    final movedDirectories = moved(directories);
    final movedFiles = moved(files);
    if (movedDirectories.isEmpty && movedFiles.isEmpty) _missing();
    String target(String p) => newPath + p.substring(oldPath.length);
    for (final p in movedDirectories) {
      directories
        ..remove(p)
        ..add(target(p));
    }
    for (final p in movedFiles) {
      files
        ..remove(p)
        ..add(target(p));
    }
  }

  @override
  Future<void> remove(String filename) async {
    if (!files.remove(filename)) _missing();
  }

  @override
  Future<void> rmdir(String dirname) async {
    if ({...directories, ...files}.any((p) => p.startsWith('$dirname/'))) {
      // ignore: only_throw_errors, dartssh2 models protocol errors this way.
      throw SftpStatusError(SftpStatusCode.failure, 'Not empty');
    }
    directories.remove(dirname);
  }
}

/// Answers the extractor's commands and plays the archive's contents into
/// the scratch folder when asked to extract.
class _FakeHost {
  _FakeHost(
    this.sftp, {
    required this.names,
    required this.verbose,
    this.extracted = const [],
    this.hasTool = true,
    this.extractExitCode = 0,
  });

  final _TreeSftp sftp;
  final String names;
  final String verbose;

  /// Relative paths the extraction creates; a trailing `/` marks a folder.
  final List<String> extracted;
  final bool hasTool;
  final int extractExitCode;

  /// Each script's command line, without the shared PATH setup.
  final commands = <String>[];

  /// Whole scripts as sent to `/bin/sh` on stdin.
  final scripts = <String>[];

  Future<RemoteCommandResult> run(
    String script, {
    required Duration timeout,
    required int maxOutputBytes,
  }) async {
    scripts.add(script);
    final lines = script.split('\n');
    final command = lines[lines.indexOf('} </dev/null') - 1];
    commands.add(command);
    RemoteCommandResult output(String stdout) {
      final truncated = utf8.encode(stdout).length > maxOutputBytes;
      return RemoteCommandResult(
        exitCode: truncated ? null : 0,
        stdout: truncated ? stdout.substring(0, maxOutputBytes) : stdout,
        truncated: truncated,
      );
    }

    if (command.startsWith('command -v')) {
      return output(hasTool ? '' : 'MONKEYSSH_ARCHIVE_TOOL_MISSING\n');
    }
    if (command.startsWith('cp ')) {
      final words = _shellWords(command);
      if (!sftp.files.contains(words[1])) {
        return const RemoteCommandResult(exitCode: 1, stdout: '');
      }
      sftp.files.add(words[2]);
      return output('');
    }
    if (command.startsWith('unzip -Z1') ||
        command.startsWith('tar -t') && !command.startsWith('tar -tv')) {
      return output(names);
    }
    if (command.startsWith('unzip -Z') || command.startsWith('tar -tv')) {
      return output(verbose);
    }
    final target = _shellWords(command).last;
    for (final entry in extracted) {
      final path = '$target/${entry.replaceAll(RegExp(r'/$'), '')}';
      if (entry.endsWith('/')) {
        sftp.directories.add(path);
      } else {
        sftp.files.add(path);
      }
    }
    return RemoteCommandResult(exitCode: extractExitCode, stdout: '');
  }
}

/// Splits a POSIX command line built with single quotes and `'\''`.
List<String> _shellWords(String command) {
  final words = <String>[];
  final word = StringBuffer();
  var quoted = false;
  var inWord = false;
  for (var i = 0; i < command.length; i++) {
    final char = command[i];
    if (quoted) {
      if (char == "'") {
        quoted = false;
      } else {
        word.write(char);
      }
    } else if (char == "'") {
      quoted = true;
      inWord = true;
    } else if (char == r'\' && i + 1 < command.length) {
      word.write(command[++i]);
      inWord = true;
    } else if (char == ' ') {
      if (inWord) words.add(word.toString());
      word.clear();
      inWord = false;
    } else {
      word.write(char);
      inWord = true;
    }
  }
  if (inWord) words.add(word.toString());
  return words;
}

class _MockSshClient extends Mock implements SSHClient {
  @override
  Future<void> close() async {}
}

/// An exec channel whose stdout the test feeds and whose stdin it reads.
({
  MockSessionWithChannel exec,
  StreamController<Uint8List> stdout,
  List<int> stdin,
})
_execChannel() {
  final exec = MockSessionWithChannel();
  // The test closes stdout; the code under test closes stdin.
  // ignore: close_sinks
  final stdout = StreamController<Uint8List>();
  final stdin = <int>[];
  // ignore: close_sinks
  final stdinController = StreamController<Uint8List>()
    ..stream.listen(stdin.addAll);
  when(() => exec.stdout).thenAnswer((_) => stdout.stream);
  when(() => exec.stderr).thenAnswer((_) => const Stream.empty());
  when(() => exec.stdin).thenReturn(stdinController.sink);
  when(() => exec.done).thenAnswer((_) => stdout.done);
  when(() => exec.exitCode).thenReturn(0);
  when(exec.close).thenReturn(null);
  when(exec.channel.destroy).thenReturn(null);
  return (exec: exec, stdout: stdout, stdin: stdin);
}

const _zipVerboseHeader =
    'Archive:  /srv/project.zip\n'
    'Zip file size: 1234 bytes, number of entries: 2\n';

void main() {
  group('remoteArchiveKindForName', () {
    test('recognises zip and tar variants', () {
      expect(remoteArchiveKindForName('a.zip'), RemoteArchiveKind.zip);
      expect(remoteArchiveKindForName('A.ZIP'), RemoteArchiveKind.zip);
      expect(remoteArchiveKindForName('a.tar'), RemoteArchiveKind.tar);
      expect(remoteArchiveKindForName('a.tar.gz'), RemoteArchiveKind.tarGzip);
      expect(remoteArchiveKindForName('a.tgz'), RemoteArchiveKind.tarGzip);
      expect(remoteArchiveKindForName('a.tbz2'), RemoteArchiveKind.tarBzip2);
      expect(remoteArchiveKindForName('a.tar.xz'), RemoteArchiveKind.tarXz);
      expect(remoteArchiveKindForName('notes.gz'), isNull);
      expect(remoteArchiveKindForName('.zip'), isNull);
      expect(remoteArchiveKindForName('notes.txt'), isNull);
    });

    test('strips the suffix for the folder name', () {
      expect(
        remoteArchiveStem('build.tar.gz', RemoteArchiveKind.tarGzip),
        'build',
      );
      expect(remoteArchiveStem('Site.ZIP', RemoteArchiveKind.zip), 'Site');
    });
  });

  group('validateRemoteArchiveEntries', () {
    test('accepts plain files and folders', () {
      expect(
        validateRemoteArchiveEntries(
          names: ['src/', 'src/main.dart', './README.md'],
          types: ['d', '-', '-'],
        ),
        isNull,
      );
    });

    for (final name in [
      '/etc/passwd',
      '../escape.txt',
      'src/../../escape.txt',
      r'..\escape.txt',
      r'\windows\path',
      'C:/escape',
    ]) {
      test('refuses $name', () {
        expect(
          validateRemoteArchiveEntries(
            names: ['ok.txt', name],
            types: ['-', '-'],
          ),
          contains('outside this folder'),
        );
      });
    }

    test('accepts entries without type bits only for zip listings', () {
      expect(
        validateRemoteArchiveEntries(
          names: ['hello.txt'],
          types: ['?'],
          allowUntyped: true,
        ),
        isNull,
      );
      expect(
        validateRemoteArchiveEntries(names: ['hello.txt'], types: ['?']),
        contains('links or special files'),
      );
    });

    test('refuses links and special files', () {
      for (final type in ['l', 'h', 'c', 'b', 'p']) {
        expect(
          validateRemoteArchiveEntries(names: ['a', 'b'], types: ['-', type]),
          contains('links or special files'),
        );
      }
    });

    test('refuses a listing it cannot line up or an empty archive', () {
      expect(
        validateRemoteArchiveEntries(names: ['a', 'b'], types: ['-']),
        contains('could not be checked'),
      );
      expect(
        validateRemoteArchiveEntries(names: [], types: []),
        contains('empty'),
      );
    });
  });

  group('sshRemoteCommandRunner', () {
    tearDown(resetQueuedSshExecsForTesting);

    test('the login shell only ever sees the fixed command line', () async {
      final client = _MockSshClient();
      final channel = _execChannel();
      final commandLines = <String>[];
      when(() => client.execute(any(), pty: any(named: 'pty')))
          .thenAnswer((invocation) async {
            commandLines.add(invocation.positionalArguments.single as String);
            return channel.exec;
          });
      final session = SshSession(
        connectionId: 41,
        hostId: 1,
        client: client,
        config: const SshConnectionConfig(
          hostname: 'demo.example.com',
          port: 22,
          username: 'demo',
        ),
      );
      addTearDown(session.close);
      final script = remoteArchiveScript([
        r"unzip -Z1 '/srv/it'\''s; rm -rf ~.zip'",
      ]);

      final running = sshRemoteCommandRunner(session)(
        script,
        timeout: const Duration(seconds: 5),
        maxOutputBytes: 1024,
      );
      await pumpEventQueue();
      channel.stdout.add(Uint8List.fromList(utf8.encode('x.txt\n')));
      await channel.stdout.close();
      final result = await running;

      expect(commandLines, [kArchiveHostCommandLine]);
      expect(utf8.decode(channel.stdin), script);
      expect(result.stdout, 'x.txt\n');
      expect(result.exitCode, 0);
      expect(result.truncated, isFalse);
    });

    test('output past the limit stops the command', () async {
      final channel = _execChannel();

      final running = collectRemoteCommandOutput(
        channel.exec,
        script: remoteArchiveScript(['tar -tf x']),
        timeout: const Duration(seconds: 5),
        maxOutputBytes: 4,
      );
      channel.stdout.add(Uint8List.fromList(utf8.encode('abcdefgh')));
      final result = await running;

      expect(result.truncated, isTrue);
      expect(result.stdout, 'abcd');
      expect(result.exitCode, isNull);
      verify(channel.exec.channel.destroy).called(1);
      await channel.stdout.close();
    });
  });

  group('RemoteArchiveExtractor', () {
    test('moves a single top-level folder up beside the archive', () async {
      final sftp = _TreeSftp(files: {'/srv/project.tar.gz'});
      final host = _FakeHost(
        sftp,
        names: 'project/\nproject/main.dart\n',
        verbose:
            'drwxr-xr-x me/me 0 2026-10-01 12:00 project/\n'
            '-rw-r--r-- me/me 12 2026-10-01 12:00 project/main.dart\n',
        extracted: ['project/', 'project/main.dart'],
      );

      final result = await RemoteArchiveExtractor(runCommand: host.run)
          .extractHere(
            sftp: sftp,
            archivePath: '/srv/project.tar.gz',
            kind: RemoteArchiveKind.tarGzip,
          );

      expect(result.name, 'project');
      expect(result.isDirectory, isTrue);
      expect(sftp.files, contains('/srv/project/main.dart'));
      expect(
        sftp.directories.where((p) => p.contains('.monkeyssh-extract-')),
        isEmpty,
      );
      expect(
        host.commands.last,
        matches(
          RegExp(
            r"^tar -xzf '/srv/\.monkeyssh-extract-[0-9a-f]+/archive' -C "
            r"'/srv/\.monkeyssh-extract-[0-9a-f]+/out'$",
          ),
        ),
      );
    });

    test('keeps several entries together in a folder with a free name', () async {
      final sftp = _TreeSftp(
        directories: {'/srv/site'},
        files: {'/srv/site.zip'},
      );
      final host = _FakeHost(
        sftp,
        names: 'index.html\nstyle.css\n',
        verbose:
            '$_zipVerboseHeader'
            '-rw-r--r--  3.0 unx      120 tx defN 26-Oct-01 12:00 index.html\n'
            '-rw-r--r--  3.0 unx       80 tx defN 26-Oct-01 12:00 style.css\n'
            '2 files, 200 bytes uncompressed, 150 bytes compressed:  25.0%\n',
        extracted: ['index.html', 'style.css'],
      );

      final result = await RemoteArchiveExtractor(runCommand: host.run)
          .extractHere(
            sftp: sftp,
            archivePath: '/srv/site.zip',
            kind: RemoteArchiveKind.zip,
          );

      expect(result.name, 'site (2)');
      expect(sftp.files, containsAll(['/srv/site (2)/index.html']));
      expect(sftp.directories, contains('/srv/site'));
      expect(
        host.commands.last,
        matches(
          RegExp(
            r"^unzip -qq -o '/srv/\.monkeyssh-extract-[0-9a-f]+/archive' -d ",
          ),
        ),
      );
    });

    test('refuses traversal before extracting anything', () async {
      final sftp = _TreeSftp(files: {'/srv/evil.zip'});
      final host = _FakeHost(
        sftp,
        names: 'ok.txt\n../../home/me/.ssh/authorized_keys\n',
        verbose:
            '$_zipVerboseHeader'
            '-rw-r--r--  3.0 unx       10 tx defN 26-Oct-01 12:00 ok.txt\n'
            '-rw-r--r--  3.0 unx       10 tx defN 26-Oct-01 12:00 '
            '../../home/me/.ssh/authorized_keys\n',
      );

      await expectLater(
        RemoteArchiveExtractor(runCommand: host.run).extractHere(
          sftp: sftp,
          archivePath: '/srv/evil.zip',
          kind: RemoteArchiveKind.zip,
        ),
        throwsA(isA<RemoteArchiveException>()),
      );
      expect(host.commands.where((c) => c.startsWith('unzip -qq')), isEmpty);
      expect(sftp.directories, {'/', '/srv'});
    });

    test('refuses an archive holding a symlink', () async {
      final sftp = _TreeSftp(files: {'/srv/links.tar.gz'});
      final host = _FakeHost(
        sftp,
        names: 'escape\nescape/passwd\n',
        verbose:
            'lrwxrwxrwx me/me 0 2026-10-01 12:00 escape -> /etc\n'
            '-rw-r--r-- me/me 5 2026-10-01 12:00 escape/passwd\n',
      );

      await expectLater(
        RemoteArchiveExtractor(runCommand: host.run).extractHere(
          sftp: sftp,
          archivePath: '/srv/links.tar.gz',
          kind: RemoteArchiveKind.tarGzip,
        ),
        throwsA(
          isA<RemoteArchiveException>().having(
            (error) => error.message,
            'message',
            contains('links'),
          ),
        ),
      );
      expect(host.commands.where((c) => c.startsWith('tar -xzf')), isEmpty);
    });

    test('reports a missing tool', () async {
      final sftp = _TreeSftp(files: {'/srv/a.zip'});
      final host = _FakeHost(sftp, names: '', verbose: '', hasTool: false);

      await expectLater(
        RemoteArchiveExtractor(runCommand: host.run).extractHere(
          sftp: sftp,
          archivePath: '/srv/a.zip',
          kind: RemoteArchiveKind.zip,
        ),
        throwsA(
          isA<RemoteArchiveException>().having(
            (error) => error.message,
            'message',
            'unzip is not installed on this host.',
          ),
        ),
      );
      expect(host.commands, hasLength(1));
    });

    test('extracts zip entries that carry no Unix type bits', () async {
      // Python's ZipFile.writestr leaves the type bits out; unzip -Z shows
      // `?` and extracts a plain file.
      final sftp = _TreeSftp(files: {'/srv/py.zip'});
      final host = _FakeHost(
        sftp,
        names: 'hello.txt\n',
        verbose:
            '$_zipVerboseHeader'
            '?rw-------  2.0 unx        5 b- stor 26-Oct-01 12:00 hello.txt\n',
        extracted: ['hello.txt'],
      );

      final result = await RemoteArchiveExtractor(runCommand: host.run)
          .extractHere(
            sftp: sftp,
            archivePath: '/srv/py.zip',
            kind: RemoteArchiveKind.zip,
          );

      expect(result.name, 'hello.txt');
      expect(sftp.files, contains('/srv/hello.txt'));
    });

    test('lists and extracts a private copy, never the original', () async {
      final sftp = _TreeSftp(files: {"/srv/it's a.zip"});
      final host = _FakeHost(
        sftp,
        names: 'x.txt\n',
        verbose:
            '$_zipVerboseHeader'
            '-rw-r--r--  3.0 unx        5 tx defN 26-Oct-01 12:00 x.txt\n',
        extracted: ['x.txt'],
      );

      await RemoteArchiveExtractor(runCommand: host.run).extractHere(
        sftp: sftp,
        archivePath: "/srv/it's a.zip",
        kind: RemoteArchiveKind.zip,
      );

      final scratch = sftp.modes.keys.singleWhere(
        (path) => path.contains('.monkeyssh-extract-'),
      );
      expect(sftp.modes[scratch], 0x1C0);
      expect(host.commands[1], startsWith('cp '));
      for (final command in host.commands.skip(2)) {
        expect(command, isNot(contains('a.zip')));
        expect(command, contains('$scratch/archive'));
      }
      expect(sftp.files, isNot(contains('$scratch/archive')));
    });

    test('every script starts from the login PATH', () async {
      final sftp = _TreeSftp(files: {'/srv/a.zip'});
      final host = _FakeHost(
        sftp,
        names: 'x.txt\n',
        verbose:
            '$_zipVerboseHeader'
            '-rw-r--r--  3.0 unx        5 tx defN 26-Oct-01 12:00 x.txt\n',
        extracted: ['x.txt'],
      );

      await RemoteArchiveExtractor(runCommand: host.run).extractHere(
        sftp: sftp,
        archivePath: '/srv/a.zip',
        kind: RemoteArchiveKind.zip,
      );

      expect(host.scripts, isNotEmpty);
      for (final script in host.scripts) {
        expect(script, startsWith('{\n'));
        expect(script, contains('. ~/.profile'));
        expect(script, endsWith('} </dev/null\n'));
      }
    });

    test('refuses listings past the entry or byte limit', () async {
      for (final count in [remoteArchiveMaxEntries + 1, 600000]) {
        final sftp = _TreeSftp(files: {'/srv/big.tar.gz'});
        final names = List.generate(count, (i) => 'file-$i').join('\n');
        final verbose = List.generate(
          count,
          (i) => '-rw-r--r-- me/me 1 2026-10-01 12:00 file-$i',
        ).join('\n');
        final host = _FakeHost(
          sftp,
          names: names,
          verbose: verbose,
          extracted: ['file-0'],
        );

        await expectLater(
          RemoteArchiveExtractor(runCommand: host.run).extractHere(
            sftp: sftp,
            archivePath: '/srv/big.tar.gz',
            kind: RemoteArchiveKind.tarGzip,
          ),
          throwsA(
            isA<RemoteArchiveException>().having(
              (error) => error.message,
              'message',
              contains('too many entries'),
            ),
          ),
        );
        expect(host.commands.where((c) => c.startsWith('tar -x')), isEmpty);
        expect(sftp.directories, {'/', '/srv'});
      }
    });

    test(
      'a single top-level entry whose name is taken gets a free one',
      () async {
        final sftp = _TreeSftp(
          directories: {'/srv/project'},
          files: {'/srv/project.tar.gz', '/srv/notes.txt', '/srv/notes.tgz'},
        );
        final folder = _FakeHost(
          sftp,
          names: 'project/\nproject/main.dart\n',
          verbose:
              'drwxr-xr-x me/me 0 2026-10-01 12:00 project/\n'
              '-rw-r--r-- me/me 12 2026-10-01 12:00 project/main.dart\n',
          extracted: ['project/', 'project/main.dart'],
        );

        final result = await RemoteArchiveExtractor(runCommand: folder.run)
            .extractHere(
              sftp: sftp,
              archivePath: '/srv/project.tar.gz',
              kind: RemoteArchiveKind.tarGzip,
            );

        expect(result.name, 'project (2)');
        expect(sftp.files, contains('/srv/project (2)/main.dart'));

        final file = _FakeHost(
          sftp,
          names: 'notes.txt\n',
          verbose: '-rw-r--r-- me/me 5 2026-10-01 12:00 notes.txt\n',
          extracted: ['notes.txt'],
        );
        final single = await RemoteArchiveExtractor(runCommand: file.run)
            .extractHere(
              sftp: sftp,
              archivePath: '/srv/notes.tgz',
              kind: RemoteArchiveKind.tarGzip,
            );
        expect(single.name, 'notes (2).txt');
      },
    );

    test('removes the partial folder when extraction fails', () async {
      final sftp = _TreeSftp(files: {'/srv/broken.tar.gz'});
      final host = _FakeHost(
        sftp,
        names: 'a/\na/b.txt\n',
        verbose:
            'drwxr-xr-x me/me 0 2026-10-01 12:00 a/\n'
            '-rw-r--r-- me/me 5 2026-10-01 12:00 a/b.txt\n',
        extracted: ['a/', 'a/b.txt'],
        extractExitCode: 2,
      );

      await expectLater(
        RemoteArchiveExtractor(runCommand: host.run).extractHere(
          sftp: sftp,
          archivePath: '/srv/broken.tar.gz',
          kind: RemoteArchiveKind.tarGzip,
        ),
        throwsA(isA<RemoteArchiveException>()),
      );
      expect(sftp.directories, {'/', '/srv'});
      expect(sftp.files, {'/srv/broken.tar.gz'});
    });
  });
}

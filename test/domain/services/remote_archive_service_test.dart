import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/remote_archive_service.dart';

/// Directory tree standing in for the host, with just what extraction uses.
class _TreeSftp extends Fake implements SftpClient {
  _TreeSftp({Set<String>? directories, Set<String>? files})
    : directories = {'/', '/srv', ...?directories},
      files = {...?files};

  final Set<String> directories;
  final Set<String> files;

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
  final commands = <String>[];

  Future<RemoteCommandResult> run(
    String command, {
    required Duration timeout,
  }) async {
    commands.add(command);
    if (command.startsWith('command -v')) {
      return RemoteCommandResult(
        exitCode: 0,
        stdout: hasTool ? '' : 'MONKEYSSH_ARCHIVE_TOOL_MISSING\n',
      );
    }
    if (command.startsWith('unzip -Z1') || command.startsWith('tar -tz')) {
      return RemoteCommandResult(exitCode: 0, stdout: names);
    }
    if (command.startsWith('unzip -Z') || command.startsWith('tar -tv')) {
      return RemoteCommandResult(exitCode: 0, stdout: verbose);
    }
    final scratch = RegExp(r"(?:-d|-C) '([^']+)'$")
        .firstMatch(command)!
        .group(1)!;
    for (final entry in extracted) {
      final path = '$scratch/${entry.replaceAll(RegExp(r'/$'), '')}';
      if (entry.endsWith('/')) {
        sftp.directories.add(path);
      } else {
        sftp.files.add(path);
      }
    }
    return RemoteCommandResult(exitCode: extractExitCode, stdout: '');
  }
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
        startsWith("tar -xzf '/srv/project.tar.gz' -C"),
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
      expect(host.commands.last, startsWith("unzip -qq -o '/srv/site.zip' -d"));
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

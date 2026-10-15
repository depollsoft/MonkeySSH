// Runs the extractor's scripts in a real `/bin/sh` against a temporary
// folder standing in for the host, so the shell-side checks are exercised
// with real tar and unzip. HOME points at a temporary folder too, so no real
// startup file is read.
@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/agent_management_service.dart';
import 'package:monkeyssh/domain/services/remote_archive_service.dart';

bool _has(String tool) =>
    Process.runSync('/bin/sh', ['-c', 'command -v $tool']).exitCode == 0;

/// A host made of local folders: [root] holds the archives and [home] is the
/// fake home folder the scripts see.
class _LocalHost {
  _LocalHost()
    : root = Directory.systemTemp.createTempSync('archive-host-'),
      home = Directory.systemTemp.createTempSync('archive-home-');

  final Directory root;
  final Directory home;

  /// Runs before each script; may change the folder to play an attacker.
  void Function(String script)? beforeScript;

  /// Replaces a script's output, to play a listing that hides a link.
  RemoteCommandResult? Function(String script)? fakeResult;

  /// Extra environment for every script, as a login shell might export.
  Map<String, String> environment = const {};

  void dispose() {
    for (final directory in [root, home]) {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    }
  }

  Future<RemoteCommandResult> run(
    String script, {
    required Duration timeout,
    required int maxOutputBytes,
  }) async {
    beforeScript?.call(script);
    if (fakeResult?.call(script) case final result?) return result;
    final process = await Process.start(
      '/bin/sh',
      ['-s'],
      environment: {
        'HOME': home.path,
        'PATH': '/usr/bin:/bin',
        'SHELL': '/bin/sh',
        'LC_ALL': 'C',
        ...environment,
      },
      includeParentEnvironment: false,
    );
    process.stdin.write(script);
    await process.stdin.close();
    final stderr = process.stderr.drain<void>();
    final stdout = await process.stdout.fold<BytesBuilder>(
      BytesBuilder(),
      (builder, chunk) => builder..add(chunk),
    );
    await stderr;
    final exitCode = await process.exitCode.timeout(timeout);
    return RemoteCommandResult(
      exitCode: exitCode,
      stdout: utf8.decode(stdout.takeBytes(), allowMalformed: true),
    );
  }
}

/// SFTP answered from the local file system, never following links.
class _LocalSftp extends Fake implements SftpClient {
  SftpFileAttrs _attrs(String path) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    final mode = switch (type) {
      FileSystemEntityType.directory => 0x41ED,
      FileSystemEntityType.file => 0x81A4,
      FileSystemEntityType.link => 0xA1FF,
      _ =>
        // ignore: only_throw_errors, dartssh2 models protocol errors this way.
        throw SftpStatusError(SftpStatusCode.noSuchFile, 'No such file'),
    };
    return SftpFileAttrs(mode: SftpFileMode.value(mode));
  }

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async =>
      _attrs(path);

  @override
  Future<List<SftpName>> listdir(String path) async => [
    for (final entity in Directory(path).listSync(followLinks: false))
      SftpName(
        filename: entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
        longname: entity.path,
        attr: _attrs(entity.path),
      ),
  ];

  @override
  Future<void> mkdir(String path, [SftpFileAttrs? attrs]) async {
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      // ignore: only_throw_errors, dartssh2 models protocol errors this way.
      throw SftpStatusError(SftpStatusCode.failure, 'Failure');
    }
    Directory(path).createSync();
  }

  @override
  Future<void> setStat(String path, SftpFileAttrs attrs) async {}

  @override
  Future<void> rename(String oldPath, String newPath) async {
    final type = FileSystemEntity.typeSync(oldPath, followLinks: false);
    if (type == FileSystemEntityType.link) {
      Link(oldPath).renameSync(newPath);
    } else if (type == FileSystemEntityType.directory) {
      Directory(oldPath).renameSync(newPath);
    } else {
      File(oldPath).renameSync(newPath);
    }
  }

  @override
  Future<void> remove(String filename) async => File(filename).deleteSync();

  @override
  Future<void> rmdir(String dirname) async => Directory(dirname).deleteSync();
}

void _run(String command, {required String inDirectory}) {
  final result = Process.runSync('/bin/sh', [
    '-c',
    command,
  ], workingDirectory: inDirectory);
  if (result.exitCode != 0) {
    fail('$command failed: ${result.stderr}');
  }
}

void main() {
  final hasTools = _has('tar') && _has('find');
  late _LocalHost host;
  late String root;

  setUp(() {
    host = _LocalHost();
    root = host.root.resolveSymbolicLinksSync();
  });

  tearDown(() => host.dispose());

  Future<RemoteArchiveExtraction> extract(
    String archive,
    RemoteArchiveKind kind, {
    Random? random,
  }) => RemoteArchiveExtractor(
    runCommand: host.run,
    random: random,
  ).extractHere(sftp: _LocalSftp(), archivePath: archive, kind: kind);

  test('extracts a real archive and moves its folder up', () async {
    Directory('$root/src/project').createSync(recursive: true);
    File('$root/src/project/main.dart').writeAsStringSync('void main() {}');
    _run('tar -czf ../project.tar.gz project', inDirectory: '$root/src');

    final result = await extract(
      '$root/project.tar.gz',
      RemoteArchiveKind.tarGzip,
    );

    expect(result.name, 'project');
    expect(
      File('$root/project/main.dart').readAsStringSync(),
      'void main() {}',
    );
    expect(
      host.root.listSync().map(
        (e) => e.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
      ),
      unorderedEquals(['src', 'project.tar.gz', 'project']),
    );
  }, skip: hasTools ? false : 'tar is not available');

  test('a link that the listing hid is refused after extraction', () async {
    Directory('$root/src').createSync();
    Directory('$root/outside').createSync();
    Link('$root/src/docs').createSync('../outside');
    _run('tar -cf ../links.tar docs', inDirectory: '$root/src');
    // Play a listing that shows the link as a plain file, as unzip -Z does
    // for a zip whose link mode sits in an extra field.
    host.fakeResult = (script) {
      if (!script.contains('tar -tf') && !script.contains('tar -tvf')) {
        return null;
      }
      final marker = RegExp("m='([^']+)'").firstMatch(script)!.group(1);
      final listing = script.contains('tar -tvf')
          ? '-rw-r--r-- me/me 0 2026-10-01 12:00 docs'
          : 'docs';
      return RemoteCommandResult(exitCode: 0, stdout: '$listing\n$marker 0\n');
    };

    await expectLater(
      extract('$root/links.tar', RemoteArchiveKind.tar),
      throwsA(
        isA<RemoteArchiveException>().having(
          (error) => error.message,
          'message',
          contains('links'),
        ),
      ),
    );
    expect(
      FileSystemEntity.typeSync('$root/docs', followLinks: false),
      FileSystemEntityType.notFound,
    );
    expect(
      Directory(root).listSync().where((e) => e.path.contains('.monkeyssh')),
      isEmpty,
    );
  }, skip: hasTools ? false : 'tar is not available');

  test(
    'a private folder swapped for a link is refused and the target kept',
    () async {
      Directory('$root/src/project').createSync(recursive: true);
      File('$root/src/project/a.txt').writeAsStringSync('a');
      _run('tar -czf ../project.tar.gz project', inDirectory: '$root/src');
      final victim = Directory('${host.home.path}/victim')..createSync();
      File('${victim.path}/keep.txt').writeAsStringSync('precious');
      var swapped = false;
      host.beforeScript = (script) {
        if (swapped || script.contains('command -v')) return;
        final scratch = Directory(root)
            .listSync()
            .whereType<Directory>()
            .singleWhere((e) => e.path.contains('.monkeyssh-extract-'));
        // A co-user renames the folder away and leaves a link in its place.
        final name = scratch.path;
        scratch.renameSync('$root/stolen');
        Link(name).createSync(victim.path);
        swapped = true;
      };

      await expectLater(
        extract('$root/project.tar.gz', RemoteArchiveKind.tarGzip),
        throwsA(isA<RemoteArchiveException>()),
      );
      expect(swapped, isTrue);
      expect(victim.listSync().map((e) => e.path), ['${victim.path}/keep.txt']);
      expect(File('${victim.path}/keep.txt').readAsStringSync(), 'precious');
      expect(
        FileSystemEntity.typeSync('$root/project', followLinks: false),
        FileSystemEntityType.notFound,
      );
    },
    skip: hasTools ? false : 'tar is not available',
  );

  test('a link planted at the private folder name is left alone', () async {
    Directory('$root/src/project').createSync(recursive: true);
    File('$root/src/project/a.txt').writeAsStringSync('a');
    _run('tar -czf ../project.tar.gz project', inDirectory: '$root/src');
    final victim = Directory('${host.home.path}/victim')..createSync();
    final predict = Random(7);
    String hex() => predict.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    hex();
    hex();
    final planted = Link('$root/.monkeyssh-extract-${hex()}')
      ..createSync(victim.path);

    await expectLater(
      extract(
        '$root/project.tar.gz',
        RemoteArchiveKind.tarGzip,
        random: Random(7),
      ),
      throwsA(isA<RemoteArchiveException>()),
    );
    expect(planted.targetSync(), victim.path);
    expect(victim.listSync(), isEmpty);
  }, skip: hasTools ? false : 'tar is not available');

  test(
    'a folder find cannot read is refused rather than trusted',
    () async {
      // The archive carries a mode 000 folder holding a link. tar restores the
      // folder's mode last, so the link lands inside, and `find` then cannot
      // enter the folder: it reports an error and lists nothing. The pipeline
      // used to report only `head`'s status, which promoted the tree.
      Directory('$root/outside').createSync();
      const buildArchive =
          'import sys, tarfile\n'
          'with tarfile.open(sys.argv[1], "w") as tar:\n'
          '    folder = tarfile.TarInfo("docs")\n'
          '    folder.type = tarfile.DIRTYPE\n'
          '    folder.mode = 0\n'
          '    tar.addfile(folder)\n'
          '    link = tarfile.TarInfo("docs/link")\n'
          '    link.type = tarfile.SYMTYPE\n'
          '    link.linkname = "../../outside"\n'
          '    tar.addfile(link)\n';
      final build = Process.runSync('python3', [
        '-I',
        '-c',
        buildArchive,
        '$root/locked.tar',
      ]);
      expect(build.exitCode, 0, reason: '${build.stderr}');
      // Play a listing that shows only a plain file, as the hidden-link test
      // does, so the shell-side check after extraction is what decides.
      host.fakeResult = (script) {
        if (!script.contains('tar -tf') && !script.contains('tar -tvf')) {
          return null;
        }
        final marker = RegExp("m='([^']+)'").firstMatch(script)!.group(1);
        final listing = script.contains('tar -tvf')
            ? '-rw-r--r-- me/me 0 2026-10-01 12:00 docs'
            : 'docs';
        return RemoteCommandResult(
          exitCode: 0,
          stdout: '$listing\n$marker 0\n',
        );
      };

      try {
        await expectLater(
          extract('$root/locked.tar', RemoteArchiveKind.tar),
          throwsA(
            isA<RemoteArchiveException>().having(
              (error) => error.message,
              'message',
              contains('could not be checked'),
            ),
          ),
        );
        expect(
          FileSystemEntity.typeSync('$root/docs', followLinks: false),
          FileSystemEntityType.notFound,
        );
        // Cleanup opens the unreadable folder up before `rm -rf`.
        expect(
          Directory(root)
              .listSync()
              .where((e) => e.path.contains('.monkeyssh-extract-')),
          isEmpty,
        );
      } finally {
        // Keeps tearDown working if cleanup regresses.
        Process.runSync('chmod', ['-R', 'u+rwx', root]);
      }
    },
    skip: hasTools && _has('python3') && !_isRoot
        ? false
        : 'needs tar, python3 and a non-root user',
  );

  test('an exported CDPATH does not break the private folder checks', () async {
    Directory('$root/src/project').createSync(recursive: true);
    File('$root/src/project/main.dart').writeAsStringSync('void main() {}');
    _run('tar -czf ../project.tar.gz project', inDirectory: '$root/src');
    // With CDPATH set, POSIX `cd` prints the folder it changed to.
    host.environment = {'CDPATH': '.:${host.home.path}'};

    final result = await extract(
      '$root/project.tar.gz',
      RemoteArchiveKind.tarGzip,
    );

    expect(result.name, 'project');
    expect(File('$root/project/main.dart').existsSync(), isTrue);
  }, skip: hasTools ? false : 'tar is not available');

  test(
    'a first step whose reply is lost leaves no private folder behind',
    () async {
      Directory('$root/src/project').createSync(recursive: true);
      File('$root/src/project/a.txt').writeAsStringSync('a');
      _run('tar -czf ../project.tar.gz project', inDirectory: '$root/src');
      var lost = false;
      final extractor = RemoteArchiveExtractor(
        runCommand:
            (script, {required timeout, required maxOutputBytes}) async {
              final result = await host.run(
                script,
                timeout: timeout,
                maxOutputBytes: maxOutputBytes,
              );
              if (!lost && script.contains('cat -- ')) {
                // The copy finished on the host, but the reply never came.
                lost = true;
                throw TimeoutException('No reply', timeout);
              }
              return result;
            },
      );

      await expectLater(
        extractor.extractHere(
          sftp: _LocalSftp(),
          archivePath: '$root/project.tar.gz',
          kind: RemoteArchiveKind.tarGzip,
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(lost, isTrue);
      expect(
        Directory(root)
            .listSync()
            .map((e) => e.uri.pathSegments.lastWhere((s) => s != '')),
        unorderedEquals(['src', 'project.tar.gz']),
      );
    },
    skip: hasTools ? false : 'tar is not available',
  );

  test('the login PATH survives missing and broken startup files', () {
    final home = host.home.path;
    Directory('$home/profile-bin').createSync();
    Directory('$home/zprofile-bin').createSync();
    File('$home/.profile')
        .writeAsStringSync('PATH="\$HOME/profile-bin:\$PATH"\n');
    File('$home/.zprofile')
        .writeAsStringSync('PATH="\$HOME/zprofile-bin:\$PATH"\n');
    // A zsh-only file with a syntax error for /bin/sh, while .bash_profile
    // does not exist.
    File('$home/.zshrc').writeAsStringSync('if then fi\n');

    final result = Process.runSync(
      '/bin/sh',
      ['-c', '${remoteProfilePathPrefix}printf %s "\$PATH"'],
      environment: {'HOME': home, 'PATH': '/usr/bin:/bin', 'SHELL': '/bin/zsh'},
      includeParentEnvironment: false,
    );

    expect(result.exitCode, 0);
    final entries = (result.stdout as String).split(':');
    // Each file's result already holds the earlier entries, so a file adds
    // its own entry once instead of doubling the whole PATH.
    expect(entries.where((e) => e == '$home/profile-bin'), hasLength(1));
    expect(entries.where((e) => e == '$home/zprofile-bin'), hasLength(1));
    expect(
      entries.indexOf('$home/zprofile-bin'),
      lessThan(entries.indexOf('$home/profile-bin')),
    );
  });
}

final bool _isRoot =
    Process.runSync('id', ['-u']).stdout.toString().trim() == '0';

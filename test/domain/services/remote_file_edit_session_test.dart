import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/remote_file_edit_session.dart';
import 'package:monkeyssh/domain/services/remote_file_service.dart';

import '../../helpers/in_memory_sftp.dart';

const _path = '/home/demo/notes.txt';

Uint8List _bytes(String text) => utf8.encode(text);

String _text(InMemorySftpClient server, String path) =>
    utf8.decode(server.files[path]!);

Future<RemoteFileEditSession> _openSession(
  InMemorySftpClient server, {
  String path = _path,
}) async {
  final session = RemoteFileEditSession(remotePath: path);
  session.accept(await session.read(server, maxBytes: 1024 * 1024 + 1));
  return session;
}

void main() {
  group('RemoteFileEditSession', () {
    late InMemorySftpClient server;

    setUp(() {
      server = InMemorySftpClient()..writeFile(_path, _bytes('original\n'));
    });

    test('an untouched file is unchanged', () async {
      final session = await _openSession(server);

      expect(await session.checkForChanges(server), RemoteFileChange.unchanged);
    });

    test('a later edit with a new size or time is a change', () async {
      final session = await _openSession(server);
      server.writeFile(_path, _bytes('agent rewrote this\n'));
      expect(await session.checkForChanges(server), RemoteFileChange.modified);

      final sameSize = await _openSession(server);
      server.writeFile(_path, _bytes('agent rewrote THIS\n'), modifyTime: 1);
      expect(await sameSize.checkForChanges(server), RemoteFileChange.modified);
    });

    test(
      'a same-second, same-size edit is caught by the content hash',
      () async {
        final session = await _openSession(server);
        // SFTP v3 times have one-second resolution, so only content differs.
        server.writeFile(_path, _bytes('ORIGINAL\n'));

        expect(
          await session.checkForChanges(server),
          RemoteFileChange.modified,
        );
      },
    );

    test('without size or time from the server, the hash decides', () async {
      server
        ..omitMetadata = true
        ..rejectFstat = true;
      final session = await _openSession(server);
      expect(await session.checkForChanges(server), RemoteFileChange.unchanged);

      server.writeFile(_path, _bytes('original\nplus a line\n'));
      expect(await session.checkForChanges(server), RemoteFileChange.modified);
    });

    test('large files trust size and time instead of re-reading', () async {
      final large = List.filled(remoteEditRehashMaxBytes + 1, 0x61);
      server.writeFile(_path, large);
      final session = await _openSession(server);
      final changed = List.of(large)..[0] = 0x62;
      server.writeFile(_path, changed);

      // Same size and same second: indistinguishable without a download.
      expect(await session.checkForChanges(server), RemoteFileChange.unchanged);
      server.writeFile(_path, changed, modifyTime: server.now + 1);
      expect(await session.checkForChanges(server), RemoteFileChange.modified);
    });

    test('a removed file is reported as deleted', () async {
      final session = await _openSession(server);
      server.deleteFile(_path);

      expect(await session.checkForChanges(server), RemoteFileChange.deleted);
    });

    test('checking before a version was accepted is a bug', () async {
      final session = RemoteFileEditSession(remotePath: _path);

      expect(() => session.checkForChanges(server), throwsStateError);
    });

    test('a read that is not accepted leaves the baseline alone', () async {
      final session = await _openSession(server);
      server.writeFile(_path, _bytes('agent rewrote this\n'));
      await session.read(server, maxBytes: 1024);

      expect(await session.checkForChanges(server), RemoteFileChange.modified);
    });

    test('saving makes the saved bytes the new baseline', () async {
      final session = await _openSession(server);
      server.now += 30;
      await session.save(server, _bytes('edited on the phone\n'));

      expect(_text(server, _path), 'edited on the phone\n');
      expect(await session.checkForChanges(server), RemoteFileChange.unchanged);
      server.writeFile(_path, _bytes('EDITED ON THE PHONE\n'));
      expect(await session.checkForChanges(server), RemoteFileChange.modified);
    });

    test(
      'saving through a symlink keeps the link and tracks the target',
      () async {
        server
          ..writeFile('/srv/real.txt', _bytes('real\n'))
          ..directories.add('/srv')
          ..links['/home/demo/link.txt'] = '/srv/real.txt';
        final session = await _openSession(server, path: '/home/demo/link.txt');

        await session.save(server, _bytes('through the link\n'));

        expect(_text(server, '/srv/real.txt'), 'through the link\n');
        expect(server.links, {'/home/demo/link.txt': '/srv/real.txt'});
        expect(
          await session.checkForChanges(server),
          RemoteFileChange.unchanged,
        );
      },
    );

    group('saveCopy', () {
      test('writes beside the original without touching it', () async {
        final session = await _openSession(server);
        server.writeFile(_path, _bytes('agent version\n'));

        final copy = await session.saveCopy(server, _bytes('phone version\n'));

        expect(copy, '/home/demo/notes (copy).txt');
        expect(_text(server, copy), 'phone version\n');
        expect(_text(server, _path), 'agent version\n');
      });

      test(
        'stages content privately and never writes the shown name',
        () async {
          server.writeFile(_path, _bytes('secret\n'), mode: 0x180);
          final session = await _openSession(server);

          final copy = await session.saveCopy(server, _bytes('phone\n'));

          // The reserved name only ever holds an empty placeholder, so a reader
          // who opened it early never sees the content.
          expect(server.writes, isNot(contains(copy)));
          expect(server.writes, everyElement(contains('/.monkeyssh-save-')));
          expect(_text(server, copy), 'phone\n');
          expect(server.modes[copy], 0x180);
          expect(
            server.directories.where((d) => d.contains('.monkeyssh-save-')),
            isEmpty,
          );
        },
      );

      test('never replaces an existing file', () async {
        server
          ..writeFile('/home/demo/notes (copy).txt', _bytes('first copy\n'))
          ..writeFile('/home/demo/notes (copy 2).txt', _bytes('second\n'));
        final session = await _openSession(server);

        final copy = await session.saveCopy(server, _bytes('third\n'));

        expect(copy, '/home/demo/notes (copy 3).txt');
        expect(_text(server, '/home/demo/notes (copy).txt'), 'first copy\n');
        expect(_text(server, '/home/demo/notes (copy 2).txt'), 'second\n');
        expect(_text(server, copy), 'third\n');
      });

      test('keeps the original permissions, or owner-only when gone', () async {
        server.writeFile(_path, _bytes('secret\n'), mode: 0x180);
        final session = await _openSession(server);

        final private = await session.saveCopy(server, _bytes('a\n'));
        expect(server.modes[private], 0x180);

        server
          ..writeFile(_path, _bytes('script\n'), mode: 0x1ED)
          ..deleteFile('/home/demo/notes (copy).txt');
        final executable = await session.saveCopy(server, _bytes('b\n'));
        expect(server.modes[executable], 0x1ED);

        server.deleteFile(_path);
        final orphan = await session.saveCopy(server, _bytes('c\n'));
        expect(server.modes[orphan], 0x180);
        expect(server.files.containsKey(_path), isFalse);
      });

      test('removes a copy that could not be made private', () async {
        final session = await _openSession(server);
        server.setStatFailure = SftpStatusError(
          SftpStatusCode.permissionDenied,
          'no chmod',
        );

        await expectLater(
          session.saveCopy(server, _bytes('phone version\n')),
          throwsA(isA<SftpStatusError>()),
        );
        expect(server.files.keys, [_path]);
      });

      test('gives up when every copy name is taken', () async {
        for (var attempt = 1; attempt <= 100; attempt++) {
          server.writeFile(remoteFileCopyPath(_path, attempt), _bytes('x'));
        }
        final session = await _openSession(server);

        await expectLater(
          session.saveCopy(server, _bytes('phone version\n')),
          throwsA(isA<RemoteFileRefusedException>()),
        );
        expect(server.files, hasLength(101));
      });
    });
  });

  group('review round 1 regressions', () {
    late InMemorySftpClient server;

    setUp(() {
      server = InMemorySftpClient()
        ..writeFile(_path, _bytes('original\n'), mode: 0x180);
    });

    test('a rewrite with identical bytes is not a change', () async {
      final session = await _openSession(server);
      server.writeFile(
        _path,
        _bytes('original\n'),
        modifyTime: server.now + 10,
      );

      expect(await session.checkForChanges(server), RemoteFileChange.unchanged);
      expect(session.baseline!.modifyTime, server.now + 10);
    });

    test('a large identical rewrite is compared by content too', () async {
      final large = List.filled(remoteEditRehashMaxBytes + 10, 0x61);
      server.writeFile(_path, large);
      final session = await _openSession(server);
      server.writeFile(_path, large, modifyTime: server.now + 10);

      expect(await session.checkForChanges(server), RemoteFileChange.unchanged);
    });

    test('the content re-read skips the unused fstat', () async {
      final session = await _openSession(server);
      final before = server.fstatCount;

      await session.checkForChanges(server);

      expect(server.fstatCount, before);
    });

    test('a same-size change between fstat and read still saves', () async {
      server.afterFstat = (path) {
        server
          ..afterFstat = null
          ..writeFile(path, _bytes('ORIGINAL\n'), modifyTime: server.now + 1);
      };
      final session = await _openSession(server);

      // The editor shows the newer bytes, so they are the baseline content.
      expect(await session.checkForChanges(server), RemoteFileChange.unchanged);
    });

    test('a resized change between fstat and read reports a change', () async {
      server.afterFstat = (path) {
        server
          ..afterFstat = null
          ..writeFile(path, _bytes('longer text\n'), modifyTime: server.now);
      };
      final session = await _openSession(server);

      expect(await session.checkForChanges(server), RemoteFileChange.modified);
    });

    test('recreating a deleted file keeps the mode it loaded with', () async {
      for (final mode in [0x180, 0x1ED]) {
        server.writeFile(_path, _bytes('original\n'), mode: mode);
        final session = await _openSession(server);
        server.deleteFile(_path);
        expect(await session.checkForChanges(server), RemoteFileChange.deleted);

        await session.save(server, _bytes('phone\n'), force: true);

        expect(_text(server, _path), 'phone\n');
        expect(server.modes[_path], mode);
      }
    });

    test('recreating with an unknown mode is owner-only', () async {
      final session = RemoteFileEditSession(remotePath: _path)
        ..accept(
          RemoteFileSnapshot(_bytes('x'), RemoteFileVersion.of(const [1])),
        );
      server.deleteFile(_path);

      await session.save(server, _bytes('phone\n'), force: true);

      expect(server.modes[_path], 0x180);
    });

    test('a folder at the path is reported and never moved aside', () async {
      final session = await _openSession(server);
      server
        ..deleteFile(_path)
        ..directories.add(_path)
        ..writeFile('$_path/inner.txt', _bytes('x'));

      expect(await session.checkForChanges(server), RemoteFileChange.notAFile);
      await expectLater(
        session.save(server, _bytes('phone\n'), force: true),
        throwsA(isA<RemoteFileRefusedException>()),
      );
      expect(server.directories, contains(_path));
      expect(server.files.keys, contains('$_path/inner.txt'));
    });

    test(
      'a change between the check and the rename abandons the save',
      () async {
        final session = await _openSession(server);
        expect(
          await session.checkForChanges(server),
          RemoteFileChange.unchanged,
        );
        server.afterWrite = (path) {
          if (path == _path) return;
          server
            ..afterWrite = null
            ..writeFile(_path, _bytes('agent\n'), modifyTime: server.now + 3);
        };

        await expectLater(
          session.save(server, _bytes('phone\n')),
          throwsA(isA<RemoteFileChangedDuringSaveException>()),
        );
        expect(_text(server, _path), 'agent\n');
        expect(
          server.directories.where((d) => d.contains('.monkeyssh-save-')),
          isEmpty,
        );

        // An overwrite the user chose skips the comparison.
        await session.save(server, _bytes('phone\n'), force: true);
        expect(_text(server, _path), 'phone\n');
      },
    );
  });

  group('review round 2 regressions', () {
    const copy = '/home/demo/notes (copy).txt';
    late InMemorySftpClient server;

    setUp(() {
      server = InMemorySftpClient()
        ..writeFile(_path, _bytes('host version\n'), mode: 0x180);
    });

    test('a placeholder swapped for a link is refused, not followed', () async {
      final session = await _openSession(server);
      server.afterClose = (path) {
        if (path != copy) return;
        server
          ..afterClose = null
          ..deleteFile(copy)
          ..links[copy] = _path;
      };

      await expectLater(
        session.saveCopy(server, _bytes('phone\n')),
        throwsA(isA<RemoteFileRefusedException>()),
      );
      expect(_text(server, _path), 'host version\n');
      expect(server.links[copy], _path);
      expect(
        server.directories.where((d) => d.contains('.monkeyssh-save-')),
        isEmpty,
      );
    });

    test('the copy keeps its mode when stat leaves permissions out', () async {
      final session = await _openSession(server);
      server.omitMode = true;

      final saved = await session.saveCopy(server, _bytes('phone\n'));

      expect(server.modes[saved], 0x180);
      expect(server.modeAtFirstWrite.values, everyElement(0x180));
    });

    test('a host that refuses folders refuses the copy too', () async {
      final session = await _openSession(server);
      server.mkdirFailure = SftpStatusError(
        SftpStatusCode.permissionDenied,
        'no mkdir',
      );

      await expectLater(
        session.saveCopy(server, _bytes('phone\n')),
        throwsA(isA<SftpStatusError>()),
      );
      expect(server.writes, isNot(contains(copy)));
      expect(server.files.keys, [_path]);
    });

    test('a recreated file is restricted before content lands', () async {
      final session = await _openSession(server);
      server
        ..deleteFile(_path)
        ..mkdirFailure = SftpStatusError(
          SftpStatusCode.permissionDenied,
          'no mkdir',
        );

      await session.recreate(server, _bytes('phone\n'));

      expect(server.modeAtFirstWrite[_path], 0x180);
      expect(server.modes[_path], 0x180);
      expect(_text(server, _path), 'phone\n');
    });

    test(
      'a copy made after the path became a folder uses the loaded mode',
      () async {
        final session = await _openSession(server);
        server
          ..deleteFile(_path)
          ..directories.add(_path);

        final saved = await session.saveCopy(server, _bytes('phone\n'));

        expect(server.modes[saved], 0x180);
      },
    );

    test('recreate never replaces a file that came back', () async {
      final session = await _openSession(server);
      server.deleteFile(_path);
      expect(await session.checkForChanges(server), RemoteFileChange.deleted);
      server.writeFile(_path, _bytes('agent recreated\n'));

      await expectLater(
        session.recreate(server, _bytes('phone\n')),
        throwsA(isA<RemoteFileChangedDuringSaveException>()),
      );
      expect(_text(server, _path), 'agent recreated\n');

      // Coming back during the write is caught too.
      server.deleteFile(_path);
      server.afterWrite = (path) {
        if (path == _path) return;
        server
          ..afterWrite = null
          ..writeFile(_path, _bytes('agent again\n'));
      };
      await expectLater(
        session.recreate(server, _bytes('phone\n')),
        throwsA(isA<RemoteFileChangedDuringSaveException>()),
      );
      expect(_text(server, _path), 'agent again\n');
    });
  });

  group('remoteFileCopyPath', () {
    test('inserts the copy marker before the extension', () {
      expect(remoteFileCopyPath('/a/notes.txt', 1), '/a/notes (copy).txt');
      expect(remoteFileCopyPath('/a/notes.txt', 2), '/a/notes (copy 2).txt');
      expect(remoteFileCopyPath('/a/b.tar.gz', 1), '/a/b.tar (copy).gz');
      expect(remoteFileCopyPath('/a/Makefile', 1), '/a/Makefile (copy)');
      expect(remoteFileCopyPath('/a/.env', 1), '/a/.env (copy)');
      expect(remoteFileCopyPath('/a/trailing.', 1), '/a/trailing. (copy)');
      expect(
        remoteFileCopyPath('/C:/Users/x.ps1', 1),
        '/C:/Users/x (copy).ps1',
      );
    });

    test('keeps the name within 255 bytes', () {
      final name = '${'é' * 125}.md';
      final copy = remoteFileCopyPath('/a/$name', 12);
      final copyName = copy.substring('/a/'.length);

      expect(utf8.encode(copyName).length, lessThanOrEqualTo(255));
      expect(copyName, endsWith(' (copy 12).md'));
      expect(copyName, startsWith('éé'));
    });

    test('folds an extension too long to keep into the stem', () {
      final name = 'a.${'x' * 250}';
      final copy = remoteFileCopyPath('/a/$name', 1);
      final copyName = copy.substring('/a/'.length);

      expect(utf8.encode(copyName).length, lessThanOrEqualTo(255));
      expect(copyName, startsWith('a.xxx'));
      expect(copyName, endsWith(' (copy)'));
    });
  });
}

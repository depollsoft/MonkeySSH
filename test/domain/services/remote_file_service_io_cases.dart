import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/services/remote_file_service.dart';

import '../../helpers/mocks.dart';

class _MockSftpFile extends Mock implements SftpFile {}

class _MockLocalFile extends Mock implements File {}

class _MockRandomAccessFile extends Mock implements RandomAccessFile {}

/// In-memory SFTP server for [RemoteFileService.replaceFileBytes]. Without
/// [posixRename], rename refuses an existing destination like SFTP v3. Names
/// over 255 bytes fail, and with [ignoresMkdirMode] new directories get a
/// default mode that others can enter.
class _ReplaceSftp extends Fake implements SftpClient {
  _ReplaceSftp(this.files);

  final Map<String, List<int>> files;
  final links = <String, String>{};
  final setStats = <String>[];
  final modes = <String, int>{};
  final directories = <String, int>{};

  /// Each opened path with its directory's mode at that moment, or null when
  /// the directory is not one this save created.
  final opened = <String, int?>{};

  /// Paths opened with truncation, which only the in-place fallback does.
  final truncated = <String>[];
  bool posixRename = true;
  bool ignoresMkdirMode = false;
  int originalMode = 0x81ED;
  Object? writeFailure;
  Object? setStatFailure;
  Object? mkdirFailure;

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async {
    if (!followLink && links.containsKey(path)) {
      return SftpFileAttrs(mode: const SftpFileMode.value(0xA1FF));
    }
    if (!files.containsKey(links[path] ?? path)) {
      // ignore: only_throw_errors, dartssh2 models protocol errors this way.
      throw SftpStatusError(SftpStatusCode.noSuchFile, 'missing');
    }
    return SftpFileAttrs(
      mode: SftpFileMode.value(originalMode),
      userID: 7,
      groupID: 8,
    );
  }

  @override
  Future<String> absolute(String path) async => links[path] ?? path;

  @override
  Future<void> mkdir(String path, [SftpFileAttrs? attrs]) async {
    _checkNameLength(path);
    // ignore: only_throw_errors, dartssh2 models protocol errors this way.
    if (mkdirFailure case final failure?) throw failure;
    final mode = attrs?.mode?.value;
    directories[path] = 0x4000 | (ignoresMkdirMode ? 0x1ED : mode ?? 0x1ED);
  }

  @override
  Future<void> rmdir(String dirname) async {
    if (files.keys.any((path) => path.startsWith('$dirname/'))) {
      // ignore: only_throw_errors, dartssh2 models protocol errors this way.
      throw SftpStatusError(SftpStatusCode.failure, 'not empty');
    }
    directories.remove(dirname);
  }

  @override
  Future<SftpFile> open(String path, {SftpFileOpenMode? mode}) async {
    _checkNameLength(path);
    if (mode!.flag & SftpFileOpenMode.truncate.flag != 0) truncated.add(path);
    opened[path] = directories[path.substring(0, path.lastIndexOf('/'))];
    files[path] = [];
    return _ReplaceSftpFile(this, path);
  }

  @override
  Future<void> setStat(String path, SftpFileAttrs attrs) async {
    // ignore: only_throw_errors, dartssh2 models protocol errors this way.
    if (setStatFailure case final failure?) throw failure;
    setStats.add(path);
    if (attrs.mode case final mode?) {
      if (directories.containsKey(path)) {
        directories[path] = 0x4000 | mode.value;
      } else {
        modes[path] = mode.value;
      }
    }
  }

  @override
  Future<void> rename(String oldPath, String newPath) async {
    _checkNameLength(newPath);
    if (!posixRename && files.containsKey(newPath)) {
      // ignore: only_throw_errors, dartssh2 models protocol errors this way.
      throw SftpStatusError(SftpStatusCode.failure, 'exists');
    }
    files[newPath] = files.remove(oldPath)!;
    if (modes.remove(oldPath) case final mode?) modes[newPath] = mode;
  }

  void _checkNameLength(String path) {
    if (path.substring(path.lastIndexOf('/') + 1).length > 255) {
      // OpenSSH reports ENAMETOOLONG as a bad message.
      // ignore: only_throw_errors, dartssh2 models protocol errors this way.
      throw SftpStatusError(SftpStatusCode.badMessage, 'name too long');
    }
  }

  @override
  Future<void> remove(String filename) async => files.remove(filename);
}

class _ReplaceSftpFile extends Fake implements SftpFile {
  _ReplaceSftpFile(this.sftp, this.path);

  final _ReplaceSftp sftp;
  final String path;

  @override
  Future<void> writeBytes(
    Uint8List data, {
    int chunkSize = 0,
    int maxPendingRequests = 0,
    int offset = 0,
  }) async {
    // ignore: only_throw_errors, dartssh2 models protocol errors this way.
    if (sftp.writeFailure case final failure?) throw failure;
    sftp.files[path]!.addAll(data);
  }

  @override
  Future<void> close() async {}
}

void registerRemoteFileServiceIoTests() {
  group('remote_file_service_io', () {
    late Directory directory;
    late MockSftpClient sftp;
    late _MockSftpFile remoteFile;
    const service = RemoteFileService();

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('remote-file-test-');
      sftp = MockSftpClient();
      remoteFile = _MockSftpFile();
      when(() => sftp.open('/remote/file')).thenAnswer((_) async => remoteFile);
      when(() => remoteFile.close()).thenAnswer((_) async {});
    });

    tearDown(() async {
      await directory.delete(recursive: true);
    });

    test(
      'closes the remote handle when the local download cannot open',
      () async {
        when(() => remoteFile.read())
            .thenAnswer((_) => Stream.value(Uint8List.fromList([1, 2, 3])));

        await expectLater(
          service.downloadFile(
            sftp: sftp,
            remotePath: '/remote/file',
            localPath: '${directory.path}/missing/file',
          ),
          throwsA(isA<FileSystemException>()),
        );

        verify(() => remoteFile.close()).called(1);
      },
    );

    test('closes the remote handle when the download stream fails', () async {
      final failure = SftpStatusError(SftpStatusCode.failure, 'read failed');
      when(() => remoteFile.read())
          .thenAnswer((_) => Stream<Uint8List>.error(failure));

      await expectLater(
        service.downloadFile(
          sftp: sftp,
          remotePath: '/remote/file',
          localPath: '${directory.path}/file',
        ),
        throwsA(same(failure)),
      );

      verify(() => remoteFile.close()).called(1);
    });

    test('downloads all chunks and closes the remote handle', () async {
      when(() => remoteFile.read()).thenAnswer(
        (_) => Stream.fromIterable([
          Uint8List.fromList([0, 1, 255]),
          Uint8List.fromList([2, 3]),
        ]),
      );
      final file = File('${directory.path}/file');

      await service.downloadFile(
        sftp: sftp,
        remotePath: '/remote/file',
        localPath: file.path,
      );

      expect(await file.readAsBytes(), [0, 1, 255, 2, 3]);
      verify(() => remoteFile.close()).called(1);
    });
    test('reports persisted bytes and accepts the exact byte limit', () async {
      final chunks = [
        Uint8List.fromList([1, 2]),
        Uint8List.fromList([3]),
      ];
      when(() => remoteFile.read())
          .thenAnswer((_) => Stream.fromIterable(chunks));
      final file = File('${directory.path}/file');
      final progress = <int>[];
      await service.downloadFile(
        sftp: sftp,
        remotePath: '/remote/file',
        localPath: file.path,
        maxBytes: 3,
        onProgress: (bytes) async {
          expect(await file.length(), bytes);
          progress.add(bytes);
        },
      );
      expect(progress, [2, 3]);
      expect(await file.readAsBytes(), [1, 2, 3]);
    });

    test('rejects an oversized chunk before writing it', () async {
      when(() => remoteFile.read()).thenAnswer(
        (_) => Stream.fromIterable([
          Uint8List.fromList([1, 2]),
          Uint8List.fromList([3, 4]),
        ]),
      );
      final file = File('${directory.path}/file');
      await expectLater(
        service.downloadFile(
          sftp: sftp,
          remotePath: '/remote/file',
          localPath: file.path,
          maxBytes: 3,
        ),
        throwsA(
          isA<RemoteFileDownloadLimitException>().having(
            (error) => error.byteCount,
            'byteCount',
            4,
          ),
        ),
      );
      expect(await file.readAsBytes(), [1, 2]);
      verify(() => remoteFile.close()).called(1);
    });

    test('does not open a download that is already cancelled', () async {
      final token = RemoteFileDownloadCancelToken()..cancel();
      await expectLater(
        service.downloadFile(
          sftp: sftp,
          remotePath: '/remote/file',
          localPath: '${directory.path}/file',
          cancelToken: token,
        ),
        throwsA(isA<RemoteFileDownloadCancelledException>()),
      );
      verifyNever(() => sftp.open(any()));
    });

    test('closes a handle opened after cancellation', () async {
      final opened = Completer<SftpFile>();
      when(() => sftp.open('/remote/file')).thenAnswer((_) => opened.future);
      final token = RemoteFileDownloadCancelToken();
      final download = service.downloadFile(
        sftp: sftp,
        remotePath: '/remote/file',
        localPath: '${directory.path}/file',
        cancelToken: token,
      );
      final expectation = expectLater(
        download,
        throwsA(isA<RemoteFileDownloadCancelledException>()),
      );
      token.cancel();
      opened.complete(remoteFile);
      await expectation;
      verify(() => remoteFile.close()).called(1);
      verifyNever(() => remoteFile.read());
    });

    test(
      'cancellation closes the remote handle once and stops writes',
      () async {
        final token = RemoteFileDownloadCancelToken();
        when(() => remoteFile.read()).thenAnswer(
          (_) => Stream.fromIterable([
            Uint8List.fromList([1]),
            Uint8List.fromList([2]),
          ]),
        );
        final file = File('${directory.path}/file');
        await expectLater(
          service.downloadFile(
            sftp: sftp,
            remotePath: '/remote/file',
            localPath: file.path,
            cancelToken: token,
            onProgress: (_) => token.cancel(),
          ),
          throwsA(isA<RemoteFileDownloadCancelledException>()),
        );
        expect(await file.readAsBytes(), [1]);
        token.cancel();
        verify(() => remoteFile.close()).called(1);
      },
    );

    test('does not report success until remote closure succeeds', () async {
      final closing = Completer<void>();
      final closeStarted = Completer<void>();
      when(() => remoteFile.read()).thenAnswer((_) => const Stream.empty());
      when(remoteFile.close).thenAnswer((_) {
        closeStarted.complete();
        return closing.future;
      });
      final failure = SftpStatusError(SftpStatusCode.failure, 'close failed');
      var completed = false;
      final download = service
          .downloadFile(
            sftp: sftp,
            remotePath: '/remote/file',
            localPath: '${directory.path}/file',
          )
          .whenComplete(() => completed = true);
      final expectation = expectLater(download, throwsA(same(failure)));
      await closeStarted.future;
      expect(completed, isFalse);
      closing.completeError(failure);
      await expectation;
      verify(remoteFile.close).called(1);
    });

    for (final operation in ['write', 'close']) {
      test('closes both handles when local $operation fails', () async {
        final localFile = _MockLocalFile();
        final localHandle = _MockRandomAccessFile();
        final chunk = Uint8List.fromList([1, 2, 3]);
        final failure = FileSystemException('$operation failed');
        when(() => remoteFile.read()).thenAnswer((_) => Stream.value(chunk));
        when(() => localFile.open(mode: FileMode.write))
            .thenAnswer((_) async => localHandle);
        when(() => localHandle.writeFrom(chunk)).thenAnswer((_) async {
          if (operation == 'write') throw failure;
          return localHandle;
        });
        when(localHandle.close).thenAnswer((_) async {
          if (operation == 'close') throw failure;
        });
        await IOOverrides.runZoned(
          () => expectLater(
            service.downloadFile(
              sftp: sftp,
              remotePath: '/remote/file',
              localPath: '${directory.path}/file',
            ),
            throwsA(same(failure)),
          ),
          createFile: (_) => localFile,
        );
        verify(localHandle.close).called(1);
        verify(remoteFile.close).called(1);
      });
    }

    group('upload progress', () {
      setUpAll(() {
        registerFallbackValue(SftpFileOpenMode.read);
        registerFallbackValue(SftpFileAttrs());
        registerFallbackValue(Uint8List(0));
      });

      setUp(() {
        when(() => sftp.open('/remote/file', mode: any(named: 'mode')))
            .thenAnswer((_) async => remoteFile);
        when(() => remoteFile.writeBytes(any(), offset: any(named: 'offset')))
            .thenAnswer((_) async {});
        when(() => sftp.setStat('/remote/file', any()))
            .thenAnswer((_) async {});
      });

      test('splits one oversized chunk and reports cumulative bytes', () async {
        const chunk = RemoteFileService.uploadChunkBytes;
        final bytes = Uint8List(chunk * 2 + 10);
        final reported = <int>[];

        await service.uploadBytes(
          sftp: sftp,
          remotePath: '/remote/file',
          bytes: bytes,
          onProgress: reported.add,
        );

        expect(reported, [chunk, chunk * 2, chunk * 2 + 10]);
        final writes = verify(
          () => remoteFile.writeBytes(
            captureAny(),
            offset: captureAny(named: 'offset'),
          ),
        ).captured;
        expect(writes, hasLength(6));
        expect(writes[1], 0);
        expect(writes[3], chunk);
        expect(writes[5], chunk * 2);
        expect((writes[4] as Uint8List).length, 10);
      });

      test('reports each source chunk once when they are small', () async {
        final reported = <int>[];

        await service.uploadStream(
          sftp: sftp,
          remotePath: '/remote/file',
          stream: Stream.fromIterable([
            [1, 2, 3],
            [4, 5],
          ]),
          onProgress: reported.add,
        );

        expect(reported, [3, 5]);
        verify(() => remoteFile.close()).called(1);
      });

      test('awaits the progress callback before the next write', () async {
        final order = <String>[];
        when(() => remoteFile.writeBytes(any(), offset: any(named: 'offset')))
            .thenAnswer((invocation) async {
              order.add('write ${invocation.namedArguments[#offset]}');
            });

        await service.uploadStream(
          sftp: sftp,
          remotePath: '/remote/file',
          stream: Stream.fromIterable([
            [1],
            [2],
          ]),
          onProgress: (uploadedBytes) async {
            await Future<void>.delayed(Duration.zero);
            order.add('progress $uploadedBytes');
          },
        );

        expect(order, ['write 0', 'progress 1', 'write 1', 'progress 2']);
      });
    });

    group('replaceFileBytes', () {
      test('a failed save leaves the original file intact', () async {
        final server = _ReplaceSftp({
          '/srv/notes.txt': [1, 2, 3],
        })..writeFailure = SftpStatusError(SftpStatusCode.failure, 'lost');

        await expectLater(
          service.replaceFileBytes(
            sftp: server,
            remotePath: '/srv/notes.txt',
            bytes: Uint8List.fromList([9]),
          ),
          throwsA(isA<SftpStatusError>()),
        );

        expect(server.files, {
          '/srv/notes.txt': [1, 2, 3],
        });
        expect(server.directories, isEmpty);
      });

      test(
        'replaces a symlink target with its metadata without posix-rename',
        () async {
          final server =
              _ReplaceSftp({
                  '/srv/real.txt': [1],
                })
                ..links['/srv/link'] = '/srv/real.txt'
                ..posixRename = false;

          await service.replaceFileBytes(
            sftp: server,
            remotePath: '/srv/link',
            bytes: Uint8List.fromList([9]),
          );

          expect(server.files, {
            '/srv/real.txt': [9],
          });
          expect(server.links, {'/srv/link': '/srv/real.txt'});
          expect(server.truncated, isEmpty);
          expect(server.directories, isEmpty);
          final scratch = server.setStats.first;
          expect(scratch, startsWith('/srv/.monkeyssh-save-'));
          expect(server.setStats, [scratch, '$scratch/new', '$scratch/new']);
        },
      );

      test('writes the copy only inside a 0700 scratch directory', () async {
        for (final ignoresMkdirMode in [false, true]) {
          final server =
              _ReplaceSftp({
                  '/srv/secret': [1],
                })
                ..originalMode = 0x8180
                ..ignoresMkdirMode = ignoresMkdirMode;

          await service.replaceFileBytes(
            sftp: server,
            remotePath: '/srv/secret',
            bytes: Uint8List.fromList([9]),
          );

          expect(server.files, {
            '/srv/secret': [9],
          });
          expect(server.opened.values, [0x41C0]);
          expect(server.modes['/srv/secret'], 0x8180);
          expect(server.directories, isEmpty);
        }
      });

      test('writes in place without a private scratch directory', () async {
        for (final server in [
          _ReplaceSftp({
              '/srv/secret': [1],
            })
            ..mkdirFailure = SftpStatusError(
              SftpStatusCode.permissionDenied,
              'read-only directory',
            ),
          _ReplaceSftp({
              '/srv/secret': [1],
            })
            ..setStatFailure = SftpStatusError(
              SftpStatusCode.permissionDenied,
              'no chmod',
            ),
        ]) {
          await service.replaceFileBytes(
            sftp: server,
            remotePath: '/srv/secret',
            bytes: Uint8List.fromList([9]),
          );

          expect(server.files, {
            '/srv/secret': [9],
          });
          expect(server.opened.keys, ['/srv/secret']);
          expect(server.truncated, ['/srv/secret']);
          expect(server.directories, isEmpty);
        }
      });

      test('saves a 250-byte name without posix-rename', () async {
        final path = '/srv/${'n' * 246}.txt';
        final server = _ReplaceSftp({
          path: [1],
        })..posixRename = false;

        await service.replaceFileBytes(
          sftp: server,
          remotePath: path,
          bytes: Uint8List.fromList([9]),
        );

        expect(server.files, {
          path: [9],
        });
        expect(server.truncated, isEmpty);
        expect(server.directories, isEmpty);
      });
    });
  });
}

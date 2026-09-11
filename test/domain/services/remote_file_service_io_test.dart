import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/services/remote_file_service.dart';

class _MockSftpClient extends Mock implements SftpClient {}

class _MockSftpFile extends Mock implements SftpFile {}

class _MockLocalFile extends Mock implements File {}

class _MockRandomAccessFile extends Mock implements RandomAccessFile {}

void main() {
  late Directory directory;
  late _MockSftpClient sftp;
  late _MockSftpFile remoteFile;
  const service = RemoteFileService();

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('remote-file-test-');
    sftp = _MockSftpClient();
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
      when(
        () => remoteFile.read(),
      ).thenAnswer((_) => Stream.value(Uint8List.fromList([1, 2, 3])));

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
    when(
      () => remoteFile.read(),
    ).thenAnswer((_) => Stream<Uint8List>.error(failure));

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
    when(
      () => remoteFile.read(),
    ).thenAnswer((_) => Stream.fromIterable(chunks));
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

  test('cancellation closes the remote handle once and stops writes', () async {
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
  });

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
      when(
        () => localFile.open(mode: FileMode.write),
      ).thenAnswer((_) async => localHandle);
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
}

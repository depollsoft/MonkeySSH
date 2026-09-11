import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/services/remote_file_service.dart';

class _MockSftpClient extends Mock implements SftpClient {}

class _MockSftpFile extends Mock implements SftpFile {}

void main() {
  const service = RemoteFileService();
  late _MockSftpClient sftp;
  late _MockSftpFile file;

  setUpAll(() {
    registerFallbackValue(SftpFileOpenMode.read);
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(const Stream<Uint8List>.empty());
    registerFallbackValue(SftpFileAttrs());
  });

  setUp(() {
    sftp = _MockSftpClient();
    file = _MockSftpFile();
    when(
      () => sftp.open('/upload', mode: any(named: 'mode')),
    ).thenAnswer((_) async => file);
    when(file.close).thenAnswer((_) async {});
    when(() => sftp.setStat('/upload', any())).thenAnswer((_) async {});
    when(
      () => file.writeBytes(any(), offset: any(named: 'offset')),
    ).thenAnswer((_) async {});
    // Exercise the actual upstream writer if uploadStream regresses to .write.
    when(() => file.write(any())).thenAnswer(
      (call) => SftpFileWriter(
        file,
        call.positionalArguments.single as Stream<Uint8List>,
        0,
        null,
      ),
    );
  });

  for (final failure in <Object>[
    SftpStatusError(SftpStatusCode.permissionDenied, 'denied'),
    SSHStateError('closed'),
    Exception('write failed'),
    NoSuchMethodError.withInvocation(Object(), Invocation.method(#write, [])),
  ]) {
    for (final synchronous in [false, true]) {
      test(
        'routes ${failure.runtimeType} write failure, sync=$synchronous',
        () async {
          final stub = when(
            () => file.writeBytes(any(), offset: any(named: 'offset')),
          );
          if (synchronous) {
            stub.thenThrow(failure);
          } else {
            stub.thenAnswer((_) => Future<void>.error(failure));
          }

          await expectLater(
            service.uploadStream(
              sftp: sftp,
              remotePath: '/upload',
              stream: Stream.value([1, 2, 3]),
            ),
            throwsA(same(failure)),
          );
          verify(file.close).called(1);
          verifyNever(() => sftp.setStat('/upload', any()));
        },
      );
    }
  }

  test('routes source-stream errors and closes the remote handle', () async {
    final failure = Exception('local read failed');
    await expectLater(
      service.uploadStream(
        sftp: sftp,
        remotePath: '/upload',
        stream: Stream<List<int>>.error(failure),
      ),
      throwsA(same(failure)),
    );
    verify(file.close).called(1);
    verifyNever(() => sftp.setStat('/upload', any()));
  });

  test('preserves the write failure when close also fails', () async {
    final failure = StateError('write failed');
    when(
      () => file.writeBytes(any(), offset: any(named: 'offset')),
    ).thenAnswer((_) => Future<void>.error(failure));
    when(
      file.close,
    ).thenAnswer((_) => Future<void>.error(SSHStateError('closed')));
    await expectLater(
      service.uploadBytes(
        sftp: sftp,
        remotePath: '/upload',
        bytes: Uint8List.fromList([1]),
      ),
      throwsA(same(failure)),
    );
    verify(file.close).called(1);
  });

  for (final stage in ['close', 'chmod']) {
    test('reports $stage failure after writing', () async {
      final failure = SftpStatusError(SftpStatusCode.failure, stage);
      if (stage == 'close') {
        when(file.close).thenAnswer((_) => Future<void>.error(failure));
      } else {
        when(
          () => sftp.setStat('/upload', any()),
        ).thenAnswer((_) => Future<void>.error(failure));
      }
      await expectLater(
        service.uploadBytes(
          sftp: sftp,
          remotePath: '/upload',
          bytes: Uint8List.fromList([1]),
        ),
        throwsA(same(failure)),
      );
      verify(file.close).called(1);
    });
  }

  test('awaits writes in order and applies permissions after close', () async {
    final firstWrite = Completer<void>();
    final calls = <String>[];
    when(() => file.writeBytes(any(), offset: any(named: 'offset'))).thenAnswer(
      (call) async {
        calls.add(
          '${call.namedArguments[#offset]}:${call.positionalArguments.single}',
        );
        if (calls.length == 1) {
          await firstWrite.future;
        }
      },
    );
    when(file.close).thenAnswer((_) async => calls.add('close'));
    when(
      () => sftp.setStat('/upload', any()),
    ).thenAnswer((_) async => calls.add('chmod'));
    final upload = service.uploadStream(
      sftp: sftp,
      remotePath: '/upload',
      stream: Stream.fromIterable([
        [1, 2],
        Uint8List.fromList([3]),
      ]),
    );
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['0:[1, 2]']);
    firstWrite.complete();
    await upload;
    expect(calls, ['0:[1, 2]', '2:[3]', 'close', 'chmod']);
  });
}

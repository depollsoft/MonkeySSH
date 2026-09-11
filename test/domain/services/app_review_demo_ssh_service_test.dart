// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/services/app_review_demo_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_installer_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_service.dart';
import 'package:monkeyssh/domain/services/remote_file_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

void main() {
  late AppDatabase database;
  late SshService service;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    service = SshService(
      hostRepository: HostRepository(
        database,
        SecretEncryptionService.forTesting(),
      ),
    );
  });

  tearDown(() async {
    await service.disconnectAll();
    await database.close();
  });

  Future<SftpFile> openDemoFile() async {
    final hostId = await database
        .into(database.hosts)
        .insert(
          HostsCompanion.insert(
            label: '${AppReviewDemoService.demoHostLabelPrefix} Upload tests',
            hostname: '127.0.0.1',
            port: const Value(2201),
            username: 'reviewer',
            tags: const Value('app-review,demo,monkeymux'),
          ),
        );
    final result = await service.connectToHost(hostId);
    expect(result.success, isTrue);
    final sftp = await service.getSession(result.connectionId!)!.sftp();
    return sftp.open(
      '/home/reviewer/work/monkeyssh-demo/test.bin',
      mode: SftpFileOpenMode.create | SftpFileOpenMode.write,
    );
  }

  test(
    'demo file implements metadata, sparse writes and chunked reads',
    () async {
      final file = await openDemoFile();
      addTearDown(file.close);
      await file.writeBytes(Uint8List.fromList([255, 0, 128]), offset: 2);
      expect((await file.stat()).size, 5);
      expect(await file.readBytes(), [0, 0, 255, 0, 128]);
      await file.setStat(
        SftpFileAttrs(size: 3, mode: const SftpFileMode.value(0x8180)),
      );
      expect((await file.stat()).mode?.value, 0x8180);
      await file.setStat(SftpFileAttrs(size: 6));
      expect(await file.readBytes(), [0, 0, 255, 0, 0, 0]);
      final progress = <int>[];
      expect(
        await file
            .read(offset: 1, length: 4, chunkSize: 2, onProgress: progress.add)
            .toList(),
        [
          [0, 255],
          [0, 0],
        ],
      );
      expect(progress, [2, 4]);
      await expectLater(
        file.statvfs(),
        throwsA(isA<SftpExtensionUnsupportedError>()),
      );
    },
  );

  test('demo file supports sink and random-access downloads', () async {
    final file = await openDemoFile();
    addTearDown(file.close);
    await file.writeBytes(Uint8List.fromList([1, 2, 3, 4]));
    final destination = StreamController<List<int>>();
    addTearDown(destination.close);
    final bytes = destination.stream.expand((chunk) => chunk).toList();
    expect(
      await file.downloadTo(
        destination.sink,
        offset: 1,
        length: 2,
        closeDestination: true,
      ),
      2,
    );
    expect(await bytes, [2, 3]);

    final directory = await Directory.systemTemp.createTemp('demo-sftp-');
    addTearDown(() => directory.delete(recursive: true));
    final localFile = File('${directory.path}/download.bin');
    final handle = await localFile.open(mode: FileMode.write);
    expect(await file.downloadToRandomAccess(handle, offset: 1, length: 2), 2);
    await handle.close();
    expect(await localFile.readAsBytes(), [0, 2, 3]);
  });

  test('closed demo file members fail with SftpError', () async {
    final file = await openDemoFile();
    await file.close();
    await file.close();
    expect(file.isClosed, isTrue);
    await expectLater(file.stat(), throwsA(isA<SftpError>()));
    await expectLater(
      file.setStat(SftpFileAttrs(size: 1)),
      throwsA(isA<SftpError>()),
    );
    await expectLater(file.statvfs(), throwsA(isA<SftpError>()));
    await expectLater(file.readBytes(), throwsA(isA<SftpError>()));
    await expectLater(file.writeBytes(Uint8List(1)), throwsA(isA<SftpError>()));
    expect(() => file.write(const Stream.empty()), throwsA(isA<SftpError>()));
  });

  test('demo writer reports source failures through done', () async {
    final file = await openDemoFile();
    addTearDown(file.close);
    final source = StreamController<Uint8List>();
    const failure = FileSystemException('Upload source disappeared');
    final writer = file.write(source.stream);
    final checked = expectLater(writer.done, throwsA(same(failure)));
    source.addError(failure);
    await checked;
    await source.close();
  });

  test(
    'demo writer reports a file closed during upload through done',
    () async {
      final file = await openDemoFile();
      final source = StreamController<Uint8List>();
      final writer = file.write(source.stream);
      final checked = expectLater(writer.done, throwsA(isA<SftpError>()));
      await file.close();
      source.add(Uint8List.fromList([1, 2, 3]));
      await checked;
      await source.close();
    },
  );

  test(
    'demo writer pause, resume and repeated abort preserve committed bytes',
    () async {
      final file = await openDemoFile();
      addTearDown(file.close);
      final source = StreamController<Uint8List>();
      final wrote = Completer<void>();
      final writer = file.write(
        source.stream,
        onProgress: (_) => wrote.complete(),
      )..pause();
      source.add(Uint8List.fromList([128, 255]));
      await Future<void>.delayed(Duration.zero);
      expect(writer.progress, 0);
      writer.resume();
      await wrote.future;
      writer.pause();
      source.add(Uint8List.fromList([1, 2]));
      await writer.abort();
      await writer.abort();
      await writer.done;
      await source.close();
      expect(writer.progress, 2);
      expect(await file.readBytes(), [128, 255]);
    },
  );

  test('connectToHost creates a usable local App Review demo session', () async {
    final hostId = await database
        .into(database.hosts)
        .insert(
          HostsCompanion.insert(
            label:
                '${AppReviewDemoService.demoHostLabelPrefix} MonkeyMux workspace',
            hostname: '127.0.0.1',
            port: const Value(2201),
            username: 'reviewer',
            tags: const Value('app-review,demo,monkeymux'),
          ),
        );

    final result = await service.connectToHost(hostId);

    expect(result.success, isTrue);
    expect(result.connectionId, isNotNull);

    final session = service.getSession(result.connectionId!);
    expect(session, isNotNull);

    final shell = await session!.getShell();
    final banner = await session.shellStdoutStream.first.timeout(
      const Duration(seconds: 1),
    );
    expect(banner, contains('MonkeySSH App Review Demo'));

    shell.write(Uint8List.fromList(utf8.encode('pwd\r')));
    final pwdOutput = await session.shellStdoutStream.firstWhere(
      (chunk) => chunk.contains('/home/reviewer/work/monkeyssh-demo'),
    );
    expect(pwdOutput, contains('/home/reviewer/work/monkeyssh-demo'));

    final forward = await session.client.forwardLocal('localhost', 3000);
    // Deliver request data after the constructor's scheduled close begins.
    await Future<void>.delayed(Duration.zero);
    forward.sink.add(utf8.encode('GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'));
    await forward.flush();
    final response = await forward.stream.expand((bytes) => bytes).toList();
    expect(utf8.decode(response), startsWith('HTTP/1.1 200 OK'));
    await forward.done;

    final sftp = await session.sftp();
    final files = await sftp.listdir('/home/reviewer/work/monkeyssh-demo');
    expect(files.map((file) => file.filename), contains('README.md'));

    const uploadedText = 'streamed demo upload';
    const uploadedPath = '/home/reviewer/work/monkeyssh-demo/upload.txt';
    await const RemoteFileService().uploadBytes(
      sftp: sftp,
      remotePath: uploadedPath,
      bytes: Uint8List.fromList(utf8.encode(uploadedText)),
    );
    var uploadedFile = await sftp.open(uploadedPath);
    expect(utf8.decode(await uploadedFile.readBytes()), uploadedText);
    await uploadedFile.close();
    expect(
      (await sftp.listdir(
        '/home/reviewer/work/monkeyssh-demo',
      )).map((file) => file.filename),
      contains('upload.txt'),
    );

    const shorterText = 'short';
    await const RemoteFileService().uploadBytes(
      sftp: sftp,
      remotePath: uploadedPath,
      bytes: Uint8List.fromList(utf8.encode(shorterText)),
    );
    uploadedFile = await sftp.open(uploadedPath);
    expect(utf8.decode(await uploadedFile.readBytes()), shorterText);
    await uploadedFile.close();

    final binaryBytes = Uint8List.fromList(
      List<int>.generate(20 * 1024, (index) => index % 256),
    );
    const binaryPath = '/home/reviewer/work/monkeyssh-demo/image.bin';
    await const RemoteFileService().uploadBytes(
      sftp: sftp,
      remotePath: binaryPath,
      bytes: binaryBytes,
    );
    final binaryFile = await sftp.open(binaryPath);
    expect(await binaryFile.readBytes(), orderedEquals(binaryBytes));
    await binaryFile.close();

    final mux = MonkeyMuxService(
      installer: MonkeyMuxInstallerService(
        manifestFuture: Future.value(
          const MonkeyMuxManifest(version: 'demo', entries: []),
        ),
        remoteFileService: const RemoteFileService(),
      ),
    );
    final copilotScreen = session.shellStdoutStream.firstWhere(
      (chunk) => chunk.contains('GitHub Copilot CLI'),
    );
    final windows = await mux.listWindows(session, 'review-workspace');
    expect(await copilotScreen, contains('Review PR #643'));
    expect(windows, hasLength(4));
    expect(
      windows.singleWhere((window) => window.isActive).name,
      'Copilot CLI',
    );

    final codexScreen = session.shellStdoutStream.firstWhere(
      (chunk) => chunk.contains('Codex CLI (demo)'),
    );
    await mux.createWindow(
      session,
      'review-workspace',
      command: 'codex --yolo',
      name: 'Codex',
    );
    expect(await codexScreen, contains('Patch ready'));
    final withCodex = await mux.listWindows(session, 'review-workspace');
    expect(withCodex, hasLength(5));
    expect(withCodex.singleWhere((window) => window.isActive).name, 'Codex');

    final claudeScreen = session.shellStdoutStream.firstWhere(
      (chunk) => chunk.contains('Claude Code v'),
    );
    await mux.selectWindow(session, 'review-workspace', 1);
    expect(await claudeScreen, contains('Working directory'));
    final selected = await mux.listWindows(session, 'review-workspace');
    expect(
      selected.singleWhere((window) => window.isActive).name,
      'Claude Code',
    );
  });
}

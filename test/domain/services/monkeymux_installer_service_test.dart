import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ignore_for_file: public_member_api_docs

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/services/monkeymux_installer_service.dart';
import 'package:monkeyssh/domain/services/remote_file_service.dart';
import 'package:monkeyssh/domain/services/ssh_exec_queue.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

import '../../helpers/mock_ssh_exec_session.dart';
import '../../helpers/powershell_test_helpers.dart';

class _MockSshClient extends Mock implements SSHClient {}

class _MockSshSession extends MockSessionWithChannel {}

class _MockSftpClient extends Mock implements SftpClient {}

class _FakeAssetBundle extends CachingAssetBundle {
  _FakeAssetBundle(this.assets);

  final Map<String, Uint8List> assets;
  final loads = <String>[];

  @override
  Future<ByteData> load(String key) async {
    loads.add(key);
    final bytes = assets[key];
    if (bytes == null) {
      throw StateError('Missing test asset: $key');
    }
    return ByteData.sublistView(bytes);
  }
}

class _FakeRemoteFileService extends RemoteFileService {
  _FakeRemoteFileService({
    this.homeDirectory = '/home/proof',
    this.writeUploads = false,
  });

  final String homeDirectory;
  final bool writeUploads;
  Uint8List? uploadedBytes;
  String? uploadedPath;
  bool uploaded = false;
  int uploadCount = 0;

  @override
  Future<String> resolveInitialDirectory(SftpClient sftp) async =>
      homeDirectory;

  @override
  Future<void> ensureDirectoryExists(
    SftpClient sftp,
    String remotePath, {
    SftpFileMode? mode,
  }) async {}

  @override
  Future<void> uploadBytes({
    required SftpClient sftp,
    required String remotePath,
    required Uint8List bytes,
    bool applyPrivateMode = true,
  }) async {
    uploaded = true;
    uploadCount++;
    uploadedBytes = bytes;
    uploadedPath = remotePath;
    if (writeUploads) {
      final file = File(remotePath);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
    }
  }
}

void main() {
  for (final windows in [false, true]) {
    for (final opens in [false, true]) {
      testWidgets(
        'installer ${windows ? 'raw' : 'marked'} probe bounds ${opens ? 'busy output' : 'opening'}',
        (tester) async {
          final harness = _InstallHarness();
          when(() => harness.client.remoteVersion).thenReturn(
            windows ? 'SSH-2.0-OpenSSH_for_Windows_9.5' : 'SSH-2.0-OpenSSH_9.6',
          );
          final opening = Completer<SSHSession>();
          final channel = _MockSshSession();
          final stdout = StreamController<Uint8List>();
          when(() => channel.stdout).thenAnswer((_) => stdout.stream);
          when(() => channel.stderr).thenAnswer((_) => const Stream.empty());
          when(
            () => harness.client.execute(any(), pty: any(named: 'pty')),
          ).thenAnswer((_) => opens ? Future.value(channel) : opening.future);
          final result = expectLater(
            harness.installer.probePlatform(harness.session),
            throwsA(
              windows
                  ? isA<MonkeyMuxInstallException>()
                  : isA<TimeoutException>(),
            ),
          );
          await tester.pump();
          var nextRan = false;
          final next = harness.session.runQueuedExec(() async {
            nextRan = true;
          }, priority: SshExecPriority.low);
          expect(
            pendingQueuedSshExecCountForTesting(harness.session.connectionId),
            1,
          );
          for (var second = 0; second < 21; second++) {
            if (opens) {
              stdout.add(Uint8List.fromList(utf8.encode('unrelated output\n')));
            }
            await tester.pump(const Duration(seconds: 1));
          }
          expect(nextRan, isTrue);
          await result;
          await next;
          if (!opens) {
            opening.complete(channel);
            await tester.pump();
          } else {
            expect(stdout.hasListener, isFalse);
          }
          if (opens) {
            verify(channel.close).called(1);
          } else {
            verify(channel.channel.destroy).called(1);
          }
          verify(
            () => harness.client.execute(any(), pty: any(named: 'pty')),
          ).called(1);
          stdout.close().ignore();
        },
      );
    }
  }

  test(
    'confirmable install replaces in-flight probe that cannot prompt',
    () async {
      final harness = _InstallHarness();
      final installer = harness.installer;
      final client = harness.client;
      final sftp = harness.sftp;
      final session = harness.session;
      final firstSftpMayContinue = Completer<void>();
      final acceptedConfirmations = <bool>[];
      final confirmationMayFinish = Completer<void>();
      final supersededProbeReachedShaCheck = Completer<void>();
      var sftpOpenCount = 0;
      when(sftp.close).thenAnswer((_) async {});
      when(client.sftp).thenAnswer((_) {
        sftpOpenCount += 1;
        if (sftpOpenCount == 1) {
          return firstSftpMayContinue.future.then((_) => sftp);
        }
        return Future<SftpClient>.value(sftp);
      });
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        invocation,
      ) async {
        final command = invocation.positionalArguments.single as String;
        if (acceptedConfirmations.isNotEmpty &&
            !supersededProbeReachedShaCheck.isCompleted &&
            (command.contains('sha256sum') ||
                command.contains('shasum -a 256'))) {
          supersededProbeReachedShaCheck.complete();
        }
        return _execSession(
          _outputForCommand(
            command,
            expectedSha: harness.digest,
            remoteFileService: harness.remote,
          ),
        );
      });

      final probeOnlyInstall = installer.ensureInstalled(session);
      MonkeyMuxInstallation? probeOnlyInstallation;
      Object? probeOnlyError;
      final observedProbeOnlyInstall = probeOnlyInstall.then<void>(
        (installation) => probeOnlyInstallation = installation,
        onError: (Object error) => probeOnlyError = error,
      );
      await _waitUntil(() => sftpOpenCount == 1);

      final confirmableInstall = installer.ensureInstalled(
        session,
        priority: SshExecPriority.normal,
        confirmInstall: (request) async {
          acceptedConfirmations.add(true);
          await confirmationMayFinish.future;
          return true;
        },
      );
      await _waitUntil(() => acceptedConfirmations.length == 1);

      firstSftpMayContinue.complete();
      await supersededProbeReachedShaCheck.future.timeout(
        const Duration(seconds: 2),
      );
      expect(probeOnlyInstallation, isNull);
      expect(probeOnlyError, isNull);

      confirmationMayFinish.complete();

      final installation = await confirmableInstall.timeout(
        const Duration(seconds: 2),
      );
      expect(installation.version, '9.9.9');
      expect(installation.installedDuringCall, isTrue);
      expect(acceptedConfirmations, <bool>[true]);
      expect(sftpOpenCount, 2);

      await observedProbeOnlyInstall.timeout(const Duration(seconds: 2));
      expect(probeOnlyError, isNull);
      expect(probeOnlyInstallation?.version, '9.9.9');
    },
  );

  for (final scenario in [
    (
      name: 'reused helper is not marked as installed during the call',
      launcherFails: false,
      corrupt: false,
    ),
    (
      name: 'launcher failure does not block a verified helper',
      launcherFails: true,
      corrupt: false,
    ),
    (
      name: 'fresh install rejects a bundled checksum mismatch before upload',
      launcherFails: false,
      corrupt: true,
    ),
  ]) {
    test(scenario.name, () async {
      final harness = _InstallHarness(
        remote: _FakeRemoteFileService()..uploaded = !scenario.corrupt,
        assets: scenario.corrupt
            ? {
                'assets/test/monkeymux': Uint8List.fromList([0]),
              }
            : {},
      );
      final installer = harness.installer;
      final session = harness.session;
      final client = harness.client;
      final sftp = harness.sftp;
      final remoteFileService = harness.remote;
      final commands = harness.commands;
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        invocation,
      ) async {
        final command = invocation.positionalArguments.single as String;
        commands.add(command);
        if (scenario.launcherFails &&
            command.contains('.local/bin/monkeymux')) {
          throw StateError('launcher directory is read-only');
        }
        return _execSession(
          _outputForCommand(
            command,
            expectedSha: harness.digest,
            remoteFileService: remoteFileService,
          ),
        );
      });

      if (scenario.corrupt) {
        await expectLater(
          installer.ensureInstalled(session, confirmInstall: (_) async => true),
          throwsA(
            isA<MonkeyMuxInstallException>().having(
              (error) => error.message,
              'message',
              'Bundled MonkeyMux checksum does not match the manifest.',
            ),
          ),
        );
        expect(remoteFileService.uploadCount, 0);
        verify(sftp.close).called(1);
        return;
      }
      final installation = await installer.ensureInstalled(session);

      expect(installation.version, '9.9.9');
      expect(installation.installedDuringCall, isFalse);
      expect(remoteFileService.uploadCount, 0);
      expect(
        commands,
        contains(
          allOf(
            contains('.local/bin/monkeymux'),
            contains('ln -s'),
            contains('.monkeyssh/bin/monkeymux/'),
          ),
        ),
      );
    });
  }

  for (final confirmation in ['missing', 'declined', 'accepted']) {
    test('loads the bundle only after confirmation is $confirmation', () async {
      final harness = _InstallHarness();
      final install = harness.installer.ensureInstalled(
        harness.session,
        confirmInstall: confirmation == 'missing'
            ? null
            : (_) async {
                expect(harness.bundle.loads, isEmpty);
                return confirmation == 'accepted';
              },
      );
      if (confirmation == 'accepted') {
        await install;
        expect(harness.bundle.loads, hasLength(1));
        expect(harness.remote.uploadedBytes, harness.binary);
        // Probe, existing-file checksum, one finalization, launcher.
        expect(harness.commands, hasLength(4));
        expect(
          harness.commands.where((command) => command.contains('mv -f')),
          hasLength(1),
        );
      } else {
        await expectLater(
          install,
          throwsA(
            confirmation == 'missing'
                ? isA<MonkeyMuxInstallConfirmationRequiredException>()
                : isA<MonkeyMuxInstallDeclinedException>(),
          ),
        );
        expect(harness.bundle.loads, isEmpty);
        expect(harness.remote.uploadCount, 0);
      }
    });
  }

  for (final encoding in ['gzip', 'invalid-gzip', 'gzip-mismatch', 'unknown']) {
    test('verifies bundled bytes in worker: $encoding', () async {
      final harness = _InstallHarness(encoding: encoding);
      final install = harness.installer.ensureInstalled(
        harness.session,
        confirmInstall: (_) async => true,
      );
      if (encoding == 'gzip') {
        await install;
        expect(harness.remote.uploadedBytes, harness.binary);
      } else {
        await expectLater(
          install,
          throwsA(
            encoding == 'invalid-gzip'
                ? isA<FormatException>()
                : isA<MonkeyMuxInstallException>(),
          ),
        );
        expect(harness.remote.uploadCount, 0);
      }
    });
  }

  for (final scenario in [
    'sha256sum',
    'shasum',
    'checksum-mismatch',
    'hash-failure',
    'chmod-failure',
    'rename-failure',
  ]) {
    test('POSIX finalization stops on failure: $scenario', () async {
      final directory = await Directory.systemTemp.createTemp('monkeymux-test');
      addTearDown(() => directory.delete(recursive: true));
      final remote = _FakeRemoteFileService(
        homeDirectory: "${directory.path}/home with 'quotes'",
        writeUploads: true,
      );
      final harness = _InstallHarness(remote: remote);
      final target = File(
        '${remote.homeDirectory}/.monkeyssh/bin/monkeymux/9.9.9/'
        'darwin-arm64/monkeymux',
      );
      await target.parent.create(recursive: true);
      await target.writeAsString('existing helper');
      final utilities = await Directory('${directory.path}/utilities').create();
      for (final utility in ['sha256sum', 'shasum', 'chmod', 'mv']) {
        final script = File('${utilities.path}/$utility');
        final body = switch (utility) {
          'sha256sum' when scenario == 'shasum' => 'exit 127',
          'sha256sum' || 'shasum' when scenario == 'hash-failure' =>
            'echo "${harness.digest}  file"; exit 1',
          'sha256sum' ||
          'shasum' when scenario == 'checksum-mismatch' => 'echo "wrong  file"',
          'sha256sum' => r'/usr/bin/shasum -a 256 "$@"',
          'shasum' => r'/usr/bin/shasum "$@"',
          'chmod' when scenario == 'chmod-failure' => 'exit 1',
          'mv' when scenario == 'rename-failure' => 'exit 1',
          _ => '/bin/$utility "\$@"',
        };
        await script.writeAsString('#!/bin/sh\n$body\n');
        final chmod = await Process.run('/bin/chmod', ['700', script.path]);
        expect(chmod.exitCode, 0);
      }
      harness.finalize = (command) async {
        final result = await Process.run(
          '/bin/sh',
          ['-c', command],
          environment: {'PATH': utilities.path},
        );
        return result.stdout as String;
      };
      final install = harness.installer.ensureInstalled(
        harness.session,
        confirmInstall: (_) async => true,
      );
      if (scenario == 'sha256sum' || scenario == 'shasum') {
        await install;
        expect(await target.readAsBytes(), harness.binary);
        expect(target.statSync().mode & 0x1ff, 0x1c0);
        expect(File(remote.uploadedPath!).existsSync(), isFalse);
        verifyNever(() => harness.sftp.remove(any()));
      } else {
        await expectLater(
          install,
          throwsA(
            isA<MonkeyMuxInstallException>().having(
              (error) => error.message,
              'message',
              contains('Remote command failed with exit status'),
            ),
          ),
        );
        expect(await target.readAsString(), 'existing helper');
        verify(() => harness.sftp.remove(remote.uploadedPath!)).called(1);
        expect(harness.commands, hasLength(3));
      }
      expect(
        harness.commands.where((command) => command.contains('.tmp')),
        hasLength(1),
      );
    });
  }

  test(
    'Windows installs beside locked builds and reuses the verified copy',
    () async {
      final harness = _InstallHarness(
        windows: true,
        remote: _FakeRemoteFileService(homeDirectory: '/C:/Users/proof’s'),
      );
      const directory =
          '/C:/Users/proof’s/.monkeyssh/bin/monkeymux/9.9.9/windows-amd64';
      final target = '$directory/${harness.digest}/monkeymux.exe';
      final locked = {
        '$directory/monkeymux.exe',
        '$directory/${'a' * 64}/monkeymux.exe',
      };
      final files = {...locked};
      when(() => harness.sftp.remove(any())).thenAnswer((invocation) async {
        final path = invocation.positionalArguments.single as String;
        if (locked.contains(path)) {
          return Future<void>.error(
            SftpStatusError(
              SftpStatusCode.permissionDenied,
              'running executable',
            ),
          );
        }
        if (!files.remove(path)) {
          return Future<void>.error(
            SftpStatusError(SftpStatusCode.noSuchFile, 'missing'),
          );
        }
      });
      when(() => harness.sftp.rename(any(), any())).thenAnswer((
        invocation,
      ) async {
        final destination = invocation.positionalArguments[1] as String;
        expect(destination, target);
        expect(files.contains(destination), isFalse);
        files.add(destination);
      });
      when(
        () => harness.client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((invocation) async {
        final command = invocation.positionalArguments.single as String;
        harness.commands.add(command);
        return _execSession(
          _windowsOutputForCommand(
            command,
            expectedSha: harness.digest,
            remoteFileService: harness.remote,
          ),
        );
      });

      final installed = await harness.installer.ensureInstalled(
        harness.session,
        confirmInstall: (_) async => true,
      );
      expect(installed.installedDuringCall, isTrue);
      expect(files, {...locked, target});
      expect(harness.remote.uploadCount, 1);
      harness.installer.clearCache(harness.session.connectionId);
      final reused = await harness.installer.ensureInstalled(harness.session);
      expect(reused.executablePath, installed.executablePath);
      expect(reused.installedDuringCall, isFalse);
      expect(harness.remote.uploadCount, 1);
      final launcher = decodeEncodedPowerShell(harness.commands.last);
      expect(
        launcher,
        contains('9.9.9\\windows-amd64\\${harness.digest}\\monkeymux.exe'),
      );
    },
  );

  for (final failWith in ['confirmation', 'declined', 'upload']) {
    test(
      'passive install stops after $failWith and explicit retry recovers',
      () async {
        final harness = _InstallHarness();
        if (failWith == 'upload') {
          harness.finalize = (_) async => '__monkeymux_exec_done__:1\n';
        }
        final first = harness.installer.ensureInstalled(
          harness.session,
          confirmInstall: failWith == 'confirmation'
              ? null
              : (_) async => failWith != 'declined',
        );
        await expectLater(first, throwsA(isA<MonkeyMuxInstallException>()));
        final commandCount = harness.commands.length;
        for (var i = 0; i < 3; i++) {
          await expectLater(
            harness.installer.ensureInstalled(harness.session),
            throwsA(isA<MonkeyMuxInstallException>()),
          );
        }
        expect(harness.commands, hasLength(commandCount));
        harness.finalize = null;
        harness.remote.uploaded = false;
        var prompted = false;
        final recovered = await harness.installer.ensureInstalled(
          harness.session,
          confirmInstall: (_) async {
            prompted = true;
            return true;
          },
        );
        expect(prompted, isTrue);
        expect(recovered.installedDuringCall, isTrue);
        expect(
          await harness.installer.ensureInstalled(harness.session),
          same(recovered),
        );
      },
    );
  }

  test('disconnect clears passive install failure', () async {
    final harness = _InstallHarness();
    await expectLater(
      harness.installer.ensureInstalled(harness.session),
      throwsA(isA<MonkeyMuxInstallConfirmationRequiredException>()),
    );
    final commandCount = harness.commands.length;
    harness.installer.clearCache(harness.session.connectionId);
    await expectLater(
      harness.installer.ensureInstalled(harness.session),
      throwsA(isA<MonkeyMuxInstallConfirmationRequiredException>()),
    );
    expect(harness.commands.length, greaterThan(commandCount));
  });

  for (final failure in [
    null,
    'checksum',
    'remove',
    'rename',
    'final-checksum',
  ]) {
    test(
      'Windows installation preserves replacement semantics: $failure',
      () async {
        final harness = _InstallHarness(
          windows: true,
          remote: _FakeRemoteFileService(homeDirectory: '/C:/Users/proof’s'),
        );
        final remoteFileService = harness.remote;
        final assetBytes = harness.binary;
        final expectedSha = harness.digest;
        final installer = harness.installer;
        final client = harness.client;
        final sftp = harness.sftp;
        final session = harness.session;
        final renames = <(String, String)>[];
        final commands = <String>[];
        when(() => sftp.remove(any())).thenAnswer((invocation) async {
          final path = invocation.positionalArguments.single as String;
          if (failure == 'remove' && path.endsWith('monkeymux.exe')) {
            return Future<void>.error(
              SftpStatusError(SftpStatusCode.permissionDenied, 'locked'),
            );
          }
        });
        when(() => sftp.rename(any(), any())).thenAnswer((invocation) async {
          if (failure == 'rename') {
            return Future<void>.error(
              SftpStatusError(SftpStatusCode.failure, 'rename failed'),
            );
          }
          renames.add((
            invocation.positionalArguments[0] as String,
            invocation.positionalArguments[1] as String,
          ));
        });
        when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
          invocation,
        ) async {
          final command = invocation.positionalArguments.single as String;
          commands.add(command);
          if (command.contains('certutil') &&
              remoteFileService.uploaded &&
              (failure == 'checksum' ||
                  (failure == 'final-checksum' && renames.isNotEmpty))) {
            return _execSession('bad checksum');
          }
          return _execSession(
            _windowsOutputForCommand(
              command,
              expectedSha: expectedSha,
              remoteFileService: remoteFileService,
            ),
          );
        });
        final install = installer.ensureInstalled(
          session,
          confirmInstall: (_) async => true,
        );

        if (failure != null) {
          await expectLater(
            install,
            throwsA(
              failure == 'remove' || failure == 'rename'
                  ? isA<SftpStatusError>()
                  : isA<MonkeyMuxInstallException>(),
            ),
          );
          expect(remoteFileService.uploadedBytes, assetBytes);
          expect(renames, hasLength(failure == 'final-checksum' ? 1 : 0));
          if (failure != 'final-checksum') {
            verify(
              () => sftp.remove(remoteFileService.uploadedPath!),
            ).called(1);
          }
          if (failure == 'checksum') {
            verifyNever(
              () => sftp.remove(any(that: endsWith('monkeymux.exe'))),
            );
          }
          expect(
            commands.any((command) => command.contains('powershell')),
            isFalse,
          );
          return;
        }
        final installation = await install;
        expect(installation.platform, 'windows-amd64');
        expect(installation.isWindows, isTrue);
        expect(
          installation.executablePath,
          r'C:\Users\proof’s\.monkeyssh\bin\monkeymux\9.9.9\windows-amd64\'
          '$expectedSha\\monkeymux.exe',
        );
        expect(installation.installedDuringCall, isTrue);
        expect(remoteFileService.uploadCount, 1);
        expect(renames, hasLength(1));
        expect(
          renames.single.$2,
          '/C:/Users/proof’s/.monkeyssh/bin/monkeymux/9.9.9/windows-amd64/'
          '$expectedSha/monkeymux.exe',
        );
        final launcherCommand = commands.singleWhere(
          (command) =>
              command.contains('powershell -NoProfile -NonInteractive'),
        );
        final launcherScript = decodeEncodedPowerShell(launcherCommand);
        for (final matcher in [
          contains(r'.local\bin\monkeymux.cmd'),
          contains(r"'C:\Users\proof’’s\.local\bin\monkeymux.cmd'"),
          contains(r"'C:\Users\proof’’s\.local\bin\.monkeymux-current'"),
          contains('%~dp0.monkeymux-current'),
          contains(r'%~dp0..\..\.monkeyssh\bin\monkeymux'),
          isNot(contains('%USERPROFILE%')),
          contains('9.9.9\\windows-amd64\\$expectedSha\\monkeymux.exe'),
          contains('[System.IO.File]::Replace'),
          contains(r'$exists = Test-Path -LiteralPath $path'),
          contains(r'if ($exists -and $first -ne $managedMarker)'),
          isNot(contains(r'if ($null -eq $first)')),
        ]) {
          expect(launcherScript, matcher);
        }
        expect(
          launcherScript.indexOf(r'-Destination $pointer'),
          lessThan(launcherScript.indexOf(r'-Destination $path')),
        );
        expect(launcherScript, isNot(contains('Copy-Item')));
      },
    );
  }
}

class _InstallHarness {
  _InstallHarness({
    String? encoding,
    _FakeRemoteFileService? remote,
    bool windows = false,
    Map<String, Uint8List>? assets,
  }) : remote = remote ?? _FakeRemoteFileService() {
    bundle = _FakeAssetBundle(
      assets ??
          {
            'assets/test/monkeymux': switch (encoding) {
              'gzip' => Uint8List.fromList(gzip.encode(binary)),
              'gzip-mismatch' => Uint8List.fromList(gzip.encode([0])),
              // A single byte can decode to an empty buffer without a format error.
              'invalid-gzip' => Uint8List.fromList(
                utf8.encode('not a gzip archive'),
              ),
              _ => binary,
            },
          },
    );
    installer = MonkeyMuxInstallerService(
      manifestFuture: Future.value(
        MonkeyMuxManifest(
          version: '9.9.9',
          entries: [
            MonkeyMuxManifestEntry(
              platform: windows ? 'windows-amd64' : 'darwin-arm64',
              asset: 'assets/test/monkeymux',
              encoding: (encoding?.contains('gzip') ?? false)
                  ? 'gzip'
                  : encoding,
              sha256: digest,
              size: binary.length,
            ),
          ],
        ),
      ),
      remoteFileService: this.remote,
      assetBundle: bundle,
    );
    if (windows) {
      when(
        () => client.remoteVersion,
      ).thenReturn('SSH-2.0-OpenSSH_for_Windows_9.5');
    }
    addTearDown(dispose);
    when(sftp.close).thenAnswer((_) async {});
    when(() => sftp.remove(any())).thenAnswer((_) async {});
    when(client.sftp).thenAnswer((_) async => sftp);
    when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
      invocation,
    ) async {
      final command = invocation.positionalArguments.single as String;
      commands.add(command);
      return _execSession(
        command.contains('mv -f') && finalize != null
            ? await finalize!(command)
            : _outputForCommand(
                command,
                expectedSha: digest,
                remoteFileService: this.remote,
              ),
      );
    });
    session = SshSession(
      connectionId: _nextConnectionId++,
      hostId: 1,
      client: client,
      config: const SshConnectionConfig(
        hostname: 'example.com',
        port: 22,
        username: 'proof',
      ),
    );
  }

  static int _nextConnectionId = 800000;
  final binary = Uint8List.fromList(utf8.encode('monkeymux-binary'));
  String get digest => sha256.convert(binary).toString();
  final _FakeRemoteFileService remote;
  final client = _MockSshClient();
  final sftp = _MockSftpClient();
  final commands = <String>[];
  Future<String> Function(String)? finalize;
  late final _FakeAssetBundle bundle;
  late final MonkeyMuxInstallerService installer;
  late final SshSession session;

  void dispose() => installer.clearCache(session.connectionId);
}

/// Routes remote commands issued on a Windows host to canned raw output (the
/// Windows deploy path never uses the POSIX completion-marker wrapper).
String _windowsOutputForCommand(
  String command, {
  required String expectedSha,
  required _FakeRemoteFileService remoteFileService,
}) {
  if (command.contains('echo %OS%')) {
    return 'Windows_NT AMD64 \r\n';
  }
  if (command.contains('certutil')) {
    final digest = remoteFileService.uploaded ? expectedSha : '';
    return 'SHA256 hash of file:\r\n$digest\r\n'
        'CertUtil: -hashfile command completed successfully.\r\n';
  }
  if (command.contains('powershell -NoProfile -NonInteractive')) {
    return 'MONKEYMUX_LAUNCHER_MANAGED\r\n';
  }
  return '';
}

String _outputForCommand(
  String command, {
  required String expectedSha,
  required _FakeRemoteFileService remoteFileService,
}) {
  if (command.contains('uname -s')) {
    return _markedOutput('Darwin\narm64\n');
  }
  if (command.contains('sha256sum') || command.contains('shasum -a 256')) {
    return _markedOutput(remoteFileService.uploaded ? expectedSha : 'missing');
  }
  return _markedOutput('');
}

String _markedOutput(String output) => '$output\n__monkeymux_exec_done__:0\n';

SSHSession _execSession(String stdoutText) {
  final session = _MockSshSession();
  when(() => session.stdout).thenAnswer(
    (_) => Stream<Uint8List>.value(Uint8List.fromList(utf8.encode(stdoutText))),
  );
  when(() => session.stderr).thenAnswer((_) => const Stream<Uint8List>.empty());
  when(session.close).thenReturn(null);
  return session;
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition was not met before timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

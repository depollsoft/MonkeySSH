import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
// fake_async is supplied by flutter_test; dependency manifests are outside this job.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/screens/terminal/terminal_path_verifier.dart';

class _MockSshClient extends Mock implements SSHClient {}

class _MockSftpClient extends Mock implements SftpClient {
  _MockSftpClient() {
    when(close).thenAnswer((_) async {});
  }
}

void registerTerminalPathVerifierTests() {
  group('terminal path verification', () {
    test('path cache evicts oldest stores and retains reinserted paths', () {
      fakeAsync((async) {
        final sshClient = _MockSshClient();
        final session = SshSession(
          connectionId: 7,
          hostId: 1,
          client: sshClient,
          config: const SshConnectionConfig(
            hostname: 'terminal.example.com',
            port: 22,
            username: 'root',
          ),
        );
        var directory = '/project';
        var mounted = true;
        final verifier = TerminalPathVerifier(
          currentScope: () => '1:${session.connectionId}:$directory',
          workingDirectory: () => directory,
          activeSession: () => session,
          isMounted: () => mounted,
          onCacheChanged: () {},
          showMessage: (_) {},
          now: () => DateTime(2026).add(async.elapsed),
        );

        try {
          final sftp = _MockSftpClient();
          final calls = <String, int>{};
          when(sshClient.sftp).thenAnswer((_) async => sftp);
          when(() => sftp.stat(any())).thenAnswer((invocation) async {
            final path = invocation.positionalArguments.single as String;
            calls.update(path, (count) => count + 1, ifAbsent: () => 1);
            return SftpFileAttrs();
          });
          directory = '/project';
          async
            ..flushMicrotasks()
            ..elapse(const Duration(milliseconds: 100));
          void showPath(int index) {
            verifier.primeTerminalFilePathVerification('lib/file$index.txt');
            async
              ..flushMicrotasks()
              ..elapse(const Duration(milliseconds: 100))
              ..flushMicrotasks();
          }

          for (var index = 0; index <= 128; index++) {
            showPath(index);
          }
          expect(calls['/project/lib/file0.txt'], 1);
          showPath(0);
          expect(calls['/project/lib/file0.txt'], 2);
          showPath(129);
          showPath(0);
          expect(calls['/project/lib/file0.txt'], 2);
          showPath(2);
          expect(calls['/project/lib/file2.txt'], 2);
          mounted = false;
          verifier
            ..cancelPendingBatch()
            ..disposeTerminalPathVerificationSftp();
          async.flushMicrotasks();
        } finally {
          mounted = false;
          verifier
            ..cancelPendingBatch()
            ..disposeTerminalPathVerificationSftp();
        }
      });
    });

    test(
      'path batch stops using its SFTP client after session replacement',
      () {
        fakeAsync((async) {
          final sshClient = _MockSshClient();
          var session = SshSession(
            connectionId: 7,
            hostId: 1,
            client: sshClient,
            config: const SshConnectionConfig(
              hostname: 'terminal.example.com',
              port: 22,
              username: 'root',
            ),
          );
          var directory = '/project';
          var mounted = true;
          final verifier = TerminalPathVerifier(
            currentScope: () => '1:${session.connectionId}:$directory',
            workingDirectory: () => directory,
            activeSession: () => session,
            isMounted: () => mounted,
            onCacheChanged: () {},
            showMessage: (_) {},
            now: () => DateTime(2026).add(async.elapsed),
          );

          try {
            final sftp = _MockSftpClient();
            final stat = Completer<SftpFileAttrs>();
            when(sshClient.sftp).thenAnswer((_) async => sftp);
            when(() => sftp.stat('/project/lib/first.txt'))
                .thenAnswer((_) => stat.future);
            when(() => sftp.stat('/project/lib/second.txt'))
                .thenAnswer((_) async => SftpFileAttrs());
            directory = '/project';
            async
              ..flushMicrotasks()
              ..elapse(const Duration(milliseconds: 100));
            verifier
              ..primeTerminalFilePathVerification('lib/first.txt')
              ..primeTerminalFilePathVerification('lib/second.txt');
            async
              ..flushMicrotasks()
              ..elapse(const Duration(milliseconds: 75));
            verify(() => sftp.stat('/project/lib/first.txt')).called(1);
            session = SshSession(
              connectionId: session.connectionId,
              hostId: 1,
              client: _MockSshClient(),
              config: session.config,
            )..getOrCreateTerminal();
            stat.complete(SftpFileAttrs());
            async.flushMicrotasks();
            verifyNever(() => sftp.stat('/project/lib/second.txt'));
            mounted = false;
            verifier
              ..cancelPendingBatch()
              ..disposeTerminalPathVerificationSftp();
            async.flushMicrotasks();
          } finally {
            mounted = false;
            verifier
              ..cancelPendingBatch()
              ..disposeTerminalPathVerificationSftp();
          }
        });
      },
    );

    for (final pendingHome in [false, true]) {
      test(
        'path verification discards a directory change during ${pendingHome ? 'home lookup' : 'stat'}',
        () {
          fakeAsync((async) {
            final sshClient = _MockSshClient();
            final session = SshSession(
              connectionId: 7,
              hostId: 1,
              client: sshClient,
              config: const SshConnectionConfig(
                hostname: 'terminal.example.com',
                port: 22,
                username: 'root',
              ),
            );
            var directory = '/project';
            var mounted = true;
            final verifier = TerminalPathVerifier(
              currentScope: () => '1:${session.connectionId}:$directory',
              workingDirectory: () => directory,
              activeSession: () => session,
              isMounted: () => mounted,
              onCacheChanged: () {},
              showMessage: (_) {},
              now: () => DateTime(2026).add(async.elapsed),
            );

            try {
              final sftp = _MockSftpClient();
              final home = Completer<String>();
              final stat = Completer<SftpFileAttrs>();
              const oldDirectory = '/old/project';
              const newDirectory = '/new/project';
              final terminalPath = pendingHome
                  ? '~/notes.txt'
                  : 'lib/notes.txt';
              final statPaths = <String>[];
              var homeCalls = 0;
              when(sshClient.sftp).thenAnswer((_) async => sftp);
              when(() => sftp.absolute('.')).thenAnswer((_) {
                homeCalls++;
                return homeCalls == 1 ? home.future : Future.value('/new/home');
              });
              when(() => sftp.stat(any())).thenAnswer((invocation) {
                final path = invocation.positionalArguments.single as String;
                statPaths.add(path);
                return path.startsWith(oldDirectory)
                    ? stat.future
                    : Future.value(SftpFileAttrs());
              });
              directory = oldDirectory;
              async
                ..flushMicrotasks()
                ..elapse(const Duration(milliseconds: 100));
              verifier.primeTerminalFilePathVerification(terminalPath);
              async
                ..flushMicrotasks()
                ..elapse(const Duration(milliseconds: 75));
              expect(pendingHome ? homeCalls : statPaths.length, 1);
              directory = newDirectory;
              async.flushMicrotasks();
              if (pendingHome) {
                home.complete('/old/home');
              } else {
                stat.complete(SftpFileAttrs());
              }
              async
                ..flushMicrotasks()
                ..elapse(const Duration(milliseconds: 100));
              expect(statPaths, isNot(contains('/old/home/notes.txt')));
              verifier.primeTerminalFilePathVerification(terminalPath);
              async
                ..flushMicrotasks()
                ..elapse(const Duration(milliseconds: 100));
              expect(
                statPaths,
                contains(
                  pendingHome
                      ? '/new/home/notes.txt'
                      : '$newDirectory/lib/notes.txt',
                ),
              );
              mounted = false;
              verifier
                ..cancelPendingBatch()
                ..disposeTerminalPathVerificationSftp();
              async.flushMicrotasks();
            } finally {
              mounted = false;
              verifier
                ..cancelPendingBatch()
                ..disposeTerminalPathVerificationSftp();
            }
          });
        },
      );
    }

    for (final overflow in [false, true]) {
      test(
        'background path verification batches relative path stats with overflow $overflow',
        () {
          fakeAsync((async) {
            final sshClient = _MockSshClient();
            final session = SshSession(
              connectionId: 7,
              hostId: 1,
              client: sshClient,
              config: const SshConnectionConfig(
                hostname: 'terminal.example.com',
                port: 22,
                username: 'root',
              ),
            );
            var directory = '/project';
            var mounted = true;
            final verifier = TerminalPathVerifier(
              currentScope: () => '1:${session.connectionId}:$directory',
              workingDirectory: () => directory,
              activeSession: () => session,
              isMounted: () => mounted,
              onCacheChanged: () {},
              showMessage: (_) {},
              now: () => DateTime(2026).add(async.elapsed),
            );
            T complete<T>(Future<T> future) {
              late T result;
              var done = false;
              future.then((value) {
                result = value;
                done = true;
              });
              async.flushMicrotasks();
              expect(done, isTrue);
              return result;
            }

            try {
              const firstPath = 'lib/presentation/screens/terminal_screen.dart';
              const secondPath = 'lib/domain/services/tmux_service.dart';
              const workingDirectory = '/Users/tester/project';
              final sftp = _MockSftpClient();
              final firstStatStarted = Completer<void>();
              final firstStatCompleter = Completer<SftpFileAttrs>();
              var secondStatCalls = 0;
              final recentStats = <String>[];
              when(sshClient.sftp).thenAnswer((_) async => sftp);
              when(() => sftp.stat(any())).thenAnswer((call) {
                final path = call.positionalArguments.single as String;
                if (path == '$workingDirectory/$firstPath') {
                  if (!firstStatStarted.isCompleted) {
                    firstStatStarted.complete();
                  }
                  return firstStatCompleter.future;
                }
                if (path == '$workingDirectory/$secondPath') {
                  secondStatCalls++;
                } else {
                  recentStats.add(path);
                }
                return Future.value(SftpFileAttrs());
              });
              directory = workingDirectory;
              async
                ..flushMicrotasks()
                ..elapse(const Duration(milliseconds: 100));
              verifier
                ..primeTerminalFilePathVerification(firstPath)
                ..primeTerminalFilePathVerification(secondPath);
              async
                ..flushMicrotasks()
                ..elapse(const Duration(milliseconds: 75));
              complete(
                firstStatStarted.future.timeout(const Duration(seconds: 1)),
              );
              expect(secondStatCalls, 0);
              if (overflow) {
                for (var index = 0; index < 160; index++) {
                  verifier.primeTerminalFilePathVerification(
                    'lib/recent$index.txt',
                  );
                  async
                    ..flushMicrotasks()
                    ..elapse(const Duration(milliseconds: 16));
                }
                expect(recentStats, isEmpty);
              }
              firstStatCompleter.complete(SftpFileAttrs());
              async
                ..flushMicrotasks()
                ..elapse(const Duration(milliseconds: 100));
              verify(() => sftp.stat('$workingDirectory/$firstPath')).called(1);
              if (overflow) {
                expect(secondStatCalls, 0);
                expect(recentStats, hasLength(128));
                expect(recentStats.first, '$workingDirectory/lib/recent32.txt');
                expect(recentStats.last, '$workingDirectory/lib/recent159.txt');
                return;
              }
              verify(sshClient.sftp).called(1);
              verify(() => sftp.stat('$workingDirectory/$secondPath'))
                  .called(1);
            } finally {
              mounted = false;
              verifier
                ..cancelPendingBatch()
                ..disposeTerminalPathVerificationSftp();
            }
          });
        },
      );
    }

    for (final failure in [
      'synchronous open',
      'asynchronous open',
      'recoverable open',
      'recoverable stat',
    ]) {
      test(
        'background path verification stops retrying after $failure failure',
        () {
          fakeAsync((async) {
            final sshClient = _MockSshClient();
            final session = SshSession(
              connectionId: 7,
              hostId: 1,
              client: sshClient,
              config: const SshConnectionConfig(
                hostname: 'terminal.example.com',
                port: 22,
                username: 'root',
              ),
            );
            var directory = '/project';
            var mounted = true;
            final verifier = TerminalPathVerifier(
              currentScope: () => '1:${session.connectionId}:$directory',
              workingDirectory: () => directory,
              activeSession: () => session,
              isMounted: () => mounted,
              onCacheChanged: () {},
              showMessage: (_) {},
              now: () => DateTime(2026).add(async.elapsed),
            );

            try {
              final sftp = _MockSftpClient();
              var openCalls = 0;
              var statCalls = 0;
              when(sshClient.sftp).thenAnswer((_) {
                openCalls++;
                if (failure == 'synchronous open') {
                  throw StateError('SFTP unavailable');
                }
                if (failure != 'recoverable stat') {
                  return Future.error(
                    failure == 'asynchronous open'
                        ? StateError('SFTP unavailable')
                        : SSHStateError('SFTP unavailable'),
                  );
                }
                return Future.value(sftp);
              });
              when(() => sftp.stat(any())).thenAnswer((_) {
                statCalls++;
                return Future.error(SSHStateError('SFTP unavailable'));
              });
              directory = '/project';
              async
                ..flushMicrotasks()
                ..elapse(const Duration(milliseconds: 100));
              final timers = <Timer>[];
              runZoned(
                () {
                  verifier
                    ..primeTerminalFilePathVerification('lib/first.txt')
                    ..primeTerminalFilePathVerification('lib/second.txt');
                  async
                    ..flushMicrotasks()
                    ..elapse(const Duration(milliseconds: 75));
                  expect(openCalls, 1);
                  expect(statCalls, failure == 'recoverable stat' ? 1 : 0);
                  for (var tick = 0; tick < 4; tick++) {
                    async.elapse(const Duration(seconds: 11));
                  }
                  expect(openCalls, 1);
                  expect(statCalls, failure == 'recoverable stat' ? 1 : 0);
                  expect(
                    timers.where((timer) => timer.isActive),
                    isEmpty,
                    reason:
                        'Idle verification must leave no retry timer pending',
                  );
                },
                zoneSpecification: ZoneSpecification(
                  createTimer: (self, parent, zone, duration, callback) {
                    final timer = parent.createTimer(zone, duration, callback);
                    timers.add(timer);
                    return timer;
                  },
                ),
              );
              if (!failure.startsWith('recoverable')) {
                // New output must retry paths whose batch failed.
                final recoveredPaths = <String>[];
                when(sshClient.sftp).thenAnswer((_) async => sftp);
                when(() => sftp.stat(any())).thenAnswer((invocation) async {
                  recoveredPaths.add(
                    invocation.positionalArguments.single as String,
                  );
                  return SftpFileAttrs();
                });
                // Separate commands so continuation detection cannot join the
                // previous path with the next command's name.
                verifier
                  ..primeTerminalFilePathVerification('lib/first.txt')
                  ..primeTerminalFilePathVerification('lib/second.txt');
                async
                  ..flushMicrotasks()
                  ..elapse(const Duration(milliseconds: 75));
                expect(recoveredPaths, [
                  '/project/lib/first.txt',
                  '/project/lib/second.txt',
                ]);
              }
              mounted = false;
              verifier
                ..cancelPendingBatch()
                ..disposeTerminalPathVerificationSftp();
              async.flushMicrotasks();
            } finally {
              mounted = false;
              verifier
                ..cancelPendingBatch()
                ..disposeTerminalPathVerificationSftp();
            }
          });
        },
      );
    }

    test(
      'background path verification preserves replacement after open timeout',
      () {
        fakeAsync((async) {
          final sshClient = _MockSshClient();
          final session = SshSession(
            connectionId: 7,
            hostId: 1,
            client: sshClient,
            config: const SshConnectionConfig(
              hostname: 'terminal.example.com',
              port: 22,
              username: 'root',
            ),
          );
          var directory = '/project';
          var mounted = true;
          final verifier = TerminalPathVerifier(
            currentScope: () => '1:${session.connectionId}:$directory',
            workingDirectory: () => directory,
            activeSession: () => session,
            isMounted: () => mounted,
            onCacheChanged: () {},
            showMessage: (_) {},
            now: () => DateTime(2026).add(async.elapsed),
          );
          T complete<T>(Future<T> future) {
            late T result;
            var done = false;
            future.then((value) {
              result = value;
              done = true;
            });
            async.flushMicrotasks();
            expect(done, isTrue);
            return result;
          }

          try {
            const relativePath =
                'lib/presentation/screens/terminal_screen.dart';
            const workingDirectory = '/Users/tester/project';
            final sftp = _MockSftpClient();
            final sftpOpenCompleter = Completer<SftpClient>();

            when(sshClient.sftp).thenAnswer((_) => sftpOpenCompleter.future);
            directory = workingDirectory;
            async
              ..flushMicrotasks()
              ..elapse(const Duration(milliseconds: 100));

            verifier.primeTerminalFilePathVerification(relativePath);
            async
              ..flushMicrotasks()
              ..elapse(const Duration(milliseconds: 75));
            verify(sshClient.sftp).called(1);

            async.elapse(const Duration(seconds: 5, milliseconds: 1));
            verifyNever(sftp.close);

            // The real terminal timeout handler must release the pending open
            // immediately, so another consumer can recover before it finishes.
            final replacement = _MockSftpClient();
            when(sshClient.sftp).thenAnswer((_) async => replacement);
            final next = session.sftp();
            async.flushMicrotasks();
            verify(sshClient.sftp).called(1);
            expect(complete(next), same(replacement));

            sftpOpenCompleter.complete(sftp);
            async.flushMicrotasks();

            verify(sftp.close).called(1);
            verifyNever(replacement.close);
            expect(complete(session.sftp()), same(replacement));
            verifyNever(sshClient.sftp);

            mounted = false;
            verifier
              ..cancelPendingBatch()
              ..disposeTerminalPathVerificationSftp();
            async.elapse(const Duration(seconds: 11));
          } finally {
            mounted = false;
            verifier
              ..cancelPendingBatch()
              ..disposeTerminalPathVerificationSftp();
          }
        });
      },
    );

    test('background path verification discards cached SFTP clients after stat timeout', () {
      fakeAsync((async) {
        final sshClient = _MockSshClient();
        final session = SshSession(
          connectionId: 7,
          hostId: 1,
          client: sshClient,
          config: const SshConnectionConfig(
            hostname: 'terminal.example.com',
            port: 22,
            username: 'root',
          ),
        );
        var directory = '/project';
        var mounted = true;
        final verifier = TerminalPathVerifier(
          currentScope: () => '1:${session.connectionId}:$directory',
          workingDirectory: () => directory,
          activeSession: () => session,
          isMounted: () => mounted,
          onCacheChanged: () {},
          showMessage: (_) {},
          now: () => DateTime(2026).add(async.elapsed),
        );
        T complete<T>(Future<T> future) {
          late T result;
          var done = false;
          future.then((value) {
            result = value;
            done = true;
          });
          async.flushMicrotasks();
          expect(done, isTrue);
          return result;
        }

        try {
          const relativePath = 'lib/presentation/screens/terminal_screen.dart';
          const workingDirectory = '/Users/tester/project';
          final sftp = _MockSftpClient();
          final statStarted = Completer<void>();
          final statCompleter = Completer<SftpFileAttrs>();

          when(sshClient.sftp).thenAnswer((_) async => sftp);
          when(() => sftp.stat('$workingDirectory/$relativePath'))
              .thenAnswer((_) {
                if (!statStarted.isCompleted) {
                  statStarted.complete();
                }
                return statCompleter.future;
              });
          directory = workingDirectory;
          async
            ..flushMicrotasks()
            ..elapse(const Duration(milliseconds: 100));

          verifier.primeTerminalFilePathVerification(relativePath);
          async
            ..flushMicrotasks()
            ..elapse(const Duration(milliseconds: 75));
          complete(statStarted.future.timeout(const Duration(seconds: 1)));

          async.elapse(const Duration(seconds: 5, milliseconds: 1));

          verify(sftp.close).called(1);

          mounted = false;
          verifier
            ..cancelPendingBatch()
            ..disposeTerminalPathVerificationSftp();
          async.elapse(const Duration(seconds: 11));
        } finally {
          mounted = false;
          verifier
            ..cancelPendingBatch()
            ..disposeTerminalPathVerificationSftp();
        }
      });
    });
  });
}

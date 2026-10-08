// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/services/ssh_exec_queue.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/widgets/acp_connection_support.dart';

import '../../helpers/mock_ssh_exec_session.dart';
import '../../helpers/mocks.dart';
import '../../helpers/powershell_test_helpers.dart';

class _MockExecChannel extends MockSessionWithChannel {}

void registerAcpConnectionSupportTests() {
  group('acp_connection_support', () {
    tearDown(resetQueuedSshExecsForTesting);
    for (final windows in [false, true]) {
      for (final executable in ['opencode2', 'opencode', 'open-code']) {
        test(
          'OpenCode sign-in uses cached launch probe: windows=$windows executable=$executable',
          () async {
            final client = MockSshClient();
            when(() => client.remoteVersion).thenReturn(
              windows
                  ? 'SSH-2.0-OpenSSH_for_Windows_9.5'
                  : 'SSH-2.0-OpenSSH_9.6',
            );
            final prefix = windows ? 'C:/tools' : '/opt/tools';
            var probes = 0;
            when(
              () => client.execute(any(), pty: any(named: 'pty')),
            ).thenAnswer((_) async {
              probes++;
              final channel = MockSSHSession();
              final output =
                  '$executable\u001f$prefix/$executable\n'
                  '${executable == 'opencode2' ? 'opencode\u001f$prefix/opencode\n' : ''}';
              when(() => channel.stdout).thenAnswer(
                (_) => Stream<Uint8List>.value(
                  Uint8List.fromList(utf8.encode(output)),
                ),
              );
              when(() => channel.stderr)
                  .thenAnswer((_) => const Stream<Uint8List>.empty());
              when(() => channel.done).thenAnswer((_) async {});
              when(() => channel.exitCode).thenReturn(0);
              when(channel.close).thenReturn(null);
              return channel;
            });
            final session = SshSession(
              connectionId: 92,
              hostId: 3,
              client: client,
              config: const SshConnectionConfig(
                hostname: 'example.test',
                port: 22,
                username: 'dev',
              ),
            );
            await prewarmAcpRemoteExecutables(session);
            final command = await resolveAcpTerminalAuthCommand(
              providerId: AcpBuiltinProviderIds.openCode,
              session: session,
            );
            expect(command?.argv, [executable, 'auth', 'login']);
            expect(probes, 1);
          },
        );
      }
    }
    for (final (providerId, installed, expectedArgv) in [
      (
        AcpBuiltinProviderIds.copilotCli,
        'github-copilot',
        ['github-copilot', 'login'],
      ),
      (AcpBuiltinProviderIds.copilotCli, 'copilot', ['copilot', 'login']),
      (AcpBuiltinProviderIds.hermes, 'hermes-agent', ['hermes-agent']),
      // A provider whose sign-in executable is not a probe candidate keeps
      // its declared command even when the probe finds nothing.
      (
        AcpBuiltinProviderIds.claudeAgent,
        'claude-agent-acp',
        ['claude', '/login'],
      ),
    ]) {
      test('terminal sign-in substitutes the installed probe candidate: '
          '$providerId installed=$installed', () async {
        final client = MockSshClient();
        when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.6');
        when(() => client.execute(any(), pty: any(named: 'pty')))
            .thenAnswer((_) async {
              final channel = _MockExecChannel();
              when(() => channel.stdout).thenAnswer(
                (_) => Stream<Uint8List>.value(
                  Uint8List.fromList(
                    utf8.encode('$installed\u001f/opt/tools/$installed\n'),
                  ),
                ),
              );
              when(() => channel.stderr)
                  .thenAnswer((_) => const Stream<Uint8List>.empty());
              when(() => channel.done).thenAnswer((_) async {});
              when(() => channel.exitCode).thenReturn(0);
              when(channel.close).thenReturn(null);
              return channel;
            });
        final session = SshSession(
          connectionId: 93,
          hostId: 3,
          client: client,
          config: const SshConnectionConfig(
            hostname: 'example.test',
            port: 22,
            username: 'dev',
          ),
        );
        final command = await resolveAcpTerminalAuthCommand(
          providerId: providerId,
          session: session,
        );
        expect(command?.argv, expectedArgv);
      });
    }
    for (final windows in [false, true]) {
      for (final installedAdapter in [false, true]) {
        for (final installedMuse in [false, true]) {
          testWidgets(
            'Muse launch requires CLI: windows=$windows adapter=$installedAdapter muse=$installedMuse',
            (tester) async {
              final client = MockSshClient();
              when(() => client.remoteVersion).thenReturn(
                windows
                    ? 'SSH-2.0-OpenSSH_for_Windows_9.5'
                    : 'SSH-2.0-OpenSSH_9.6',
              );
              final prefix = windows ? 'C:/tools' : '/opt/tools';
              when(() => client.execute(any(), pty: any(named: 'pty')))
                  .thenAnswer((_) async {
                    final channel = MockSSHSession();
                    final output = [
                      'npx\u001f$prefix/npx',
                      if (installedAdapter)
                        'muse-code-acp\u001f$prefix/muse-code-acp',
                      if (installedMuse) 'muse\u001f$prefix/muse',
                    ].join('\n');
                    when(() => channel.stdout).thenAnswer(
                      (_) => Stream<Uint8List>.value(
                        Uint8List.fromList(utf8.encode(output)),
                      ),
                    );
                    when(() => channel.stderr)
                        .thenAnswer((_) => const Stream<Uint8List>.empty());
                    when(() => channel.done).thenAnswer((_) async {});
                    when(() => channel.exitCode).thenReturn(0);
                    when(channel.close).thenReturn(null);
                    return channel;
                  });
              final session = SshSession(
                connectionId: 1,
                hostId: 1,
                client: client,
                config: const SshConnectionConfig(
                  hostname: 'example.test',
                  port: 22,
                  username: 'dev',
                ),
              );
              ({AcpLaunchCommand? override, bool terminal})? result;
              var completed = false;
              await tester.pumpWidget(
                MaterialApp(
                  home: Builder(
                    builder: (context) => Scaffold(
                      body: TextButton(
                        onPressed: () async {
                          result = await resolveAcpRemoteProviderLaunch(
                            context: context,
                            session: session,
                            provider: acpMuseCodeProvider,
                            canUseTerminalCli: true,
                          );
                          completed = true;
                        },
                        child: const Text('Launch'),
                      ),
                    ),
                  ),
                ),
              );
              await tester.tap(find.text('Launch'));
              await tester.pumpAndSettle();
              if (!installedMuse) {
                expect(find.text('Muse Code unavailable'), findsOneWidget);
                expect(find.textContaining('Install muse'), findsOneWidget);
                expect(find.text('Run adapter'), findsNothing);
                expect(find.text('Use terminal CLI'), findsNothing);
                await tester.tap(find.text('OK'));
                await tester.pumpAndSettle();
                expect(completed, isTrue);
                expect(result, isNull);
              } else {
                if (!installedAdapter) {
                  expect(find.text('Run adapter'), findsOneWidget);
                  await tester.tap(find.text('Run adapter'));
                  await tester.pumpAndSettle();
                }
                expect(completed, isTrue);
                expect(result!.terminal, isFalse);
                expect(
                  result!.override!.argv,
                  installedAdapter
                      ? ['$prefix/muse-code-acp']
                      : ['$prefix/npx', '--yes', '@bex-co/muse-code-acp@0.6.0'],
                );
              }
            },
          );
        }
      }
    }

    for (final windows in [false, true]) {
      for (final (verdict, choice) in [
        ('0', 'Copy command'),
        ('0', 'Use terminal CLI'),
        ('ready', null),
      ]) {
        testWidgets('Hermes launch checks ACP support: windows=$windows '
            'verdict=$verdict choice=$choice', (tester) async {
          final client = MockSshClient();
          when(() => client.remoteVersion).thenReturn(
            windows ? 'SSH-2.0-OpenSSH_for_Windows_9.5' : 'SSH-2.0-OpenSSH_9.6',
          );
          final prefix = windows ? 'C:/tools' : '/opt/tools';
          var checks = 0;
          when(() => client.execute(any(), pty: any(named: 'pty')))
              .thenAnswer((invocation) async {
                final command = decodeEncodedPowerShell(
                  invocation.positionalArguments.single as String,
                );
                final String output;
                if (command.contains('__monkeyssh_acp_support__')) {
                  checks++;
                  output = '__monkeyssh_acp_support__=$verdict\n';
                } else if (command.contains('hermes-agent')) {
                  output = 'hermes\u001f$prefix/hermes\n';
                } else {
                  // Profile discovery: no profiles, so no picker.
                  output = '';
                }
                final channel = MockSSHSession();
                when(() => channel.stdout).thenAnswer(
                  (_) => Stream<Uint8List>.value(
                    Uint8List.fromList(utf8.encode(output)),
                  ),
                );
                when(() => channel.stderr)
                    .thenAnswer((_) => const Stream<Uint8List>.empty());
                when(() => channel.done).thenAnswer((_) async {});
                when(() => channel.exitCode).thenReturn(0);
                when(channel.close).thenReturn(null);
                return channel;
              });
          String? copied;
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async {
              if (call.method == 'Clipboard.setData') {
                copied = (call.arguments as Map)['text'] as String?;
              }
              return null;
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );
          final session = SshSession(
            connectionId: 94,
            hostId: 3,
            client: client,
            config: const SshConnectionConfig(
              hostname: 'example.test',
              port: 22,
              username: 'dev',
            ),
          );
          final results = <({AcpLaunchCommand? override, bool terminal})?>[];
          await tester.pumpWidget(
            MaterialApp(
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () async => results.add(
                      await resolveAcpRemoteProviderLaunch(
                        context: context,
                        session: session,
                        provider: acpHermesProvider,
                        canUseTerminalCli: true,
                      ),
                    ),
                    child: const Text('Launch'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Launch'));
          await tester.pumpAndSettle();

          if (choice == null) {
            expect(find.text('Hermes needs ACP support'), findsNothing);
            expect(results.single!.override!.argv, [
              '$prefix/hermes',
              '--profile',
              'default',
              'acp',
            ]);
            // A passing check is remembered for the session.
            await tester.tap(find.text('Launch'));
            await tester.pumpAndSettle();
            expect(results, hasLength(2));
            expect(checks, 1);
            return;
          }
          expect(find.text('Hermes needs ACP support'), findsOneWidget);
          expect(
            find.text("pipx install --force 'hermes-agent[acp]'"),
            findsOneWidget,
          );
          await tester.tap(find.text(choice));
          await tester.pumpAndSettle();
          if (choice == 'Copy command') {
            expect(copied, "pipx install --force 'hermes-agent[acp]'");
            expect(results.single, isNull);
          } else {
            expect(copied, isNull);
            expect(results.single, (override: null, terminal: true));
          }
        });
      }
    }

    testWidgets('a hung Hermes ACP check frees its channel and launches', (
      tester,
    ) async {
      final client = MockSshClient();
      when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.6');
      final hungStdout = StreamController<Uint8List>();
      addTearDown(hungStdout.close);
      final hungDone = Completer<void>();
      _MockExecChannel? checkChannel;
      when(() => client.execute(any(), pty: any(named: 'pty')))
          .thenAnswer((invocation) async {
            final command = invocation.positionalArguments.single as String;
            final channel = _MockExecChannel();
            if (command.contains('__monkeyssh_acp_support__')) {
              checkChannel = channel;
              when(() => channel.stdout).thenAnswer((_) => hungStdout.stream);
              when(() => channel.done).thenAnswer((_) => hungDone.future);
            } else {
              final output = command.contains('hermes-agent')
                  ? 'hermes\u001f/opt/tools/hermes\n'
                  : '';
              when(() => channel.stdout).thenAnswer(
                (_) => Stream<Uint8List>.value(
                  Uint8List.fromList(utf8.encode(output)),
                ),
              );
              when(() => channel.done).thenAnswer((_) async {});
            }
            when(() => channel.stderr)
                .thenAnswer((_) => const Stream<Uint8List>.empty());
            when(() => channel.exitCode).thenReturn(0);
            when(channel.close).thenReturn(null);
            return channel;
          });
      final session = SshSession(
        connectionId: 95,
        hostId: 3,
        client: client,
        config: const SshConnectionConfig(
          hostname: 'example.test',
          port: 22,
          username: 'dev',
        ),
      );
      final results = <({AcpLaunchCommand? override, bool terminal})?>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => results.add(
                  await resolveAcpRemoteProviderLaunch(
                    context: context,
                    session: session,
                    provider: acpHermesProvider,
                    canUseTerminalCli: true,
                  ),
                ),
                child: const Text('Launch'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Launch'));
      await tester.pump();
      expect(checkChannel, isNotNull);
      expect(results, isEmpty);

      // The check times out, then the channel ignores EOF past the grace.
      await tester.pump(const Duration(seconds: 31));
      await tester.pump(abandonedSshExecCloseGrace);
      await tester.pumpAndSettle();

      verify(checkChannel!.channel.destroy).called(1);
      expect(find.text('Hermes needs ACP support'), findsNothing);
      expect(results.single!.override!.argv, [
        '/opt/tools/hermes',
        '--profile',
        'default',
        'acp',
      ]);
    });

    test('ACP executable prewarm is reused during the launch window', () async {
      final client = MockSshClient();
      final executedCommands = <String>[];
      when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.6');
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        invocation,
      ) async {
        executedCommands.add(invocation.positionalArguments.single as String);
        final channel = MockSSHSession();
        final output = [
          'cursor-agent\u001f/Users/demo/.local/bin/cursor-agent',
          'npx\u001f/opt/homebrew/bin/npx',
        ].join('\n');
        when(() => channel.stdout).thenAnswer(
          (_) =>
              Stream<Uint8List>.value(Uint8List.fromList(utf8.encode(output))),
        );
        when(() => channel.stderr)
            .thenAnswer((_) => const Stream<Uint8List>.empty());
        when(() => channel.done).thenAnswer((_) async {});
        when(() => channel.exitCode).thenReturn(0);
        when(channel.close).thenReturn(null);
        return channel;
      });
      final session = SshSession(
        connectionId: 91,
        hostId: 3,
        client: client,
        config: const SshConnectionConfig(
          hostname: 'example.test',
          port: 22,
          username: 'dev',
        ),
      );

      await prewarmAcpRemoteExecutables(session);
      await prewarmAcpRemoteExecutables(session);

      expect(executedCommands, hasLength(1));
      expect(executedCommands.single, contains('cursor-agent'));
      expect(executedCommands.single, contains('claude-agent-acp'));
      expect(executedCommands.single, contains('npx'));
    });
  });
}

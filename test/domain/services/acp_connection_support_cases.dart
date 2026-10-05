// ignore_for_file: public_member_api_docs

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/services/ssh_exec_queue.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/widgets/acp_connection_support.dart';

import '../../helpers/mocks.dart';

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
        final client = _MockSshClient();
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

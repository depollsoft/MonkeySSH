// ignore_for_file: public_member_api_docs

import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/services/ssh_exec_queue.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/widgets/acp_connection_support.dart';

class _MockSshClient extends Mock implements SSHClient {}

class _MockExecChannel extends Mock implements SSHSession {}

void registerAcpConnectionSupportTests() {
  group('acp_connection_support', () {
    tearDown(resetQueuedSshExecsForTesting);
    for (final windows in [false, true]) {
      for (final installedAdapter in [false, true]) {
        for (final installedMuse in [false, true]) {
          testWidgets(
            'Muse launch requires CLI: windows=$windows adapter=$installedAdapter muse=$installedMuse',
            (tester) async {
              final client = _MockSshClient();
              when(() => client.remoteVersion).thenReturn(
                windows
                    ? 'SSH-2.0-OpenSSH_for_Windows_9.5'
                    : 'SSH-2.0-OpenSSH_9.6',
              );
              final prefix = windows ? 'C:/tools' : '/opt/tools';
              when(() => client.execute(any(), pty: any(named: 'pty')))
                  .thenAnswer((_) async {
                    final channel = _MockExecChannel();
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
      final client = _MockSshClient();
      final executedCommands = <String>[];
      when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.6');
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        invocation,
      ) async {
        executedCommands.add(invocation.positionalArguments.single as String);
        final channel = _MockExecChannel();
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

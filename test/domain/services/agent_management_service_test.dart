// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/agent_runtime_info.dart';
import 'package:monkeyssh/domain/models/agent_usage.dart';
import 'package:monkeyssh/domain/services/agent_management_service.dart';
import 'package:monkeyssh/domain/services/agent_session_discovery_service.dart';
import 'package:monkeyssh/domain/services/ssh_exec_queue.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/domain/services/windows_remote_powershell.dart';

import '../../helpers/powershell_test_helpers.dart';

class _MockSshClient extends Mock implements SSHClient {}

class _MockExecSession extends Mock implements SSHSession {}

class _MockDiscovery extends Mock implements AgentSessionDiscoveryService {}

AgentManagementService _unlockedManagementService(
  AgentSessionDiscoveryService discovery,
) => AgentManagementService(discovery, canManageAgents: () async => true);

SSHSession _execOutput(String output, {int exitCode = 0}) {
  final exec = _MockExecSession();
  when(() => exec.stdout).thenAnswer(
    (_) => Stream<Uint8List>.value(Uint8List.fromList(utf8.encode(output))),
  );
  when(() => exec.stderr).thenAnswer((_) => const Stream.empty());
  when(() => exec.done).thenAnswer((_) async {});
  when(() => exec.exitCode).thenReturn(exitCode);
  when(exec.close).thenReturn(null);
  return exec;
}

SshSession _remoteSession(_MockSshClient client, {int connectionId = 77}) =>
    SshSession(
      connectionId: connectionId,
      hostId: 3,
      client: client,
      config: const SshConnectionConfig(
        hostname: 'agent.example.com',
        port: 22,
        username: 'dev',
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'all installed CLI agents request usage and partial failures can retry',
    () async {
      final client = _MockSshClient();
      final commands = <String>[];
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        invocation,
      ) async {
        commands.add(invocation.positionalArguments.first as String);
        return _execOutput(
          '__monkeyssh_usage__={"id":"pi","status":"available",'
          '"windows":[{"label":"Weekly","usedPercent":12}],'
          '"notices":[{"provider":"Anthropic","status":"signInRequired"}]}',
        );
      });
      final session = _remoteSession(client);
      final service = _unlockedManagementService(_MockDiscovery());
      final runtimes = [
        for (final definition in agentCliRuntimeDefinitions)
          AgentRuntimeInfo(
            definition: definition,
            status: AgentRuntimeStatus.installed,
            executablePath: '/bin/agent',
          ),
      ];
      final result = await service.readUsage(session, runtimes);
      final match = RegExp(
        r"'([A-Za-z0-9+/=]+)' 2>/dev/null$",
      ).firstMatch(commands.first)!;
      final requested =
          jsonDecode(utf8.decode(base64.decode(match[1]!))) as Map;
      expect(requested.keys.toSet(), {
        'claude',
        'codex',
        'copilot',
        'opencode',
        'antigravity',
        'cursor',
        'pi',
        'hermes',
        'openclaw',
        'grok',
      });
      expect(result['cli:pi']!.status, AgentUsageStatus.available);
      await service.readUsage(session, runtimes);
      expect(commands, hasLength(2));
    },
  );

  test(
    'Windows sends the probe through stdin within the command limit',
    () async {
      final client = _MockSshClient();
      when(
        () => client.remoteVersion,
      ).thenReturn('SSH-2.0-OpenSSH_for_Windows_9.5');
      final input = StreamController<Uint8List>();
      final received = <int>[];
      input.stream.listen(received.addAll);
      final exec =
          _execOutput(
                '__monkeyssh_usage__={"id":"grok","status":"notReported"}',
              )
              as _MockExecSession;
      when(() => exec.stdin).thenReturn(input.sink);
      String? command;
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        invocation,
      ) async {
        command = invocation.positionalArguments.first as String;
        return exec;
      });
      final service = _unlockedManagementService(_MockDiscovery());
      final definition = agentCliRuntimeDefinitions.firstWhere(
        (d) => d.id == 'cli:grok',
      );
      final result = await service.readUsage(_remoteSession(client), [
        AgentRuntimeInfo(
          definition: definition,
          status: AgentRuntimeStatus.installed,
          executablePath: r'C:\tools\grok.exe',
        ),
      ]);
      expect(command!.length, lessThan(7500));
      expect(
        decodeEncodedPowerShell(command!),
        contains("require(''readline'')"),
      );
      expect(
        utf8.decode(base64.decode(utf8.decode(received).trim())),
        contains('function grokUsage'),
      );
      expect(result['cli:grok']!.status, AgentUsageStatus.notReported);
      await input.close();
    },
  );

  test('partial quota snapshots respect provider throttling', () async {
    final client = _MockSshClient();
    var calls = 0;
    when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
      _,
    ) async {
      calls++;
      return _execOutput(
        '__monkeyssh_usage__={"id":"pi","status":"available",'
        '"windows":[{"label":"Weekly","usedPercent":12}],'
        '"notices":[{"provider":"Anthropic","status":"rateLimited"}]}',
      );
    });
    final service = _unlockedManagementService(_MockDiscovery());
    final session = _remoteSession(client);
    final runtimes = [
      AgentRuntimeInfo(
        definition: agentCliRuntimeDefinitions.firstWhere(
          (d) => d.id == 'cli:pi',
        ),
        status: AgentRuntimeStatus.installed,
        executablePath: '/bin/pi',
      ),
    ];
    await service.readUsage(session, runtimes);
    await service.readUsage(session, runtimes);
    expect(calls, 1);
  });
  test(
    'usage is gated and quota snapshots are shared and cached per connection',
    () async {
      var now = DateTime.utc(2026, 9, 10);
      final client = _MockSshClient();
      var calls = 0;
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        _,
      ) async {
        calls++;
        return _execOutput(
          '__monkeyssh_usage__={"id":"copilot","status":"available",'
          '"windows":[{"label":"Premium requests","usedPercent":42}]}',
        );
      });
      final session = _remoteSession(client);
      final runtimes = [
        for (final definition in [
          agentCliRuntimeDefinitions[1],
          agentAcpRuntimeDefinitions.first,
        ])
          AgentRuntimeInfo(
            definition: definition,
            status: AgentRuntimeStatus.installed,
            executablePath: '/usr/local/bin/copilot',
          ),
      ];
      final locked = AgentManagementService(
        _MockDiscovery(),
        canManageAgents: () async => false,
      );
      expect(await locked.readUsage(session, runtimes), isEmpty);
      expect(calls, 0);
      final service = AgentManagementService(
        _MockDiscovery(),
        canManageAgents: () async => true,
        now: () => now,
      );
      final concurrent = await Future.wait([
        service.readUsage(session, runtimes),
        service.readUsage(session, runtimes),
      ]);
      expect(calls, 1);
      final result = concurrent.first;
      expect(result['cli:copilot']!.status, AgentUsageStatus.available);
      expect(identical(result['cli:copilot'], result['acp:copilot']), isTrue);
      now = now.add(const Duration(minutes: 2));
      await service.readUsage(session, runtimes);
      expect(calls, 2);
      await service.readUsage(
        _remoteSession(client, connectionId: 78),
        runtimes,
      );
      expect(calls, 3);
    },
  );

  test(
    'failed usage checks retry immediately for every supported agent',
    () async {
      final client = _MockSshClient();
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenThrow(StateError('SECRET'));
      final session = _remoteSession(client);
      final runtimes = [
        for (final definition in [
          agentCliRuntimeDefinitions.first,
          agentCliRuntimeDefinitions.firstWhere((d) => d.id == 'cli:opencode'),
        ])
          AgentRuntimeInfo(
            definition: definition,
            status: AgentRuntimeStatus.installed,
            executablePath: '/bin/agent',
          ),
      ];
      final service = _unlockedManagementService(_MockDiscovery());
      final result = await service.readUsage(session, runtimes);
      expect(result['cli:claude']!.status, AgentUsageStatus.unavailable);
      expect(result['cli:opencode']!.status, AgentUsageStatus.unavailable);
      await service.readUsage(session, runtimes);
      verify(() => client.execute(any(), pty: any(named: 'pty'))).called(2);
    },
  );

  test(
    'retrying a failed provider preserves other provider cooldowns',
    () async {
      final client = _MockSshClient();
      final commands = <String>[];
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        invocation,
      ) async {
        commands.add(invocation.positionalArguments.first as String);
        return _execOutput(
          '__monkeyssh_usage__={"id":"claude","status":"rateLimited"}\n'
          '__monkeyssh_usage__={"id":"copilot","status":"signInRequired"}',
        );
      });
      final session = _remoteSession(client);
      final service = _unlockedManagementService(_MockDiscovery());
      final runtimes = [
        for (final definition in agentCliRuntimeDefinitions.take(2))
          AgentRuntimeInfo(
            definition: definition,
            status: AgentRuntimeStatus.installed,
            executablePath: '/bin/${definition.executableNames.first}',
          ),
      ];
      await service.readUsage(session, runtimes);
      await service.readUsage(session, runtimes);
      final input = RegExp(
        "'([A-Za-z0-9+/=]+)' 2>/dev/null",
      ).firstMatch(commands.last)!.group(1)!;
      final requested =
          jsonDecode(utf8.decode(base64.decode(input))) as Map<String, dynamic>;
      expect(requested.keys, ['copilot']);
    },
  );

  test('a newly passed reset bypasses the usage cooldown once', () async {
    var now = DateTime.utc(2026, 9, 10, 12);
    final client = _MockSshClient();
    var calls = 0;
    when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
      _,
    ) async {
      calls++;
      return _execOutput(
        '__monkeyssh_usage__={"id":"claude","status":"available",'
        '"windows":[{"label":"5 hours","usedPercent":100,"resetsAt":"2026-09-10T12:01:00Z"}]}',
      );
    });
    final session = _remoteSession(client);
    final service = AgentManagementService(
      _MockDiscovery(),
      canManageAgents: () async => true,
      now: () => now,
    );
    final runtimes = [
      AgentRuntimeInfo(
        definition: agentCliRuntimeDefinitions.first,
        status: AgentRuntimeStatus.installed,
        executablePath: '/bin/claude',
      ),
    ];
    await service.readUsage(session, runtimes);
    now = now.add(const Duration(minutes: 1));
    await service.readUsage(session, runtimes);
    await service.readUsage(session, runtimes);
    expect(calls, 2);
  });

  testWidgets('stalled probe open fails and releases its queue slot', (
    tester,
  ) async {
    final opening = Completer<SSHSession>();
    final client = _MockSshClient();
    when(
      () => client.execute(any(), pty: any(named: 'pty')),
    ).thenAnswer((_) => opening.future);
    final session = _remoteSession(client);
    final result = _unlockedManagementService(
      _MockDiscovery(),
    ).refreshAll(session);
    var completed = false;
    unawaited(
      result.then((_) {
        completed = true;
      }),
    );
    await tester.pump();
    expect(activeQueuedSshExecCountForTesting(session.connectionId), 1);
    await tester.pump(const Duration(milliseconds: 7999));
    expect(completed, isFalse);
    await tester.pump(const Duration(milliseconds: 1));
    expect(completed, isTrue);
    final runtimes = await result;
    expect(runtimes, isNotEmpty);
    expect(
      runtimes.every((runtime) => runtime.status == AgentRuntimeStatus.failed),
      isTrue,
    );
    expect(runtimes.first.message, contains('TimeoutException'));
    expect(activeQueuedSshExecCountForTesting(session.connectionId), 0);
    expect(pendingQueuedSshExecCountForTesting(session.connectionId), 0);
    final late = _execOutput('late');
    opening.complete(late);
    await tester.pump();
    verify(late.close).called(1);
  });

  tearDown(resetQueuedSshExecsForTesting);
  group('parseAgentVersion', () {
    test('parses common CLI version output', () {
      expect(parseAgentVersion('claude 2.1.29 (Claude Code)'), '2.1.29');
      expect(parseAgentVersion('opencode version v1.2.3'), '1.2.3');
      expect(parseAgentVersion('github-copilot/0.0.371'), '0.0.371');
      expect(parseAgentVersion('codex-cli 0.98.0-alpha.3'), '0.98.0-alpha.3');
      expect(parseAgentVersion('GitHub Copilot CLI 1.0.84-3.'), '1.0.84-3');
      expect(
        parseAgentVersion('\x1b[32mV1.2.3-beta.10+build.4\x1b[0m'),
        '1.2.3-beta.10+build.4',
      );
      expect(parseAgentVersion('no version here'), isNull);
    });
  });

  group('compareAgentVersions', () {
    test('compares numeric segments instead of lexical text', () {
      expect(compareAgentVersions('1.9.0', '1.10.0'), lessThan(0));
      expect(compareAgentVersions('2.0', '2.0.0'), 0);
      expect(compareAgentVersions('2026.8.1', '2026.7.12'), greaterThan(0));
    });

    test('orders prereleases before stable versions', () {
      expect(compareAgentVersions('1.0.0-beta.2', '1.0.0'), lessThan(0));
      expect(compareAgentVersions('v1.0.0', '1.0.0'), 0);
      expect(
        compareAgentVersions('1.0.0-beta.9', '1.0.0-beta.10'),
        lessThan(0),
      );
      expect(compareAgentVersions('1.0.0-1', '1.0.0-alpha'), lessThan(0));
      expect(compareAgentVersions('1.0.0-beta', '1.0.0-beta.1'), lessThan(0));
      expect(compareAgentVersions('1.0.0+one', '1.0.0+two'), 0);
    });
  });

  test('registers every supported CLI and built-in ACP adapter', () {
    expect(agentCliRuntimeDefinitions, hasLength(10));
    expect(agentAcpRuntimeDefinitions, hasLength(10));
    expect(agentStandaloneAcpRuntimeDefinitions, hasLength(4));
    expect(agentRuntimeDefinitions, hasLength(14));
    expect(
      agentStandaloneAcpRuntimeDefinitions.map((definition) => definition.id),
      <String>['acp:claude', 'acp:codex', 'acp:antigravity', 'acp:pi'],
    );
    final antigravityAcp = agentStandaloneAcpRuntimeDefinitions.firstWhere(
      (definition) => definition.id == 'acp:antigravity',
    );
    expect(antigravityAcp.executableNames, contains('npx'));
    expect(
      agentCliRuntimeDefinitions.map((definition) => definition.label),
      containsAll(<String>[
        'Claude Code',
        'Copilot CLI',
        'Codex',
        'OpenCode',
        'Antigravity',
        'Cursor Agent',
        'Pi',
        'Hermes',
        'OpenClaw',
        'Grok Build',
      ]),
    );
  });

  group('Pi package migration', () {
    final definition = agentCliRuntimeDefinitions.singleWhere(
      (definition) => definition.id == 'cli:pi',
    );
    const package = '@earendil-works/pi-coding-agent';

    for (final windows in [false, true]) {
      test('Pi installs use the current package, windows=$windows', () {
        expect(definition.registry, AgentPackageRegistry.npm);
        expect(definition.packageName, package);
        for (final update in [false, true]) {
          final command = buildAgentInstallCommand(
            definition,
            windows: windows,
            update: update,
            detectionSource: 'npm global',
          )!;
          final script = windows ? decodeEncodedPowerShell(command) : command;
          expect(script, contains(package));
          expect(script, isNot(contains('@mariozechner/')));
        }
        final command = buildAgentInstallCommand(
          definition,
          windows: windows,
          update: true,
          executablePath: windows ? r'C:\tools\pi.cmd' : '/usr/local/bin/pi',
        )!;
        final script = windows ? decodeEncodedPowerShell(command) : command;
        expect(script, contains("'update' '--self'"));
        expect(script, isNot(contains('npm install')));
        expect(
          agentAcpRuntimeDefinitions
              .singleWhere((d) => d.id == 'acp:pi')
              .packageName,
          'pi-acp',
        );
      });

      for (final batched in [false, true]) {
        test(
          'Pi detects 0.85.1 from 0.85.0, windows=$windows, batched=$batched',
          () async {
            final client = _MockSshClient();
            final session = _remoteSession(client);
            when(() => client.remoteVersion).thenReturn(
              windows
                  ? 'SSH-2.0-OpenSSH_for_Windows_9.5'
                  : 'SSH-2.0-OpenSSH_9.9',
            );
            expect(session.remoteIsWindows, windows);
            final commands = <String>[];
            when(
              () => client.execute(any(), pty: any(named: 'pty')),
            ).thenAnswer((invocation) async {
              final command = invocation.positionalArguments.first as String;
              final script = windows
                  ? decodeEncodedPowerShell(command)
                  : command;
              commands.add(script);
              if (script.contains('__monkeyssh_agent_path__')) {
                return _execOutput(
                  '__monkeyssh_agent_runtime__=cli:pi\n'
                  '__monkeyssh_agent_path__=/usr/local/bin/pi\n'
                  '__monkeyssh_agent_version__=0.85.0\n'
                  '__monkeyssh_agent_runtime_end__\n',
                );
              }
              final currentPackage = script
                  .replaceAll("''", "'")
                  .contains("npm view '$package'");
              return _execOutput(
                '__monkeyssh_agent_runtime__=cli:pi\n'
                '__monkeyssh_agent_source__=npm global\n'
                '__monkeyssh_agent_installed__=0.85.0\n'
                '__monkeyssh_agent_latest__=${currentPackage ? '0.85.1' : '0.73.1'}\n'
                '__monkeyssh_agent_runtime_end__\n',
              );
            });
            final service = _unlockedManagementService(_MockDiscovery());
            final runtime = batched
                ? (await service.checkForUpdates(
                    session,
                  )).singleWhere((runtime) => runtime.definition.id == 'cli:pi')
                : await service.inspect(session, definition);

            expect(runtime.status, AgentRuntimeStatus.updateAvailable);
            expect(runtime.hasUpdate, isTrue);
            expect(runtime.installedVersion, '0.85.0');
            expect(runtime.latestVersion, '0.85.1');
            expect(runtime.detectionSource, 'npm global');
            expect(runtime.managedByPackageManager, isTrue);
            expect(commands, hasLength(2));
            expect(commands.last, contains("'$package@'"));
            expect(commands.last, isNot(contains('@mariozechner/')));
          },
        );
      }
    }
  });

  group('consistent update detection', () {
    for (final windows in [false, true]) {
      for (final mode in ['inspect', 'refresh', 'background']) {
        test('all runtimes detect updates, $mode, windows=$windows', () async {
          final client = _MockSshClient();
          final discovery = _MockDiscovery();
          final session = _remoteSession(client);
          when(() => client.remoteVersion).thenReturn(
            windows ? 'SSH-2.0-OpenSSH_for_Windows_9.5' : 'SSH-2.0-OpenSSH_9.9',
          );
          when(() => discovery.invalidateSession(session)).thenReturn(null);
          when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
            invocation,
          ) async {
            final command = invocation.positionalArguments.first as String;
            final script = windows ? decodeEncodedPowerShell(command) : command;
            final output = StringBuffer();
            final probe = script.contains('__monkeyssh_agent_path__');
            for (final definition in agentRuntimeDefinitions) {
              if (!script.contains(definition.id)) continue;
              output.writeln('__monkeyssh_agent_runtime__=${definition.id}');
              if (probe) {
                output.writeln(
                  '__monkeyssh_agent_path__=/bin/${definition.executableNames.first}',
                );
                if (definition.kind == AgentRuntimeKind.cli) {
                  output.writeln('__monkeyssh_agent_version__=1.0.0');
                }
              } else {
                output
                  ..writeln('__monkeyssh_agent_source__=npm global')
                  ..writeln('__monkeyssh_agent_installed__=1.0.0')
                  ..writeln('__monkeyssh_agent_latest__=1.1.0');
              }
              output.writeln('__monkeyssh_agent_runtime_end__');
            }
            return _execOutput(output.toString());
          });
          final service = _unlockedManagementService(discovery);
          final runtimes = switch (mode) {
            'inspect' => [
              for (final definition in agentRuntimeDefinitions)
                await service.inspect(session, definition),
            ],
            'refresh' => await service.refreshAll(session),
            _ => await service.checkForUpdates(session),
          };
          expect(runtimes, hasLength(agentRuntimeDefinitions.length));
          for (final runtime in runtimes) {
            expect(
              runtime.status,
              AgentRuntimeStatus.updateAvailable,
              reason: runtime.definition.id,
            );
            expect(
              runtime.installedVersion,
              '1.0.0',
              reason: runtime.definition.id,
            );
            expect(
              runtime.latestVersion,
              '1.1.0',
              reason: runtime.definition.id,
            );
          }
          if (mode != 'inspect') {
            final cached = await service.checkForUpdates(session);
            expect(
              cached.map((runtime) => runtime.definition.id),
              agentRuntimeDefinitions.map((definition) => definition.id),
            );
          }
        });
      }
    }

    test(
      'shared adapters use the same package and release source as their CLI',
      () {
        for (final adapter in agentAcpRuntimeDefinitions.where(
          (d) => d.sharesCliInstallation,
        )) {
          final cli = agentCliRuntimeDefinitions.singleWhere(
            (d) => d.tool == adapter.tool,
          );
          expect(adapter.packageName, cli.packageName, reason: adapter.id);
          expect(adapter.registry, cli.registry, reason: adapter.id);
          expect(
            adapter.executableNames,
            cli.executableNames,
            reason: adapter.id,
          );
        }
      },
    );
  });

  test(
    'POSIX metadata reads all registries and official releases without launching adapters',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'monkeyssh-metadata-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      final bin = Directory('${root.path}/bin')..createSync();
      final npmPackages = agentRuntimeDefinitions
          .where((d) => d.registry == AgentPackageRegistry.npm)
          .map((d) => d.packageName!)
          .toSet();
      final npm = File('${bin.path}/npm')
        ..writeAsStringSync(
          '#!/bin/sh\ncase "\$1" in\n'
          'list) cat <<\'PACKAGES\'\n${npmPackages.map((p) => "├── $p@1.0.0").join('\n')}\nPACKAGES\n;;\n'
          'view) echo 1.1.0;;\n*) exit 1;;\nesac\n',
        );
      final pipx = File('${bin.path}/pipx')
        ..writeAsStringSync('#!/bin/sh\necho "hermes-agent 0.19.0"\n');
      final brew = File('${bin.path}/brew')
        ..writeAsStringSync('#!/bin/sh\nexit 1\n');
      final curl = File('${bin.path}/curl')
        ..writeAsStringSync(r'''
#!/bin/sh
case "$*" in
  *cursor.com/install*) echo 'DOWNLOAD_URL="https://downloads.cursor.com/lab/2026.09.08-6caf4ff/linux/arm64/agent-cli-package.tar.gz"';;
  *antigravity*/manifests/*) echo '{"version":"1.1.28","url":"https://example.test/1.1.28"}';;
  *hermes_cli/__init__.py*) printf '__version__ = "0.21.1"\n__release_date__ = "2026.9.7"\n';;
  *x.ai/cli/stable*) echo '1.0.24';;
  *registry.npmjs.org/*/latest*) echo '{"version":"1.2.0"}';;
  *) exit 1;;
esac
''');
      await Process.run('chmod', [
        '+x',
        npm.path,
        pipx.path,
        brew.path,
        curl.path,
      ]);
      final script = File('${root.path}/metadata.sh')
        ..writeAsStringSync(
          buildAgentMetadataProbeCommand(
            agentRuntimeDefinitions,
            windows: false,
          ),
        );
      for (final shell in [
        'bash',
        if (File('/bin/zsh').existsSync()) '/bin/zsh',
      ]) {
        final result = await Process.run(
          shell,
          [script.path],
          environment: {'HOME': root.path, 'PATH': '${bin.path}:/usr/bin:/bin'},
          includeParentEnvironment: false,
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final snapshots = parseAgentMetadataProbeOutput(
          result.stdout as String,
        );
        expect(snapshots, hasLength(agentRuntimeDefinitions.length));
        for (final definition in agentRuntimeDefinitions.where(
          (d) => d.registry == AgentPackageRegistry.npm,
        )) {
          expect(
            snapshots[definition.id]?.installedVersionOutput,
            '1.0.0',
            reason: definition.id,
          );
          expect(
            snapshots[definition.id]?.latestVersionOutput,
            '1.1.0',
            reason: definition.id,
          );
        }
        for (final entry in {
          'cli:cursor': '2026.09.08-6caf4ff',
          'cli:antigravity': '1.1.28',
          'cli:hermes': '0.21.1',
          'cli:grok': '1.0.24',
        }.entries) {
          expect(
            parseAgentVersion(snapshots[entry.key]?.latestVersionOutput ?? ''),
            entry.value,
            reason: '$shell: ${entry.key}',
          );
        }
      }
      // A native or Bun installation may have no usable npm command.
      npm.writeAsStringSync('#!/bin/sh\nexit 1\n');
      final fallback = await Process.run(
        'bash',
        [script.path],
        environment: {'HOME': root.path, 'PATH': '${bin.path}:/usr/bin:/bin'},
        includeParentEnvironment: false,
      );
      final fallbackSnapshots = parseAgentMetadataProbeOutput(
        fallback.stdout as String,
      );
      for (final definition in agentRuntimeDefinitions.where(
        (d) => d.registry == AgentPackageRegistry.npm,
      )) {
        expect(
          parseAgentVersion(
            fallbackSnapshots[definition.id]?.latestVersionOutput ?? '',
          ),
          '1.2.0',
          reason: definition.id,
        );
      }
      // Offline HTTP must not invent a latest version from an error response.
      curl.writeAsStringSync('#!/bin/sh\nexit 22\n');
      final offline = await Process.run(
        'bash',
        [script.path],
        environment: {'HOME': root.path, 'PATH': '${bin.path}:/usr/bin:/bin'},
        includeParentEnvironment: false,
      );
      final offlineSnapshots = parseAgentMetadataProbeOutput(
        offline.stdout as String,
      );
      expect(offlineSnapshots, hasLength(agentRuntimeDefinitions.length));
      for (final snapshot in offlineSnapshots.values) {
        expect(snapshot.latestVersionOutput, isNull);
      }
    },
  );

  test(
    'reads ACP package versions without starting servers and handles a locked Cursor keychain',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'monkeyssh-adapter-version-',
      );
      addTearDown(() => root.delete(recursive: true));
      final bin = Directory('${root.path}/bin')..createSync();
      final node = await Process.run('which', ['node']);
      expect(
        node.exitCode,
        0,
        reason: 'Node is required to validate npm launcher metadata',
      );
      Link('${bin.path}/node').createSync((node.stdout as String).trim());
      final definitions = [
        ...agentStandaloneAcpRuntimeDefinitions,
        agentCliRuntimeDefinitions.singleWhere((d) => d.id == 'cli:cursor'),
      ];
      final sentinel = File('${root.path}/adapter-started');
      for (final definition in agentStandaloneAcpRuntimeDefinitions) {
        final package = Directory(
          '${root.path}/packages/${definition.packageName}',
        )..createSync(recursive: true);
        File('${package.path}/package.json').writeAsStringSync(
          jsonEncode({'name': definition.packageName, 'version': '1.2.3'}),
        );
        final dist = Directory('${package.path}/dist')..createSync();
        final launcher = File('${dist.path}/index.js')
          ..writeAsStringSync('#!/bin/sh\ntouch "${sentinel.path}"\n');
        await Process.run('chmod', ['+x', launcher.path]);
        Link(
          '${bin.path}/${definition.executableNames.first}',
        ).createSync(launcher.path);
      }
      final cursorDir = Directory(
        '${root.path}/.local/share/cursor-agent/versions/2026.09.02-c22c1a3',
      )..createSync(recursive: true);
      final cursor = File('${cursorDir.path}/cursor-agent')
        ..writeAsStringSync(
          '#!/bin/sh\necho "login keychain is locked" >&2\nexit 1\n',
        );
      await Process.run('chmod', ['+x', cursor.path]);
      Link('${bin.path}/cursor-agent').createSync(cursor.path);
      final probe = File('${root.path}/probe.sh')
        ..writeAsStringSync(
          buildAgentBatchProbeCommand(definitions, windows: false),
        );
      for (final shell in [
        'bash',
        if (File('/bin/zsh').existsSync()) '/bin/zsh',
      ]) {
        final result = await Process.run(
          shell,
          [probe.path],
          environment: {'HOME': root.path, 'PATH': '${bin.path}:/usr/bin:/bin'},
          includeParentEnvironment: false,
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final snapshots = parseAgentBatchProbeOutput(result.stdout as String);
        for (final definition in agentStandaloneAcpRuntimeDefinitions) {
          expect(
            snapshots[definition.id]?.versionOutput,
            '1.2.3',
            reason: '$shell: ${definition.id}',
          );
        }
        expect(snapshots['cli:cursor']?.versionOutput, '2026.09.02-c22c1a3');
        expect(sentinel.existsSync(), isFalse);
      }
    },
  );

  group('buildAgentInstallCommand', () {
    test('builds npm install and update commands for POSIX and Windows', () {
      final definition = agentCliRuntimeDefinitions.first;
      final posix = buildAgentInstallCommand(
        definition,
        windows: false,
        update: false,
      );
      expect(posix, contains(r'export PATH="$HOME/.opencode/bin'));
      expect(
        posix,
        endsWith(
          "npm install -g --foreground-scripts --ignore-scripts=false '@anthropic-ai/claude-code'@latest",
        ),
      );
      final windows = buildAgentInstallCommand(
        definition,
        windows: true,
        update: true,
      );
      expect(windows, isNotNull);
      final script = decodeEncodedPowerShell(windows!);
      expect(script, contains(r'$PROFILE.CurrentUserAllHosts'));
      expect(
        script,
        contains('npm install -g --foreground-scripts --ignore-scripts=false'),
      );
      expect(script, contains("'@anthropic-ai/claude-code@latest'"));
    });

    test('enables lifecycle scripts for every managed npm install', () {
      final npmDefinitions = agentRuntimeDefinitions.where(
        (definition) => definition.registry == AgentPackageRegistry.npm,
      );

      for (final definition in npmDefinitions) {
        final posix = buildAgentInstallCommand(
          definition,
          windows: false,
          update: false,
        );
        expect(
          posix,
          contains(
            'npm install -g --foreground-scripts --ignore-scripts=false',
          ),
          reason: definition.id,
        );

        final windows = buildAgentInstallCommand(
          definition,
          windows: true,
          update: false,
        );
        expect(
          decodeEncodedPowerShell(windows!),
          contains(
            'npm install -g --foreground-scripts --ignore-scripts=false',
          ),
          reason: definition.id,
        );
      }
    });

    test('repair reinstalls broken managed packages', () {
      final openCode = agentCliRuntimeDefinitions.firstWhere(
        (definition) => definition.id == 'cli:opencode',
      );
      final posix = buildAgentInstallCommand(
        openCode,
        windows: false,
        update: false,
        repair: true,
      );
      expect(posix, contains("npm uninstall -g 'opencode-ai'"));
      expect(
        posix,
        endsWith(
          "npm install -g --foreground-scripts --ignore-scripts=false 'opencode-ai'@latest",
        ),
      );

      final windows = decodeEncodedPowerShell(
        buildAgentInstallCommand(
          openCode,
          windows: true,
          update: false,
          repair: true,
        )!,
      );
      expect(windows, contains("npm uninstall -g 'opencode-ai'"));
      expect(
        windows,
        contains('npm install -g --foreground-scripts --ignore-scripts=false'),
      );

      final hermes = agentCliRuntimeDefinitions.firstWhere(
        (definition) => definition.id == 'cli:hermes',
      );
      expect(
        buildAgentInstallCommand(
          hermes,
          windows: false,
          update: false,
          repair: true,
        ),
        contains("pipx reinstall 'hermes-agent'"),
      );
    });

    test('uses every supported CLI built-in updater', () {
      final cases = <(String, String, List<String>)>[
        ('cli:claude', '/opt/tools/claude', ['update']),
        ('cli:copilot', '/opt/tools/copilot', ['update']),
        ('cli:codex', '/opt/tools/codex', ['update']),
        ('cli:opencode', '/opt/tools/opencode', ['upgrade']),
        ('cli:antigravity', '/opt/tools/agy', ['update']),
        ('cli:cursor', '/opt/tools/cursor-agent', ['update']),
        ('cli:pi', '/opt/tools/pi', ['update', '--self']),
        ('cli:hermes', '/opt/tools/hermes', ['update', '--yes']),
        ('cli:openclaw', '/opt/tools/openclaw', ['update', '--yes']),
        ('cli:grok', '/opt/tools/grok', ['update']),
      ];
      expect(cases, hasLength(agentCliRuntimeDefinitions.length));

      for (final entry in cases) {
        final definition = agentCliRuntimeDefinitions.firstWhere(
          (runtime) => runtime.id == entry.$1,
        );
        expect(definition.selfUpdateArguments, entry.$3);
        final quotedArguments = entry.$3
            .map((argument) => "'$argument'")
            .join(' ');
        final posix = buildAgentInstallCommand(
          definition,
          windows: false,
          update: true,
          detectionSource: 'PATH',
          executablePath: entry.$2,
        );
        expect(posix, endsWith("'${entry.$2}' $quotedArguments"));

        final windows = buildAgentInstallCommand(
          definition,
          windows: true,
          update: true,
          detectionSource: 'PATH',
          executablePath: entry.$2,
        );
        final script = decodeEncodedPowerShell(windows!);
        expect(script, contains("& '${entry.$2}' $quotedArguments"));
      }
    });

    test('keeps Homebrew updates with the detected package manager', () {
      final definition = agentCliRuntimeDefinitions.firstWhere(
        (runtime) => runtime.label == 'OpenCode',
      );
      expect(
        buildAgentInstallCommand(
          definition,
          windows: false,
          update: true,
          detectionSource: 'Homebrew',
        ),
        endsWith("brew upgrade 'opencode'"),
      );
    });

    test('builds pipx commands with a Python fallback', () {
      final definition = agentCliRuntimeDefinitions.firstWhere(
        (runtime) => runtime.label == 'Hermes',
      );
      expect(
        buildAgentInstallCommand(definition, windows: false, update: false),
        contains('pipx install'),
      );
      final windows = buildAgentInstallCommand(
        definition,
        windows: true,
        update: true,
      );
      expect(
        decodeEncodedPowerShell(windows!),
        contains("& py -m pip install --user --upgrade 'hermes-agent'"),
      );
    });

    test('quotes apostrophes safely for POSIX shells', () {
      const definition = AgentRuntimeDefinition(
        id: 'test',
        label: 'Test',
        kind: AgentRuntimeKind.cli,
        executableNames: ['test'],
        registry: AgentPackageRegistry.npm,
        packageName: "it's-agent",
      );
      expect(
        buildAgentInstallCommand(definition, windows: false, update: false),
        endsWith(
          r"npm install -g --foreground-scripts --ignore-scripts=false 'it'\''s-agent'@latest",
        ),
      );
    });

    test('does not guess an installer for unsupported packages', () {
      const definition = AgentRuntimeDefinition(
        id: 'cli:unknown',
        label: 'Unknown',
        kind: AgentRuntimeKind.cli,
        executableNames: ['unknown'],
      );
      expect(
        buildAgentInstallCommand(definition, windows: false, update: false),
        isNull,
      );
    });
  });

  group('AgentManagementService', () {
    test('detects npm ownership and an available update', () async {
      final client = _MockSshClient();
      final discovery = _MockDiscovery();
      final session = _remoteSession(client);
      when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.9');
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        invocation,
      ) async {
        final command = invocation.positionalArguments.first as String;
        if (command.contains('__monkeyssh_agent_path__')) {
          return _execOutput(
            '__monkeyssh_agent_runtime__=cli:claude\n'
            '__monkeyssh_agent_path__=/usr/local/bin/claude\n'
            '__monkeyssh_agent_runtime_end__\n',
          );
        }
        if (command.contains('__monkeyssh_agent_source__')) {
          return _execOutput(
            '__monkeyssh_agent_runtime__=cli:claude\n'
            '__monkeyssh_agent_source__=npm global\n'
            '__monkeyssh_agent_installed__=1.0.0\n'
            '__monkeyssh_agent_latest__=1.1.0\n'
            '__monkeyssh_agent_runtime_end__\n',
          );
        }
        return _execOutput('', exitCode: 1);
      });

      final runtime = await _unlockedManagementService(
        discovery,
      ).inspect(session, agentCliRuntimeDefinitions.first);

      expect(runtime.status, AgentRuntimeStatus.updateAvailable);
      expect(runtime.installedVersion, '1.0.0');
      expect(runtime.latestVersion, '1.1.0');
      expect(runtime.detectionSource, 'npm global');
      expect(runtime.managedByPackageManager, isTrue);
    });

    test('marks skipped postinstall installations as repairable', () async {
      final client = _MockSshClient();
      final discovery = _MockDiscovery();
      final session = _remoteSession(client);
      final definition = agentCliRuntimeDefinitions.firstWhere(
        (runtime) => runtime.id == 'cli:opencode',
      );
      when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.9');
      var executeCount = 0;
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        _,
      ) async {
        executeCount += 1;
        if (executeCount == 1) {
          return _execOutput(
            '__monkeyssh_agent_runtime__=cli:opencode\n'
            '__monkeyssh_agent_path__=/usr/local/bin/opencode\n'
            '__monkeyssh_agent_repair__\n'
            '__monkeyssh_agent_runtime_end__\n',
          );
        }
        return _execOutput(
          '__monkeyssh_agent_runtime__=cli:opencode\n'
          '__monkeyssh_agent_source__=npm global\n'
          '__monkeyssh_agent_runtime_end__\n',
        );
      });

      final runtime = await _unlockedManagementService(
        discovery,
      ).inspect(session, definition);

      expect(runtime.status, AgentRuntimeStatus.needsRepair);
      expect(runtime.executablePath, '/usr/local/bin/opencode');
      expect(runtime.message, contains('Required setup scripts'));
    });

    test('detects Antigravity ACP through its npx launcher', () async {
      final client = _MockSshClient();
      final discovery = _MockDiscovery();
      final session = _remoteSession(client);
      final definition = agentStandaloneAcpRuntimeDefinitions.firstWhere(
        (runtime) => runtime.id == 'acp:antigravity',
      );
      when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.9');
      var executeCount = 0;
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        _,
      ) async {
        executeCount += 1;
        if (executeCount == 1) {
          return _execOutput(
            '__monkeyssh_agent_runtime__=acp:antigravity\n'
            '__monkeyssh_agent_path__=/usr/local/bin/npx\n'
            '__monkeyssh_agent_runtime_end__\n',
          );
        }
        return _execOutput(
          '__monkeyssh_agent_runtime__=acp:antigravity\n'
          '__monkeyssh_agent_runtime_end__\n',
        );
      });

      final runtime = await _unlockedManagementService(
        discovery,
      ).inspect(session, definition);

      expect(runtime.status, AgentRuntimeStatus.installed);
      expect(runtime.executablePath, '/usr/local/bin/npx');
      expect(runtime.detectionSource, 'npx on demand');
    });

    test(
      'forced update checks bypass cache and share in-flight probes',
      () async {
        final client = _MockSshClient();
        final session = _remoteSession(client);
        when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.9');
        var calls = 0;
        when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
          _,
        ) async {
          calls++;
          return _execOutput('');
        });
        final service = _unlockedManagementService(_MockDiscovery());
        await service.checkForUpdates(session);
        await service.checkForUpdates(session);
        expect(calls, 1);
        await Future.wait([
          service.checkForUpdates(session, forceRefresh: true),
          service.checkForUpdates(session, forceRefresh: true),
        ]);
        expect(calls, 2);
      },
    );

    test('evicts expired connections on lookup and insertion', () async {
      final client = _MockSshClient();
      when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.9');
      var calls = 0;
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        _,
      ) async {
        calls++;
        return _execOutput('');
      });
      var now = DateTime.utc(2026);
      final service = AgentManagementService(
        _MockDiscovery(),
        canManageAgents: () async => true,
        now: () => now,
      );
      final older = _remoteSession(client, connectionId: 1);
      final current = _remoteSession(client, connectionId: 2);
      await service.checkForUpdates(older);
      now = now.add(const Duration(minutes: 1));
      await service.checkForUpdates(current);
      now = now.add(const Duration(minutes: 14));
      await service.checkForUpdates(current);
      expect(calls, 2);
      expect(service.cachedConnectionCount, 1);
      now = now.add(const Duration(minutes: 1));
      await service.refreshAll(older);
      expect(calls, 3);
      expect(service.cachedConnectionCount, 1);
    });

    test('bounds the cache and keeps the newest connection cached', () async {
      final client = _MockSshClient();
      when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.9');
      var calls = 0;
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        _,
      ) async {
        calls++;
        return _execOutput('');
      });
      final service = _unlockedManagementService(_MockDiscovery());
      for (var id = 0; id < 33; id++) {
        await service.checkForUpdates(_remoteSession(client, connectionId: id));
      }
      expect(service.cachedConnectionCount, 32);
      await service.checkForUpdates(_remoteSession(client, connectionId: 32));
      expect(calls, 33);
      await service.checkForUpdates(_remoteSession(client, connectionId: 0));
      expect(calls, 34);
      expect(service.cachedConnectionCount, 32);
    });

    test('free access blocks every management operation before SSH', () async {
      final client = _MockSshClient();
      final session = _remoteSession(client);
      final discovery = _MockDiscovery();
      var allowed = false;
      final service = AgentManagementService(
        discovery,
        canManageAgents: () async => allowed,
      );
      final definition = agentCliRuntimeDefinitions.first;
      expect(await service.checkForUpdates(session), isEmpty);
      expect(
        await service.checkForUpdates(session, forceRefresh: true),
        isEmpty,
      );
      expect(await service.refreshAll(session), isEmpty);
      expect(
        (await service.inspect(session, definition)).status,
        AgentRuntimeStatus.unavailable,
      );
      for (final update in [false, true]) {
        expect(
          (await service.installOrUpdate(
            session,
            definition,
            update: update,
          )).succeeded,
          isFalse,
        );
      }
      final repair = await service.installOrUpdate(
        session,
        definition,
        update: false,
        current: AgentRuntimeInfo(
          definition: definition,
          status: AgentRuntimeStatus.needsRepair,
        ),
      );
      expect(repair.succeeded, isFalse);
      verifyNever(() => client.execute(any(), pty: any(named: 'pty')));
      verifyNever(() => discovery.invalidateSession(session));
      // Revoked access must not return cached Pro results or issue new probes.
      when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.9');
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => _execOutput(''));
      allowed = true;
      expect(await service.checkForUpdates(session), isNotEmpty);
      clearInteractions(client);
      allowed = false;
      expect(await service.checkForUpdates(session), isEmpty);
      expect(await service.refreshAll(session), isEmpty);
      verifyNever(() => client.execute(any(), pty: any(named: 'pty')));
    });

    test(
      'automatic update checks include CLIs and standalone adapters',
      () async {
        final client = _MockSshClient();
        final discovery = _MockDiscovery();
        final session = _remoteSession(client);
        when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.9');
        var executeCount = 0;
        when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
          _,
        ) async {
          executeCount += 1;
          final output = StringBuffer();
          for (final definition in agentCliRuntimeDefinitions) {
            output
              ..writeln('__monkeyssh_agent_runtime__=${definition.id}')
              ..writeln('__monkeyssh_agent_runtime_end__');
          }
          return _execOutput(output.toString());
        });

        final runtimes = await _unlockedManagementService(
          discovery,
        ).checkForUpdates(session);

        expect(
          runtimes.map((runtime) => runtime.definition.id),
          agentRuntimeDefinitions.map((definition) => definition.id),
        );
        expect(executeCount, 1);
      },
    );

    test('refresh probes all runtimes through one SSH channel', () async {
      final client = _MockSshClient();
      final discovery = _MockDiscovery();
      final session = _remoteSession(client);
      when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.9');
      when(() => discovery.invalidateSession(session)).thenReturn(null);
      var executeCount = 0;
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        _,
      ) async {
        executeCount += 1;
        final output = StringBuffer();
        for (final definition in [
          ...agentCliRuntimeDefinitions,
          ...agentStandaloneAcpRuntimeDefinitions,
        ]) {
          output
            ..writeln('__monkeyssh_agent_runtime__=${definition.id}')
            ..writeln('__monkeyssh_agent_runtime_end__');
        }
        return _execOutput(output.toString());
      });

      final runtimes = await _unlockedManagementService(
        discovery,
      ).refreshAll(session);

      expect(runtimes, hasLength(agentRuntimeDefinitions.length));
      expect(
        runtimes,
        everyElement(
          isA<AgentRuntimeInfo>().having(
            (runtime) => runtime.status,
            'status',
            AgentRuntimeStatus.notInstalled,
          ),
        ),
      );
      expect(executeCount, 1);
    });

    test(
      'refresh batches installed metadata into a second SSH channel',
      () async {
        final client = _MockSshClient();
        final discovery = _MockDiscovery();
        final session = _remoteSession(client);
        when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.9');
        when(() => discovery.invalidateSession(session)).thenReturn(null);
        var executeCount = 0;
        when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
          invocation,
        ) async {
          executeCount += 1;
          final command = invocation.positionalArguments.first as String;
          if (command.contains('__monkeyssh_agent_path__')) {
            final output = StringBuffer();
            for (final definition in [
              ...agentCliRuntimeDefinitions,
              ...agentStandaloneAcpRuntimeDefinitions,
            ]) {
              output.writeln('__monkeyssh_agent_runtime__=${definition.id}');
              if (definition.id == 'cli:copilot') {
                output.writeln(
                  '__monkeyssh_agent_path__=/usr/local/bin/copilot',
                );
              }
              output.writeln('__monkeyssh_agent_runtime_end__');
            }
            return _execOutput(output.toString());
          }
          return _execOutput(
            '__monkeyssh_agent_runtime__=cli:copilot\n'
            '__monkeyssh_agent_source__=npm global\n'
            '__monkeyssh_agent_installed__=1.0.0\n'
            '__monkeyssh_agent_latest__=1.1.0\n'
            '__monkeyssh_agent_runtime_end__\n',
          );
        });

        final runtimes = await _unlockedManagementService(
          discovery,
        ).refreshAll(session);

        final copilot = runtimes.firstWhere(
          (runtime) => runtime.definition.id == 'cli:copilot',
        );
        expect(copilot.status, AgentRuntimeStatus.updateAvailable);
        expect(copilot.detectionSource, 'npm global');
        expect(copilot.installedVersion, '1.0.0');
        expect(copilot.latestVersion, '1.1.0');
        expect(
          runtimes.where((runtime) => runtime.definition.id == 'acp:copilot'),
          isEmpty,
        );
        expect(
          runtimes
              .where(
                (runtime) =>
                    runtime.definition.kind == AgentRuntimeKind.acpAdapter,
              )
              .where((runtime) => runtime.hasUpdate),
          isEmpty,
        );
        expect(executeCount, 2);
      },
    );

    test(
      'repairs the detected Bun package without touching another npm copy',
      () async {
        final root = await Directory.systemTemp.createTemp('agent-repair-');
        addTearDown(() => root.delete(recursive: true));
        final bin = Directory('${root.path}/.bun/bin')
          ..createSync(recursive: true);
        final package = Directory(
          '${root.path}/.bun/install/global/node_modules/opencode-ai',
        )..createSync(recursive: true);
        final packageBin = Directory('${package.path}/bin')..createSync();
        final executable = File('${packageBin.path}/opencode.exe');
        const broken =
            '#!/bin/sh\necho "postinstall script was not run due to --ignore-scripts" >&2\nexit 1\n';
        File(
          '${package.path}/package.json',
        ).writeAsStringSync('{"name":"opencode-ai"}');
        File('${package.path}/postinstall.mjs').writeAsStringSync(
          "import fs from 'node:fs';\n"
          'fs.writeFileSync("bin/opencode.exe", ${jsonEncode('#!/bin/sh\necho 1.2.3\n')});\n'
          'fs.chmodSync("bin/opencode.exe", 0o755);\n',
        );
        final launcher = Link('${bin.path}/opencode')
          ..createSync(executable.path);
        final node = await Process.run('which', ['node']);
        Link('${bin.path}/node').createSync((node.stdout as String).trim());
        final definition = agentCliRuntimeDefinitions.firstWhere(
          (d) => d.id == 'cli:opencode',
        );
        final command = buildAgentInstallCommand(
          definition,
          windows: false,
          update: false,
          repair: true,
          executablePath: launcher.path,
        )!;
        final script = File('${root.path}/repair.sh')
          ..writeAsStringSync(command);
        final probe = File('${root.path}/probe.sh')
          ..writeAsStringSync(
            buildAgentBatchProbeCommand([definition], windows: false),
          );
        for (final shell in [
          'bash',
          if (File('/bin/zsh').existsSync()) '/bin/zsh',
        ]) {
          executable.writeAsStringSync(broken);
          await Process.run('chmod', ['+x', executable.path]);
          final environment = {
            'HOME': root.path,
            'PATH': '/usr/bin:/bin',
            'TMPDIR': root.path,
          };
          final before = await Process.run(shell, [
            probe.path,
          ], environment: environment);
          expect(before.stdout, contains('__monkeyssh_agent_repair__'));
          final result = await Process.run(shell, [
            script.path,
          ], environment: environment);
          expect(result.exitCode, 0, reason: '${result.stderr}');
          final after = await Process.run(shell, [
            probe.path,
          ], environment: environment);
          expect(
            after.stdout,
            contains('__monkeyssh_agent_version__=1.2.3'),
            reason: shell,
          );
          expect(after.stdout, isNot(contains('__monkeyssh_agent_repair__')));
        }
        // Refuse an unrelated package rather than reporting a repair elsewhere.
        File(
          '${package.path}/package.json',
        ).writeAsStringSync('{"name":"other"}');
        final refused = await Process.run(
          'bash',
          [script.path],
          environment: {'HOME': root.path},
        );
        expect(refused.exitCode, isNot(0));
      },
    );

    test('zero exit does not mean a broken CLI was repaired', () async {
      final client = _MockSshClient();
      final discovery = _MockDiscovery();
      final session = _remoteSession(client);
      final definition = agentCliRuntimeDefinitions.firstWhere(
        (d) => d.id == 'cli:opencode',
      );
      when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.9');
      var count = 0;
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        _,
      ) async {
        count++;
        return _execOutput(
          count == 2
              ? '__monkeyssh_agent_runtime__=cli:opencode\n'
                    '__monkeyssh_agent_path__=/home/dev/.bun/bin/opencode\n__monkeyssh_agent_repair__\n__monkeyssh_agent_runtime_end__\n'
              : '',
        );
      });
      when(() => discovery.invalidateSession(session)).thenReturn(null);
      final result = await _unlockedManagementService(discovery)
          .installOrUpdate(
            session,
            definition,
            update: false,
            current: AgentRuntimeInfo(
              definition: definition,
              status: AgentRuntimeStatus.needsRepair,
              executablePath: '/home/dev/.bun/bin/opencode',
            ),
          );
      expect(result.succeeded, isFalse);
      expect(result.output, contains('could not be verified'));
    });

    test(
      'keeps completed metadata when a later registry lookup times out',
      () async {
        final client = _MockSshClient();
        final session = _remoteSession(client);
        final done = Completer<void>();
        when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.9');
        var count = 0;
        when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
          _,
        ) async {
          if (++count == 1) {
            return _execOutput(
              '__monkeyssh_agent_runtime__=cli:claude\n'
              '__monkeyssh_agent_path__=/bin/claude\n'
              '__monkeyssh_agent_runtime_end__\n',
            );
          }
          final exec = _execOutput(
            '__monkeyssh_agent_runtime__=cli:claude\n'
            '__monkeyssh_agent_installed__=2.0.0\n'
            '__monkeyssh_agent_runtime_end__\n',
          );
          when(() => exec.done).thenAnswer((_) => done.future);
          when(exec.close).thenAnswer((_) {
            if (!done.isCompleted) done.complete();
          });
          return exec;
        });
        final runtimes = await _unlockedManagementService(
          _MockDiscovery(),
        ).refreshAll(session);
        expect(runtimes.first.installedVersion, '2.0.0');
        expect(runtimes.first.status, AgentRuntimeStatus.installed);
      },
      timeout: const Timeout(Duration(seconds: 45)),
    );

    test('registry failure does not hide the installed version', () async {
      final client = _MockSshClient();
      final session = _remoteSession(client);
      when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.9');
      var count = 0;
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        _,
      ) async {
        if (++count == 2) throw StateError('registry unavailable');
        return _execOutput(
          '__monkeyssh_agent_runtime__=cli:claude\n'
          '__monkeyssh_agent_path__=/bin/claude\n__monkeyssh_agent_version__=2.0.0\n'
          '__monkeyssh_agent_runtime_end__\n',
        );
      });
      final info = await _unlockedManagementService(
        _MockDiscovery(),
      ).inspect(session, agentCliRuntimeDefinitions.first);
      expect(info.status, AgentRuntimeStatus.installed);
      expect(info.installedVersion, '2.0.0');
    });

    test('streams install output and invalidates provider discovery', () async {
      final client = _MockSshClient();
      final discovery = _MockDiscovery();
      final session = _remoteSession(client);
      when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.9');
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer(
        (_) async => _execOutput(
          'installed 1 package\n'
          '__monkeyssh_agent_runtime__=cli:claude\n'
          '__monkeyssh_agent_path__=/bin/claude\n'
          '__monkeyssh_agent_version__=2.0.0\n'
          '__monkeyssh_agent_runtime_end__\n',
        ),
      );
      when(() => discovery.invalidateSession(session)).thenReturn(null);
      final streamed = StringBuffer();

      final result = await _unlockedManagementService(discovery)
          .installOrUpdate(
            session,
            agentCliRuntimeDefinitions.first,
            update: true,
            current: AgentRuntimeInfo(
              definition: agentCliRuntimeDefinitions.first,
              status: AgentRuntimeStatus.updateAvailable,
              detectionSource: 'npm global',
              managedByPackageManager: true,
            ),
            onOutput: streamed.write,
          );

      expect(result.succeeded, isTrue);
      expect(streamed.toString(), contains('installed 1 package'));
      verify(() => discovery.invalidateSession(session)).called(1);
    });
  });

  test('Windows installers suppress progress and request plain text', () {
    for (final definition in agentRuntimeDefinitions) {
      for (final update in [false, true]) {
        final command = buildAgentInstallCommand(
          definition,
          windows: true,
          update: update,
        );
        if (command == null) continue;
        expect(command, contains('-OutputFormat Text'));
        expect(
          decodeEncodedPowerShell(command),
          startsWith(r"$ProgressPreference = 'SilentlyContinue';"),
        );
      }
    }
  });

  group('batch probes', () {
    test(
      'Windows management commands fit cmd.exe and CreateProcess limits',
      () {
        final commands = [
          buildAgentBatchProbeCommand(agentRuntimeDefinitions, windows: true),
          buildAgentMetadataProbeCommand(
            agentRuntimeDefinitions,
            windows: true,
          ),
          for (final definition in agentRuntimeDefinitions)
            buildAgentBatchProbeCommand([definition], windows: true),
        ];
        for (final (index, command) in commands.indexed) {
          expect(command.length, lessThan(7500), reason: 'index $index');
          final script = decodeEncodedPowerShell(command);
          expect(script, contains('__monkeyssh_agent_runtime__='));
        }
      },
    );
    test(
      'full Windows probe executes through cmd and PowerShell',
      () async {
        final root = await Directory.systemTemp.createTemp('agent-probe-');
        addTearDown(() => root.delete(recursive: true));
        final launcher = File('${root.path}/copilot.cmd');
        await launcher.writeAsString('@echo off\r\necho 1.2.3\r\n');
        final original = decodeEncodedPowerShell(
          buildAgentBatchProbeCommand(agentRuntimeDefinitions, windows: true),
        );
        // Isolate the fixture from installed agents and user profile side effects.
        final isolated = original.replaceFirst(
          powerShellProfilePathPreamble,
          '\$env:Path=${powerShellSingleQuote(root.path)} + \';\' + '
          r"$env:SystemRoot + '\System32;' + $env:SystemRoot + '\System32\WindowsPowerShell\v1.0';",
        );
        // Force the oversized-command regression independently of future
        // reductions in the catalog or generated probe script.
        final script = '$isolated\n${'# oversized fixture\n' * 1800}';
        expect(
          buildWindowsPowerShellCommand(script).length,
          greaterThan(32767),
        );
        final command = buildCompactWindowsPowerShellCommand(script);
        expect(command.length, lessThan(7500));
        for (final shell in ['cmd.exe', 'powershell.exe']) {
          final batch = File('${root.path}/probe.cmd');
          await batch.writeAsString('@echo off\r\n$command\r\n');
          final result = await Process.run(shell, [
            if (shell == 'cmd.exe') ...[
              '/d',
              '/c',
              batch.path,
            ] else ...[
              '-NoProfile',
              '-NonInteractive',
              '-Command',
              command,
            ],
          ]).timeout(const Duration(seconds: 60));
          expect(result.exitCode, 0, reason: '${result.stderr}');
          final snapshots = parseAgentBatchProbeOutput(result.stdout as String);
          expect(
            snapshots.keys,
            unorderedEquals(agentRuntimeDefinitions.map((d) => d.id)),
            reason: '$shell: ${result.stdout} ${result.stderr}',
          );
          final copilot = snapshots['cli:copilot']!;
          expect(copilot.executablePath, launcher.path.replaceAll('/', r'\'));
          expect(parseAgentVersion(copilot.versionOutput ?? ''), '1.2.3');
          expect(snapshots['cli:claude']!.executablePath, isNull);
        }
      },
      skip: !Platform.isWindows,
    );

    test('parses installed and missing runtimes independently', () {
      final snapshots = parseAgentBatchProbeOutput(
        'profile chatter\n'
        '__monkeyssh_agent_runtime__=cli:claude\n'
        '__monkeyssh_agent_path__=/home/dev/bin/claude\n'
        '__monkeyssh_agent_version__=claude 1.2.3\n'
        '__monkeyssh_agent_runtime_end__\n'
        '__monkeyssh_agent_runtime__=cli:codex\n'
        '__monkeyssh_agent_runtime_end__\n',
      );

      expect(snapshots['cli:claude']?.executablePath, '/home/dev/bin/claude');
      expect(snapshots['cli:claude']?.versionOutput, 'claude 1.2.3');
      expect(snapshots['cli:codex']?.executablePath, isNull);
    });

    test('retains a detected path from an interrupted runtime block', () {
      final snapshots = parseAgentBatchProbeOutput(
        '__monkeyssh_agent_runtime__=cli:claude\n'
        '__monkeyssh_agent_path__=/home/dev/bin/claude\n'
        '__monkeyssh_agent_runtime__=cli:codex\n'
        '__monkeyssh_agent_runtime_end__\n',
      );

      expect(snapshots['cli:claude']?.executablePath, '/home/dev/bin/claude');
      expect(snapshots['cli:codex']?.executablePath, isNull);
    });

    test('marks skipped postinstall scripts for repair', () {
      final snapshots = parseAgentBatchProbeOutput(
        '__monkeyssh_agent_runtime__=cli:opencode\n'
        '__monkeyssh_agent_path__=/home/dev/bin/opencode\n'
        '__monkeyssh_agent_repair__\n'
        '__monkeyssh_agent_runtime_end__\n',
      );

      expect(snapshots['cli:opencode']?.needsRepair, isTrue);
    });

    test('parses package ownership and latest versions', () {
      final snapshots = parseAgentMetadataProbeOutput(
        '__monkeyssh_agent_runtime__=cli:claude\n'
        '__monkeyssh_agent_source__=npm global\n'
        '__monkeyssh_agent_installed__=2.0.0\n'
        '__monkeyssh_agent_latest__=2.1.3\n'
        '__monkeyssh_agent_runtime_end__\n',
      );

      expect(snapshots['cli:claude']?.detectionSource, 'npm global');
      expect(snapshots['cli:claude']?.installedVersionOutput, '2.0.0');
      expect(snapshots['cli:claude']?.latestVersionOutput, '2.1.3');
    });

    test('retains metadata from an interrupted final block', () {
      final snapshots = parseAgentMetadataProbeOutput(
        '__monkeyssh_agent_runtime__=acp:codex\n'
        '__monkeyssh_agent_source__=npm global\n'
        '__monkeyssh_agent_installed__=1.6.2\n',
      );
      expect(snapshots['acp:codex']?.installedVersionOutput, '1.6.2');
      expect(snapshots['acp:codex']?.latestVersionOutput, isNull);
    });

    test('generated POSIX scripts pass bash syntax validation', () async {
      final definitions = <AgentRuntimeDefinition>[
        ...agentCliRuntimeDefinitions,
        ...agentStandaloneAcpRuntimeDefinitions,
      ];
      final scripts = [
        buildAgentBatchProbeCommand(definitions, windows: false),
        buildAgentMetadataProbeCommand(definitions, windows: false),
        buildAgentInstallCommand(
          agentCliRuntimeDefinitions.first,
          windows: false,
          update: true,
          detectionSource: 'npm global',
        )!,
      ];
      expect(scripts.first, contains('__monkeyssh_agent_repair__'));
      expect(scripts.first, contains('postinstall'));
      expect(scripts.first, contains('--ignore-scripts'));
      for (var index = 0; index < scripts.length; index += 1) {
        final file = File(
          '${Directory.systemTemp.path}/monkeyssh-agent-$index.sh',
        );
        await file.writeAsString(scripts[index]);
        addTearDown(() => file.delete().ignore());
        final result = await Process.run('bash', ['-n', file.path]);
        expect(result.exitCode, 0, reason: 'script $index: ${result.stderr}');
      }
    });

    test('detects versions without waiting for a hanging CLI', () async {
      final root = await Directory.systemTemp.createTemp(
        'monkeyssh-agent-version-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      final bin = Directory('${root.path}/bin')..createSync();
      final quick = File('${bin.path}/quick-agent')
        ..writeAsStringSync('#!/bin/sh\necho "quick-agent 1.2.3"\n');
      final hanging = File('${bin.path}/hanging-agent')
        ..writeAsStringSync('#!/bin/sh\nsleep 20\n');
      final broken = File('${bin.path}/broken-agent')
        ..writeAsStringSync(
          '#!/bin/sh\n'
          'echo "Error: postinstall script was not run due to --ignore-scripts" >&2\n'
          'exit 1\n',
        );
      await Process.run('chmod', ['+x', quick.path, hanging.path, broken.path]);
      const definitions = <AgentRuntimeDefinition>[
        AgentRuntimeDefinition(
          id: 'cli:quick',
          label: 'Quick',
          kind: AgentRuntimeKind.cli,
          executableNames: ['quick-agent'],
        ),
        AgentRuntimeDefinition(
          id: 'cli:hanging',
          label: 'Hanging',
          kind: AgentRuntimeKind.cli,
          executableNames: ['hanging-agent'],
        ),
        AgentRuntimeDefinition(
          id: 'cli:broken',
          label: 'Broken',
          kind: AgentRuntimeKind.cli,
          executableNames: ['broken-agent'],
        ),
      ];
      final script = File('${root.path}/probe.sh')
        ..writeAsStringSync(
          buildAgentBatchProbeCommand(definitions, windows: false),
        );
      final shells = <String>['bash'];
      if (File('/bin/zsh').existsSync()) shells.add('/bin/zsh');
      for (final shell in shells) {
        final stopwatch = Stopwatch()..start();
        final result = await Process.run(
          shell,
          [script.path],
          environment: {
            'HOME': root.path,
            'PATH': '${bin.path}:/usr/bin:/bin',
            'TMPDIR': root.path,
          },
        );
        stopwatch.stop();
        final snapshots = parseAgentBatchProbeOutput(result.stdout as String);

        expect(
          result.exitCode,
          0,
          reason: '$shell: ${result.stderr as String}',
        );
        expect(
          stopwatch.elapsed,
          lessThan(const Duration(seconds: 8)),
          reason: shell,
        );
        expect(
          snapshots['cli:quick']?.executablePath,
          quick.path,
          reason: shell,
        );
        expect(
          snapshots['cli:quick']?.versionOutput,
          'quick-agent 1.2.3',
          reason: shell,
        );
        expect(
          snapshots['cli:hanging']?.executablePath,
          hanging.path,
          reason: shell,
        );
        expect(snapshots['cli:hanging']?.versionOutput, isNull, reason: shell);
        expect(
          snapshots['cli:broken']?.executablePath,
          broken.path,
          reason: shell,
        );
        expect(snapshots['cli:broken']?.needsRepair, isTrue, reason: shell);
      }
    });

    for (final windows in [false, true]) {
      test('queries every standalone ACP package, windows=$windows', () {
        for (final definition in agentStandaloneAcpRuntimeDefinitions) {
          final command = buildAgentMetadataProbeCommand([
            definition,
          ], windows: windows);
          final script = windows ? decodeEncodedPowerShell(command) : command;
          expect(script, contains('npm view'));
          expect(script, contains(definition.packageName));
          expect(script, contains('npm list -g'));
        }
      });
    }

    test('builds one POSIX script containing every requested runtime', () {
      final command = buildAgentBatchProbeCommand(
        agentCliRuntimeDefinitions.take(2).toList(),
        windows: false,
      );

      expect(command, contains('__monkeyssh_agent_runtime__='));
      expect(command, contains("'cli:claude'"));
      expect(command, contains("'cli:copilot'"));
      expect(RegExp('~/.zprofile').allMatches(command), hasLength(1));
    });
  });

  group('single-runtime batch probe', () {
    test('sources login profiles and checks candidate paths on POSIX', () {
      final command = buildAgentBatchProbeCommand([
        agentCliRuntimeDefinitions.first,
      ], windows: false);
      expect(command, contains('~/.zprofile'));
      expect(
        command.replaceAll(r"'\''", "'"),
        contains("'claude' 'claude-code'"),
      );
      expect(command, contains('command -v'));
      expect(command, contains('__monkeyssh_agent_version__='));
      expect(command.replaceAll(r"'\''", "'"), contains("'--version'"));
    });

    test(
      'Windows probe timeouts terminate descendants and handle cleanup failures',
      () async {
        final script = decodeEncodedPowerShell(
          buildAgentBatchProbeCommand([], windows: true),
        );
        final root = await Directory.systemTemp.createTemp(
          'monkeyssh-probe-cleanup-',
        );
        addTearDown(() => root.delete(recursive: true));
        final fixture = File('${root.path}/cleanup.ps1')
          ..writeAsStringSync(
            script +
                r'''
$ErrorActionPreference = 'Stop';
function New-Object([string]$TypeName) {
  if ($TypeName -ne 'System.Diagnostics.Process') { throw "Unexpected type: $TypeName" };
  $process = [pscustomobject]@{
    Id = 12345;
    HasExited = $false;
    ExitCode = 0;
    StartInfo = [pscustomobject]@{
      FileName = ''; Arguments = ''; UseShellExecute = $true;
      CreateNoWindow = $false; RedirectStandardOutput = $false;
      RedirectStandardError = $false;
    };
    StandardOutput = [pscustomobject]@{};
    StandardError = [pscustomobject]@{};
  };
  $process.StandardOutput | Add-Member ScriptMethod ReadToEndAsync { [pscustomobject]@{Result = '1.2.3'} };
  $process.StandardError | Add-Member ScriptMethod ReadToEndAsync { [pscustomobject]@{Result = ''} };
  $process | Add-Member ScriptMethod Start { return $true };
  $process | Add-Member ScriptMethod WaitForExit {
    param($timeout)
    if ($timeout -ne 5000) { throw 'Unexpected timeout' };
    return $script:scenario -eq 'completed';
  };
  $process | Add-Member ScriptMethod Kill {
    $script:events.Add('kill');
    if ($script:scenario -eq 'exit-race') { throw 'Process already exited' };
    $this.HasExited = $true;
  };
  $process | Add-Member ScriptMethod Dispose { $script:events.Add('dispose') };
  $script:probeProcess = $process;
  return $process;
}
function taskkill.exe {
  if (($args -join ' ') -ne '/PID 12345 /T /F') { throw 'Expected forceful tree cleanup for the probe PID' };
  $script:events.Add('tree');
  if ($script:scenario -eq 'unavailable') { throw 'taskkill unavailable' };
  if ($script:scenario -eq 'tree-success') { $script:probeProcess.HasExited = $true };
  $global:LASTEXITCODE = if ($script:probeProcess.HasExited) { 0 } else { 1 };
  'taskkill output must not become a version';
}
foreach ($scenario in @('tree-success', 'tree-failure', 'unavailable', 'exit-race', 'completed')) {
  $script:scenario = $scenario;
  $script:events = [System.Collections.Generic.List[string]]::new();
  $output = Invoke-AgentProbe 'unused';
  $expected = if ($scenario -eq 'completed') { 'dispose' }
    elseif ($scenario -eq 'tree-success') { 'tree,dispose' }
    else { 'tree,kill,dispose' };
  if (($script:events -join ',') -ne $expected) {
    throw "${scenario}: expected $expected, got $script:events";
  };
  if ($scenario -eq 'completed') {
    if ($output -ne '1.2.3') { throw 'Successful version output was lost' };
  } elseif ($null -ne $output) { throw 'A timed-out probe returned output' };
  Write-Output "${scenario}: passed";
}
''',
          );
        final ProcessResult result;
        try {
          result = await Process.run(
            Platform.isWindows ? 'powershell.exe' : 'pwsh',
            [
              '-NoProfile',
              '-NonInteractive',
              '-ExecutionPolicy',
              'Bypass',
              '-File',
              fixture.path,
            ],
          ).timeout(const Duration(seconds: 20));
        } on ProcessException {
          markTestSkipped(
            'PowerShell is required to execute the Windows probe cleanup regression',
          );
          return;
        }
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        for (final scenario in [
          'tree-success',
          'tree-failure',
          'unavailable',
          'exit-race',
          'completed',
        ]) {
          expect(result.stdout, contains('$scenario: passed'));
        }
      },
    );

    test('uses Get-Command and one-line markers on Windows', () {
      final command = buildAgentBatchProbeCommand([
        agentCliRuntimeDefinitions.first,
      ], windows: true);
      final script = decodeEncodedPowerShell(command);
      expect(script, contains(r'$PROFILE.CurrentUserAllHosts'));
      expect(script, contains('Get-Command'));
      expect(
        script,
        contains(r"'__monkeyssh_agent_path__=' + $__flCommand.Source"),
      );
      expect(script, contains('Invoke-AgentProbe'));
      expect(script, contains('__monkeyssh_agent_version__='));
      expect(script, contains('WaitForExit(5000)'));
    });
  });
}

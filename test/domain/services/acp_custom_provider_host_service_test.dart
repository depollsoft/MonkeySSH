// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/acp_protocol.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/services/acp_custom_provider_host_service.dart';
import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_acp_bridge_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

import '../../helpers/mock_ssh_exec_session.dart';
import '../../helpers/mocks.dart';

/// An exec channel that speaks ACP: answers initialize and pages through
/// session/list, ignoring stdin EOF like a stubborn agent would.
class _ScriptedAgentExec {
  _ScriptedAgentExec({required this.supportsList});

  final bool supportsList;
  final exec = MockSessionWithChannel();
  final _stdout = StreamController<Uint8List>();
  final List<Map<String, Object?>> requests = [];

  void install() {
    when(() => exec.stdout).thenAnswer((_) => _stdout.stream);
    when(() => exec.stderr).thenAnswer((_) => const Stream.empty());
    when(() => exec.done).thenAnswer((_) => Completer<void>().future);
    when(exec.close).thenAnswer((_) {});
    when(exec.channel.destroy).thenAnswer((_) {});
    when(() => exec.write(any())).thenAnswer((invocation) {
      final bytes = invocation.positionalArguments.single as Uint8List;
      for (final line in const LineSplitter().convert(utf8.decode(bytes))) {
        if (line.trim().isEmpty) continue;
        _handle((jsonDecode(line) as Map).cast<String, Object?>());
      }
    });
  }

  void _handle(Map<String, Object?> message) {
    requests.add(message);
    final id = message['id'];
    final params = (message['params'] as Map?)?.cast<String, Object?>();
    final result = switch (message['method']) {
      'initialize' => {
        'protocolVersion': 1,
        'agentCapabilities': {
          'sessionCapabilities': {
            if (supportsList) 'list': <String, Object?>{},
          },
        },
      },
      'session/list' when params?['cursor'] == null => {
        'sessions': [
          {
            'sessionId': 'older',
            'cwd': '/work/a',
            'title': 'First',
            'updatedAt': '2026-10-01T00:00:00Z',
          },
        ],
        'nextCursor': 'page-2',
      },
      'session/list' => {
        'sessions': [
          {
            'sessionId': 'newer',
            'cwd': '/work/b',
            'updatedAt': '2026-10-08T00:00:00Z',
          },
        ],
      },
      _ => <String, Object?>{},
    };
    scheduleMicrotask(
      () => _stdout.add(
        Uint8List.fromList(
          utf8.encode(
            '${jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result})}\n',
          ),
        ),
      ),
    );
  }
}

AcpCustomProviderDefinition _approvedAgent() =>
    AcpCustomProviderDefinition.create(
      id: 'goose',
      label: r"Goose\'; touch pwned; #",
      launchCommand: AcpLaunchCommand(
        executable: 'goose',
        arguments: const ['acp', r'x\', '; touch pwned'],
      ),
    ).approve();

String _decodeEncodedPowerShell(String command) {
  final encoded = command.split(' ').last;
  final bytes = base64.decode(encoded);
  final units = <int>[
    for (var index = 0; index + 1 < bytes.length; index += 2)
      bytes[index] | (bytes[index + 1] << 8),
  ];
  return String.fromCharCodes(units);
}

void main() {
  group('environment probe', () {
    test('rejects names that are not plain identifiers', () {
      expect(
        () => buildAcpEnvironmentProbeCommand(const [
          'X;rm -rf ~',
        ], isWindows: false),
        throwsArgumentError,
      );
      expect(
        () => buildAcpEnvironmentProbeCommand(const [], isWindows: false),
        throwsArgumentError,
      );
    });

    test('POSIX probe sources the login profile and prints names only', () {
      final command = buildAcpEnvironmentProbeCommand(const [
        'OPENAI_API_KEY',
      ], isWindows: false);
      expect(command, startsWith('/bin/sh -c '));
      final script = decodeMonkeyMuxLoginShellSafeCommand(command)[4];
      expect(script, contains('. ~/.zprofile'));
      expect(script, contains('OPENAI_API_KEY'));
      expect(script, isNot(contains('printenv')));
      expect(script, isNot(contains(r'echo "$OPENAI_API_KEY"')));
    });

    test('Windows probe checks each variable with PowerShell', () {
      final script = _decodeEncodedPowerShell(
        buildAcpEnvironmentProbeCommand(const ['API_KEY'], isWindows: true),
      );
      expect(script, contains(r'[string]::IsNullOrEmpty($env:API_KEY)'));
      expect(script, contains('monkeyssh-env-unset:API_KEY'));
    });

    test('parses only requested names behind the marker', () {
      expect(
        parseAcpEnvironmentProbeOutput(
          'profile noise\n'
          'monkeyssh-env-unset:B_KEY\r\n'
          'monkeyssh-env-unset:INJECTED\n'
          'monkeyssh-env-unset:A_KEY\n',
          const ['A_KEY', 'B_KEY', 'C_KEY'],
        ),
        ['A_KEY', 'B_KEY'],
      );
    });

    test(
      'reports exported variables as set and others as unset, never values',
      () async {
        final home = await Directory.systemTemp.createTemp('acp-env-home');
        addTearDown(() => home.delete(recursive: true));
        // A profile export is visible to the agent; a plain shell variable is
        // not exported, so the agent would not see it either.
        await File('${home.path}/.profile')
            .writeAsString('export FROM_PROFILE=1\nNOT_EXPORTED=1\n');
        final command = buildAcpEnvironmentProbeCommand(const [
          'FROM_PROFILE',
          'FROM_ENVIRONMENT',
          'NOT_EXPORTED',
          'EMPTY_VALUE',
          'MISSING',
        ], isWindows: false);
        final result = await Process.run(
          '/bin/sh',
          ['-c', command],
          environment: {
            'HOME': home.path,
            // MonkeyMux runs the provider under a bash/zsh login shell.
            'SHELL': '/bin/bash',
            'PATH': '/usr/bin:/bin',
            'FROM_ENVIRONMENT': 'super-secret-value',
            'EMPTY_VALUE': '',
          },
          includeParentEnvironment: false,
        );
        final output = result.stdout as String;
        expect(output, isNot(contains('super-secret-value')));
        expect(
          parseAcpEnvironmentProbeOutput(output, const [
            'FROM_PROFILE',
            'FROM_ENVIRONMENT',
            'NOT_EXPORTED',
            'EMPTY_VALUE',
            'MISSING',
          ]),
          ['NOT_EXPORTED', 'EMPTY_VALUE', 'MISSING'],
        );
      },
      testOn: 'mac-os || linux',
    );
  });

  group('listSessions', () {
    setUpAll(() => registerFallbackValue(Uint8List(0)));

    Future<(AcpCustomAgentSessionListing, _ScriptedAgentExec, String)> run({
      required bool supportsList,
    }) async {
      final agent = _ScriptedAgentExec(supportsList: supportsList)..install();
      final client = MockSshClient();
      final commands = <String>[];
      when(() => client.execute(any(), pty: any(named: 'pty')))
          .thenAnswer((invocation) async {
            commands.add(invocation.positionalArguments.single as String);
            return agent.exec;
          });
      final session = SshSession(
        connectionId: 41,
        hostId: 1,
        client: client,
        config: const SshConnectionConfig(
          hostname: 'host',
          port: 22,
          username: 'u',
        ),
      );
      final listing = await AcpCustomProviderHostService(
        diagnostics: const NoopDiagnosticsLogger(),
      ).listSessions(session, _approvedAgent());
      return (listing, agent, commands.single);
    }

    test('pages through session/list, newest first, then destroys the '
        'channel', () async {
      final (listing, agent, command) = await run(supportsList: true);

      expect(listing.status, AcpCustomAgentSessionListStatus.listed);
      expect(listing.sessions.map((session) => session.sessionId), [
        'newer',
        'older',
      ]);
      expect(agent.requests.map((request) => request['method']), [
        'initialize',
        'session/list',
        'session/list',
      ]);
      expect((agent.requests.last['params']! as Map)['cursor'], 'page-2');
      // The agent ignored EOF, so the channel is destroyed, not left open.
      verify(agent.exec.channel.destroy).called(1);
      // The approved argv and label never reach the login shell as text.
      expect(command, isNot(contains('touch')));
      expect(
        decodeMonkeyMuxLoginShellSafeCommand(command)[4],
        endsWith(r"exec 'goose' 'acp' 'x\' '; touch pwned'"),
      );
    });

    test('reports an agent without session/list', () async {
      final (listing, agent, _) = await run(supportsList: false);
      expect(listing.status, AcpCustomAgentSessionListStatus.unsupportedAgent);
      expect(agent.requests.map((request) => request['method']), [
        'initialize',
      ]);
      verify(agent.exec.channel.destroy).called(1);
    });
  });

  test('session timestamps order newest first and tolerate absence', () {
    const newer = AcpSessionInfo(
      sessionId: 'a',
      cwd: '/repo',
      updatedAt: '2026-10-09T10:00:00Z',
    );
    const older = AcpSessionInfo(
      sessionId: 'b',
      cwd: '/repo',
      updatedAt: 1700000000000,
    );
    const unknown = AcpSessionInfo(sessionId: 'c', cwd: '/repo');
    expect(
      acpSessionInfoUpdatedAt(newer).isAfter(acpSessionInfoUpdatedAt(older)),
      isTrue,
    );
    expect(acpSessionInfoUpdatedAt(unknown).millisecondsSinceEpoch, 0);
  });
}

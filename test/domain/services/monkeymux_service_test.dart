// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:dartssh2/src/ssh_channel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/domain/models/terminal_progress.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/monkeymux_installer_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_service.dart';
import 'package:monkeyssh/domain/services/ssh_exec_queue.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

void main() {
  group('short-lived exec deadlines', () {
    setUpAll(() => registerFallbackValue(Uint8List(0)));

    for (final operation in ['one-shot', 'server-status', 'helper-version']) {
      for (final opens in [false, true]) {
        testWidgets(
          '$operation bounds ${opens ? 'busy output' : 'channel opening'}',
          (tester) async {
            final client = _MockSshClient();
            final installer = _MockMonkeyMuxInstaller();
            final session = _buildSession(client, connectionId: 88001);
            final service = MonkeyMuxService(installer: installer);
            final opening = Completer<SSHSession>();
            final stdout = StreamController<Uint8List>();
            final channel = _buildSilentControlSession(stdout);
            final underlying = _MockChannel();
            when(() => channel.channel).thenReturn(underlying);
            when(
              () => installer.ensureInstalled(
                session,
                priority: SshExecPriority.normal,
              ),
            ).thenAnswer((_) async => _fakeInstallation);
            when(
              () => client.execute(any(), pty: any(named: 'pty')),
            ).thenAnswer((_) => opens ? Future.value(channel) : opening.future);
            final request = switch (operation) {
              'one-shot' => service.injectInput(session, 'work', 'x'),
              'server-status' => service.runningServerStatus(
                session,
                _fakeInstallation,
                'work',
              ),
              _ => service.installedHelperVersion(session, _fakeInstallation),
            };
            final result = expectLater(
              request,
              operation == 'one-shot'
                  ? throwsA(isA<TimeoutException>())
                  : completion(isNull),
            );
            await tester.pump();
            final blocker = Completer<void>();
            final blocked = session.runQueuedExec(() => blocker.future);
            var nextRan = false;
            final next = session.runQueuedExec(() async {
              nextRan = true;
            });
            expect(
              pendingQueuedSshExecCountForTesting(session.connectionId),
              1,
            );
            for (var second = 0; second < (opens ? 11 : 21); second++) {
              if (opens && stdout.hasListener) {
                stdout.add(
                  Uint8List.fromList(
                    utf8.encode(
                      '{"type":"window_list","id":"unrelated","windows":[]}\n',
                    ),
                  ),
                );
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
              verify(underlying.destroy).called(1);
            }
            verify(
              () => client.execute(any(), pty: any(named: 'pty')),
            ).called(1);
            blocker.complete();
            await blocked;
            stdout.close().ignore();
            await service.clearCache(session.connectionId);
          },
        );
      }
    }
  });

  group('RemoteMuxBackendPresentation', () {
    test('parses stable storage values', () {
      expect(
        RemoteMuxBackendPresentation.fromStorageValue('auto'),
        RemoteMuxBackend.auto,
      );
      expect(
        RemoteMuxBackendPresentation.fromStorageValue('monkey_mux'),
        RemoteMuxBackend.monkeyMux,
      );
      expect(
        RemoteMuxBackendPresentation.fromStorageValue('tmux'),
        RemoteMuxBackend.tmux,
      );
      expect(RemoteMuxBackendPresentation.fromStorageValue(''), isNull);
    });

    test('keeps tmux extra flags on tmux startup', () {
      expect(
        resolveRemoteMuxBackendForStartup(
          storedBackend: 'auto',
          tmuxExtraFlags: '-f ~/.tmux.conf',
        ),
        RemoteMuxBackend.tmux,
      );
      expect(
        resolveRemoteMuxBackendForStartup(
          storedBackend: 'auto',
          tmuxExtraFlags: '',
        ),
        RemoteMuxBackend.auto,
      );
    });
  });

  group('buildMonkeyMuxAttachCommand', () {
    test('passes the force reload policy to attach', () {
      final command = buildMonkeyMuxAttachCommand(
        executablePath: '/home/me/.monkeyssh/bin/monkeymux',
        sessionName: 'work',
        serverUpdatePolicy: MonkeyMuxServerUpdatePolicy.force,
      );

      expect(
        command,
        "'/home/me/.monkeyssh/bin/monkeymux' attach --quiet "
        "--update-policy force 'work'",
      );
    });

    test('puts flags before the session and shell-quotes values', () {
      final command = buildMonkeyMuxAttachCommand(
        executablePath: '/home/me/.monkeyssh/bin/monkey mux',
        sessionName: "work'space",
        clientId: 'app 7',
        clipViewport: true,
        workingDirectory: "~/src/it's app",
        windowName: 'Codex agent',
        launchCommand: "codex --model 'gpt-5.4'",
        serverUpdatePolicy: MonkeyMuxServerUpdatePolicy.never,
        startInYoloMode: true,
      );

      expect(
        command,
        "'/home/me/.monkeyssh/bin/monkey mux' attach --quiet "
        "--client-id 'app 7' --clip-viewport --update-policy never "
        r"--restore-yolo --cwd '~/src/it'\''s app' --name 'Codex agent' --command "
        r"'codex --model '\''gpt-5.4'\''' 'work'\''space'",
      );
    });

    test('passes terminal theme reports as base64 data', () {
      final command = buildMonkeyMuxAttachCommand(
        executablePath: '/home/me/.monkeyssh/bin/monkeymux',
        sessionName: 'work',
        terminalThemeReports: '\x1b]11;rgb:0000/1111/2222\x1b\\',
      );

      expect(
        command,
        "'/home/me/.monkeyssh/bin/monkeymux' attach --quiet "
        '--theme-hint-base64 '
        'G10xMTtyZ2I6MDAwMC8xMTExLzIyMjIbXA== '
        "'work'",
      );
    });

    test('passes terminal capability reports as base64 data', () {
      final command = buildMonkeyMuxAttachCommand(
        executablePath: '/home/me/.monkeyssh/bin/monkeymux',
        sessionName: 'work',
        terminalCapabilityReports: 'da1\x1f\x1b[?62;22c',
      );

      expect(
        command,
        "'/home/me/.monkeyssh/bin/monkeymux' attach --quiet "
        '--capability-hint-base64 '
        '${base64Encode(utf8.encode('da1\x1f\x1b[?62;22c'))} '
        "'work'",
      );
    });

    test('passes explicit viewport dimensions for raw SSH attach', () {
      final command = buildMonkeyMuxAttachCommand(
        executablePath: r'C:\Users\me\monkeymux.exe',
        sessionName: 'work',
        terminalColumns: 69,
        terminalRows: 55,
        existingOnly: true,
        windows: true,
      );

      expect(command, contains('--width 69 --height 55'));
      expect(command, contains('--existing'));
      expect(command, endsWith(' work'));
    });

    test('escapes arguments for Windows argv parsing', () {
      final command = buildMonkeyMuxAttachCommand(
        executablePath: r'C:\Program Files\mm\monkeymux.exe',
        sessionName: 'workspace',
        workingDirectory: r'C:\src\my app\',
        windowName: 'Codex agent',
        launchCommand: 'python -c "print(1)"',
        serverUpdatePolicy: MonkeyMuxServerUpdatePolicy.never,
        windows: true,
      );

      // Values with spaces are wrapped in double quotes; a trailing backslash
      // before the closing quote is doubled and embedded quotes are
      // backslash-escaped so CommandLineToArgvW recovers the exact argument.
      expect(
        command,
        r'"C:\Program Files\mm\monkeymux.exe" attach --quiet '
        '--update-policy never '
        r'--cwd "C:\src\my app\\" --name "Codex agent" '
        r'--command "python -c \"print(1)\"" workspace',
      );
    });

    test('leaves space-free Windows arguments unquoted', () {
      final command = buildMonkeyMuxAttachCommand(
        executablePath: r'C:\mm\monkeymux.exe',
        sessionName: 'work',
        windows: true,
      );

      expect(command, r'C:\mm\monkeymux.exe attach --quiet work');
    });

    test('uses a unique app client id for each SSH session', () {
      SshSession createSession() => SshSession(
        connectionId: 42,
        hostId: 1,
        client: _MockSshClient(),
        config: const SshConnectionConfig(
          hostname: 'example.com',
          port: 22,
          username: 'demo',
        ),
      );

      final first = createSession();
      final second = createSession();

      expect(first.monkeyMuxClientId, startsWith('monkeyssh-42-'));
      expect(second.monkeyMuxClientId, isNot(first.monkeyMuxClientId));
    });
  });

  group('MonkeyMuxServerStatus', () {
    test('detects version mismatches and shutdown capability', () {
      const status = MonkeyMuxServerStatus(
        version: '0.1.13',
        capabilities: {
          'window-list',
          'shutdown',
          'client-viewport-clipping',
          'inject-input-bracketed-paste',
        },
      );

      expect(status.supportsShutdown, isTrue);
      expect(status.hasNativeAcpWindows, isFalse);
      expect(status.nativeAcpWindowCount, 0);
      expect(status.supportsBracketedPasteControlInput, isTrue);
      expect(status.needsUpdate('0.1.13'), isFalse);
      expect(status.needsUpdate('0.1.14'), isTrue);
    });
  });

  group('MonkeyMuxImageReplayResult', () {
    test('retries only unserved ids after a transport failure', () {
      final result = MonkeyMuxImageReplayResult(
        served: const {7},
        retryableFailure: true,
      );

      expect(result.retryableUnserved(const {7, 8, 9}), {8, 9});
    });

    test('keeps explicitly non-retryable missing ids suppressed', () {
      final result = MonkeyMuxImageReplayResult(
        served: const {7},
        retryableFailure: false,
      );

      expect(result.retryableUnserved(const {7, 8, 9}), isEmpty);
    });

    test('acknowledged empty batch keeps requested ids retryable', () {
      final result = resolveMonkeyMuxImageReplayBatchForTesting(
        requested: const {7, 8},
        alreadyServed: const <int>{},
        acknowledged: true,
        responseImageIds: const <String>[],
      );

      expect(result.served, isEmpty);
      expect(result.retryableUnserved(const {7, 8}), {7, 8});
    });

    test('partial batch preserves served ids and retries the remainder', () {
      final result = resolveMonkeyMuxImageReplayBatchForTesting(
        requested: const {7, 8, 9},
        alreadyServed: const {7},
        acknowledged: true,
        responseImageIds: const ['8'],
      );

      expect(result.served, {7, 8});
      expect(result.retryableUnserved(const {7, 8, 9}), {9});
    });
  });

  group('MonkeyMux control responses', () {
    test('parse foreground attach state', () {
      final hasForegroundClient = parseMonkeyMuxHasForegroundClientForTesting(
        '{"type":"attach_state","status":"ok","hasForegroundClient":true}',
      );

      expect(hasForegroundClient, isTrue);
    });

    test('parses served image ids from replay acknowledgement', () {
      final response = parseMonkeyMuxImageReplayAckForTesting(
        '{"type":"images_replayed","status":"ok",'
        '"imagesAcknowledged":true,"imageIds":["17","23"]}',
      );

      expect(response?.acknowledged, isTrue);
      expect(response?.imageIds, ['17', '23']);
    });

    test('parses whether focus changed the primary client', () {
      expect(
        parseMonkeyMuxFocusChangedForTesting(
          '{"type":"client_focused","status":"ok","focusChanged":true}',
        ),
        isTrue,
      );
      expect(
        parseMonkeyMuxFocusChangedForTesting(
          '{"type":"client_focused","status":"ok"}',
        ),
        isFalse,
      );
    });

    test('allows one-shot run_command responses to reach server timeout', () {
      expect(
        monkeyMuxOneShotResponseTimeoutForTesting(const <String, Object?>{
          'type': 'run_command',
        }),
        const Duration(seconds: 25),
      );
      expect(
        monkeyMuxOneShotResponseTimeoutForTesting(const <String, Object?>{
          'type': 'list_windows',
        }),
        const Duration(seconds: 10),
      );
    });
  });

  group('parseMonkeyMuxWindowSnapshotForTesting', () {
    test('ignores legacy Gemini agent metadata from older helpers', () {
      for (final name in ['Gemini CLI', 'Codex']) {
        final window = parseMonkeyMuxWindowSnapshotForTesting({
          'id': '@1',
          'index': 0,
          'name': name,
          'active': true,
          'currentCommand': 'node',
          'agentTool': 'gemini',
          'agentSessionId': 'legacy-gemini-session',
          'agentSessionIdentityExact': true,
        });
        expect(window, isNotNull);
        expect(window!.agentTool, isNull);
        expect(window.activeAgentSessionId, isNull);
        expect(window.activeAgentSessionConfidence, isNull);
        expect(window.foregroundAgentTool, isNull);
        expect(window.hasUnsupportedAgentTool, isTrue);
        expect(
          window.copyWith(currentCommand: 'copilot').foregroundAgentTool,
          AgentLaunchTool.copilotCli,
        );
      }
    });

    test('confirmed plain shells do not regain identity from their names', () {
      for (final storedTool in [null, '']) {
        final window = parseMonkeyMuxWindowSnapshotForTesting({
          'id': '@1',
          'index': 0,
          'name': 'Codex',
          'paneTitle': 'Claude Code',
          'currentCommand': 'zsh',
          'agentTool': storedTool,
          'agentToolConfirmed': true,
          'agentSessionId': 'stale-session',
          'agentSessionIdentityExact': true,
        })!;
        expect(window.foregroundAgentTool, isNull);
        expect(window.activeAgentSessionId, isNull);
        expect(window.agentSessionId, isNull);
        expect(window.activeAgentSessionConfidence, isNull);
        expect(
          window.copyWith(currentCommand: 'copilot').foregroundAgentTool,
          AgentLaunchTool.copilotCli,
        );
      }
    });

    test('maps helper agentTool metadata onto tmux windows', () {
      final window = parseMonkeyMuxWindowSnapshotForTesting({
        'id': '@1',
        'index': 0,
        'name': 'Cursor Agent',
        'active': true,
        'currentCommand': 'node',
        'panePid': 1234,
        'agentTool': 'cursor-agent',
      });

      expect(window, isNotNull);
      expect(window!.foregroundAgentTool, AgentLaunchTool.cursorAgent);
    });

    test('maps server-owned native ACP identity onto real windows', () {
      final window = parseMonkeyMuxWindowSnapshotForTesting({
        'id': '@7',
        'index': 6,
        'name': 'Pi',
        'active': true,
        'currentPath': '/home/demo/project',
        'nativeAcpBridgeId': '0123456789abcdef0123456789abcdef',
        'nativeAcpProviderId': 'builtin:pi-acp',
      });

      expect(window, isNotNull);
      expect(window!.isNativeAcp, isTrue);
      expect(window.nativeAcpBridgeId, '0123456789abcdef0123456789abcdef');
      expect(window.nativeAcpProviderId, 'builtin:pi-acp');
      expect(window.copyWith(isActive: false).isNativeAcp, isTrue);
    });

    test('maps exact live Cursor session metadata onto tmux windows', () {
      final window = parseMonkeyMuxWindowSnapshotForTesting({
        'id': '@2',
        'index': 1,
        'name': 'Cursor Agent',
        'active': true,
        'currentCommand': 'cursor-agent',
        'panePid': 4321,
        'agentTool': 'cursor-agent',
        'agentSessionId': 'cursor-chat-id',
        'agentSessionIdentityExact': true,
      });

      expect(window, isNotNull);
      expect(window!.foregroundAgentTool, AgentLaunchTool.cursorAgent);
      expect(window.activeAgentSessionId, 'cursor-chat-id');
      expect(window.activeAgentSessionConfidence, AgentSessionConfidence.high);
    });

    test('maps helper terminal progress metadata onto tmux windows', () {
      final window = parseMonkeyMuxWindowSnapshotForTesting({
        'id': '@1',
        'index': 0,
        'name': 'Build',
        'active': false,
        'terminalProgress': {'state': 2, 'percentage': 63},
      });

      expect(window, isNotNull);
      expect(
        window!.terminalProgress,
        const TerminalProgress(
          state: TerminalProgressState.error,
          percentage: 63,
        ),
      );
    });

    test('ignores invalid helper terminal progress metadata', () {
      final window = parseMonkeyMuxWindowSnapshotForTesting({
        'id': '@1',
        'index': 0,
        'name': 'Build',
        'active': false,
        'terminalProgress': {'state': 1, 'percentage': 101},
      });

      expect(window, isNotNull);
      expect(window!.terminalProgress, isNull);
    });

    test('maps helper terminal mouse mode metadata onto tmux windows', () {
      final window = parseMonkeyMuxWindowSnapshotForTesting({
        'id': '@1',
        'index': 0,
        'name': 'Mouse app',
        'active': true,
        'terminalReportsMouseWheel': true,
        'terminalMouseReportSgr': true,
        'terminalBracketedPasteMode': true,
      });

      expect(window, isNotNull);
      expect(window!.terminalReportsMouseWheel, isTrue);
      expect(window.terminalMouseReportSgr, isTrue);
      expect(window.terminalBracketedPasteMode, isTrue);
    });

    test('maps helper private mode metadata onto tmux windows', () {
      final window = parseMonkeyMuxWindowSnapshotForTesting({
        'id': '@1',
        'index': 0,
        'name': 'Mouse app',
        'active': true,
        'privateModes': {'1002': true, '1006': true, '2004': true},
      });

      expect(window, isNotNull);
      expect(window!.terminalReportsMouseWheel, isTrue);
      expect(window.terminalMouseReportSgr, isTrue);
      expect(window.terminalBracketedPasteMode, isTrue);
    });

    test(
      'leaves bracketed paste mode unknown when helper omits mode metadata',
      () {
        final window = parseMonkeyMuxWindowSnapshotForTesting({
          'id': '@1',
          'index': 0,
          'name': 'Shell',
          'active': true,
        });

        expect(window, isNotNull);
        expect(window!.terminalBracketedPasteMode, isNull);
      },
    );

    test('uses explicit helper bracketed paste mode when present', () {
      final window = parseMonkeyMuxWindowSnapshotForTesting({
        'id': '@1',
        'index': 0,
        'name': 'Shell',
        'active': true,
        'terminalBracketedPasteMode': false,
        'privateModes': {'2004': true},
      });

      expect(window, isNotNull);
      expect(window!.terminalBracketedPasteMode, isFalse);
    });

    test('surfaces the alert flag so prompts trigger push notifications', () {
      final window = parseMonkeyMuxWindowSnapshotForTesting({
        'id': '@2',
        'index': 1,
        'name': 'Claude Code',
        'active': false,
        'currentCommand': 'claude',
        'panePid': 4321,
        'flags': '#',
      });

      expect(window, isNotNull);
      expect(window!.flags, '#');
      expect(window.hasAlert, isTrue);
    });

    test('leaves windows without an alert flag un-alerted', () {
      final window = parseMonkeyMuxWindowSnapshotForTesting({
        'id': '@3',
        'index': 2,
        'name': 'shell',
        'active': false,
        'currentCommand': 'zsh',
      });

      expect(window, isNotNull);
      expect(window!.hasAlert, isFalse);
    });
  });

  group('MonkeyMux agent metadata', () {
    test('refreshes metadata for every supported agent pane', () {
      const windows = [
        TmuxWindow(
          index: 0,
          name: 'Codex',
          isActive: true,
          currentCommand: 'codex',
          panePid: 42,
        ),
        TmuxWindow(
          index: 1,
          name: 'shell',
          isActive: false,
          currentCommand: 'zsh',
          panePid: 43,
        ),
      ];

      expect(shouldRefreshMonkeyMuxAgentMetadataForTesting(windows), isTrue);
      expect(
        shouldRefreshMonkeyMuxAgentMetadataForTesting(const [
          TmuxWindow(
            index: 1,
            name: 'shell',
            isActive: false,
            currentCommand: 'zsh',
            panePid: 43,
          ),
        ]),
        isFalse,
      );
    });

    test('applies all-agent metadata with confidence to matching panes', () {
      const sep = tmuxWindowFieldSeparator;
      const windows = [
        TmuxWindow(
          index: 0,
          name: 'Codex',
          isActive: true,
          currentCommand: 'codex',
          panePid: 42,
        ),
        TmuxWindow(
          index: 1,
          name: 'Cursor',
          isActive: false,
          currentCommand: 'cursor-agent',
          panePid: 43,
        ),
      ];

      final enriched = applyMonkeyMuxAgentMetadataForTesting(
        windows,
        'codex${sep}codex-session${sep}501${sep}42${sep}medium$sep\n'
        'cursor-agent${sep}cursor-agent-session${sep}502${sep}43${sep}medium${sep}Cursor title\n',
      );

      expect(enriched[0].activeAgentSessionId, 'codex-session');
      expect(
        enriched[0].activeAgentSessionConfidence,
        AgentSessionConfidence.medium,
      );
      expect(enriched[1].activeAgentSessionId, 'cursor-agent-session');
      expect(enriched[1].agentSessionTitle, 'Cursor title');
      expect(
        enriched[1].activeAgentSessionConfidence,
        AgentSessionConfidence.medium,
      );
    });

    for (final (name, oldId, oldTitle, output, id, title, displayTitle) in [
      (
        'live title',
        null,
        null,
        'copilot\x1fsession-1\x1f501\x1f42\x1fmedium\x1fImplement MonkeyMux refresh\n',
        'session-1',
        'Implement MonkeyMux refresh',
        'Implement MonkeyMux refresh',
      ),
      (
        'absent metadata',
        'stale-session',
        'Stale Copilot session',
        '',
        'stale-session',
        'Stale Copilot session',
        'Stale Copilot session',
      ),
      (
        'untitled replacement',
        'session-a',
        'Task A',
        'copilot\x1fsession-b\x1f501\x1f42\x1fmedium\x1f\n',
        'session-b',
        null,
        'Copilot CLI',
      ),
    ]) {
      test('Copilot metadata: $name', () {
        final original = [
          TmuxWindow(
            index: 1,
            id: '@7',
            panePid: 42,
            name: 'Copilot CLI',
            isActive: true,
            currentCommand: 'copilot',
            paneTitle: 'Copilot CLI',
            activeAgentSessionId: oldId,
            agentSessionTitle: oldTitle,
            activeAgentSessionConfidence: name == 'untitled replacement'
                ? AgentSessionConfidence.high
                : null,
          ),
        ];
        final windows = applyMonkeyMuxAgentMetadataForTesting(original, output);
        expect(windows.single.activeAgentSessionId, id);
        expect(windows.single.agentSessionTitle, title);
        expect(windows.single.displayTitle, displayTitle);
        if (output.isEmpty) expect(windows, same(original));
        if (name == 'untitled replacement') {
          expect(
            windows.single.activeAgentSessionConfidence,
            AgentSessionConfidence.medium,
          );
          expect(
            applyMonkeyMuxAgentMetadataForTesting(windows, output),
            same(windows),
          );
        }
      });
    }
  });

  group('MonkeyMux input injection', () {
    setUpAll(() => registerFallbackValue(Uint8List(0)));

    test('caches bracketed input support from a one-shot hello', () async {
      final client = _MockSshClient();
      final installer = _MockMonkeyMuxInstaller();
      final session = _buildSession(client, connectionId: 898);
      final stdoutController = StreamController<Uint8List>();
      final controlSession = _buildSilentControlSession(stdoutController);

      when(
        () => installer.ensureInstalled(
          session,
          priority: SshExecPriority.normal,
        ),
      ).thenAnswer((_) async => _fakeInstallation);
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => controlSession);
      when(() => controlSession.write(any())).thenAnswer((invocation) {
        final data = invocation.positionalArguments.single as List<int>;
        final request = jsonDecode(utf8.decode(data)) as Map<String, Object?>;
        final hello = jsonEncode({
          'type': 'hello',
          'status': 'ok',
          'version': '0.1.151',
          'capabilities': ['inject-input-bracketed-paste'],
        });
        final response = jsonEncode({
          'id': request['id'],
          'type': 'window_list',
          'status': 'ok',
          'windows': const <Object?>[],
        });
        scheduleMicrotask(
          () => stdoutController.add(
            Uint8List.fromList(utf8.encode('$hello\n$response\n')),
          ),
        );
      });

      final service = MonkeyMuxService(
        installer: installer,
        agentSessionMetadataPeriodicRefreshInterval: Duration.zero,
      );
      expect(
        service.supportsBracketedPasteControlInput(session, 'work'),
        isFalse,
      );

      expect(await service.listWindows(session, 'work'), isEmpty);
      expect(
        service.supportsBracketedPasteControlInput(session, 'work'),
        isTrue,
      );

      await service.resetServerRuntime(898, 'work');
      expect(
        service.supportsBracketedPasteControlInput(session, 'work'),
        isFalse,
      );
      verifyNever(() => installer.clearCache(898));

      await stdoutController.close();
      await service.clearCache(898);
      verify(() => installer.clearCache(898)).called(1);
    });

    for (final clearConnection in [false, true]) {
      test(
        'late window list cannot refill cache after clear=$clearConnection',
        () async {
          final client = _MockSshClient();
          final installer = _MockMonkeyMuxInstaller();
          final session = _buildSession(client, connectionId: 896);
          final pending = Completer<SSHSession>();
          final oldOutput = StreamController<Uint8List>();
          final newOutput = StreamController<Uint8List>();
          final finalOutput = StreamController<Uint8List>();
          final oldControl = _buildRespondingControlSession(
            oldOutput,
            window: {
              ..._fakeWindowJson,
              'name': 'Old helper',
              'agentSessionId': 'old-session',
            },
          );
          final newControl = _buildRespondingControlSession(
            newOutput,
            window: {
              ..._fakeWindowJson,
              'name': 'Replacement helper',
              'agentSessionId': 'new-session',
            },
          );
          final finalControl = _buildRespondingControlSession(
            finalOutput,
            window: {..._fakeWindowJson, 'name': 'Replacement helper'},
          );
          when(
            () => installer.ensureInstalled(
              session,
              priority: SshExecPriority.normal,
            ),
          ).thenAnswer((_) async => _fakeInstallation);
          var opens = 0;
          when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer(
            (_) => switch (opens++) {
              0 => pending.future,
              1 => Future.value(newControl),
              _ => Future.value(finalControl),
            },
          );
          final service = MonkeyMuxService(
            installer: installer,
            agentSessionMetadataPeriodicRefreshInterval: Duration.zero,
          );
          addTearDown(() async {
            await service.clearCache(896);
            await oldOutput.close();
            await newOutput.close();
            await finalOutput.close();
          });
          final old = service.listWindows(session, 'work');
          await untilCalled(
            () => client.execute(any(), pty: any(named: 'pty')),
          );
          if (clearConnection) {
            await service.clearCache(896);
          } else {
            await service.resetServerRuntime(896, 'work');
          }
          expect(
            (await service.listWindows(session, 'work')).single.name,
            'Replacement helper',
          );
          pending.complete(oldControl);
          expect((await old).single.name, 'Old helper');
          final after = (await service.listWindows(session, 'work')).single;
          expect(after.name, 'Replacement helper');
          expect(after.activeAgentSessionId, 'new-session');
          expect(opens, 3);
        },
      );
    }

    test('recycles a watcher without closing existing consumers', () async {
      final client = _MockSshClient();
      final installer = _MockMonkeyMuxInstaller();
      final session = _buildSession(client, connectionId: 897);
      final oldOutput = StreamController<Uint8List>();
      final newOutput = StreamController<Uint8List>();
      final oldControl = _buildRespondingControlSession(
        oldOutput,
        window: {..._fakeWindowJson, 'name': 'Old helper'},
      );
      final newControl = _buildRespondingControlSession(
        newOutput,
        window: {..._fakeWindowJson, 'name': 'Replacement helper'},
      );
      var opens = 0;

      when(
        () => installer.ensureInstalled(session),
      ).thenAnswer((_) async => _fakeInstallation);
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => opens++ == 0 ? oldControl : newControl);

      final service = MonkeyMuxService(
        installer: installer,
        agentSessionMetadataPeriodicRefreshInterval: Duration.zero,
      );
      var streamClosed = false;
      final subscription = service
          .watchWindowChanges(session, 'work')
          .listen((_) {}, onDone: () => streamClosed = true);

      expect(
        (await service.listWindows(session, 'work')).single.name,
        'Old helper',
      );
      await service.resetServerRuntime(897, 'work');
      expect(streamClosed, isFalse);
      expect(
        (await service.refreshWindows(session, 'work')).single.name,
        'Replacement helper',
      );
      expect(opens, 2);

      await subscription.cancel();
      await oldOutput.close();
      await newOutput.close();
      await service.clearCache(897);
    });

    test('window actions prefer stable IDs and fall back to indices', () async {
      final client = _MockSshClient();
      final installer = _MockMonkeyMuxInstaller();
      final session = _buildSession(client);
      final output = StreamController<Uint8List>();
      final control = _buildRespondingControlSession(
        output,
        window: _fakeWindowJson,
      );
      when(
        () => installer.ensureInstalled(session),
      ).thenAnswer((_) async => _fakeInstallation);
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => control);
      final service = MonkeyMuxService(
        installer: installer,
        agentSessionMetadataPeriodicRefreshInterval: Duration.zero,
      )..watchWindowChanges(session, 'work');
      addTearDown(() async {
        await service.clearCache(session.connectionId);
        await output.close();
      });

      await service.selectWindow(session, 'work', 2, windowId: '@7');
      await service.killWindow(session, 'work', 2, windowId: '@7');
      await service.killWindow(session, 'work', 2);

      final requests = verify(() => control.write(captureAny())).captured
          .map(
            (data) =>
                jsonDecode(utf8.decode(data as List<int>))
                    as Map<String, Object?>,
          )
          .toList();
      expect(requests.map((request) => request['type']), [
        'select_window',
        'close_window',
        'close_window',
      ]);
      expect(requests.map((request) => request['windowId']), [
        '@7',
        '@7',
        null,
      ]);
      expect(requests.map((request) => request['windowIndex']), [
        null,
        null,
        2,
      ]);
    });

    test('preserves an exact bracketed paste in one control request', () async {
      final client = _MockSshClient();
      final installer = _MockMonkeyMuxInstaller();
      final session = _buildSession(client, connectionId: 899);
      final stdoutController = StreamController<Uint8List>();
      final controlSession = _buildSilentControlSession(stdoutController);
      final requests = <Map<String, Object?>>[];

      when(
        () => installer.ensureInstalled(session),
      ).thenAnswer((_) async => _fakeInstallation);
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => controlSession);
      when(() => controlSession.write(any())).thenAnswer((invocation) {
        final data = invocation.positionalArguments.single as List<int>;
        final request = jsonDecode(utf8.decode(data)) as Map<String, Object?>;
        requests.add(request);
        final hello = jsonEncode({
          'type': 'hello',
          'status': 'ok',
          'version': '0.1.151',
          'capabilities': ['inject-input-bracketed-paste'],
        });
        final response = jsonEncode({
          'id': request['id'],
          'type': 'input_injected',
          'status': 'ok',
        });
        scheduleMicrotask(
          () => stdoutController.add(
            Uint8List.fromList(utf8.encode('$hello\n$response\n')),
          ),
        );
      });

      final service = MonkeyMuxService(
        installer: installer,
        agentSessionMetadataPeriodicRefreshInterval: Duration.zero,
      )..watchWindowChanges(session, 'work');
      const paste = '\x1b[200~/tmp/image.png\x1b[201~ ';

      expect(
        service.supportsBracketedPasteControlInput(session, 'work'),
        isFalse,
      );
      expect(
        await service.injectInput(
          session,
          'work',
          paste,
          windowId: '@7',
          bracketedPaste: true,
        ),
        isTrue,
      );
      expect(requests, hasLength(1));
      expect(requests.single['type'], 'inject_input');
      expect(requests.single['clientId'], session.monkeyMuxClientId);
      expect(requests.single['windowId'], '@7');
      expect(requests.single['data'], paste);
      expect(requests.single['bracketedPaste'], isTrue);
      expect(
        service.supportsBracketedPasteControlInput(session, 'work'),
        isTrue,
      );

      await stdoutController.close();
      await service.clearCache(899);
      expect(
        service.supportsBracketedPasteControlInput(session, 'work'),
        isFalse,
      );
    });
  });

  group('MonkeyMux control channel timeout', () {
    setUpAll(() => registerFallbackValue(Uint8List(0)));

    test(
      'listWindows fails instead of hanging when no response arrives',
      () async {
        final client = _MockSshClient();
        final installer = _MockMonkeyMuxInstaller();
        final session = _buildSession(client, connectionId: 900);
        // A control channel that opens successfully but never emits a response
        // line reproduces the stuck window switcher: without a timeout the
        // request completer would never resolve.
        final stdoutController = StreamController<Uint8List>();
        final controlSession = _buildSilentControlSession(stdoutController);

        when(
          () => installer.ensureInstalled(session),
        ).thenAnswer((_) async => _fakeInstallation);
        when(
          () => client.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((_) async => controlSession);

        final service = MonkeyMuxService(
          installer: installer,
          agentSessionMetadataPeriodicRefreshInterval: Duration.zero,
          controlResponseTimeout: const Duration(milliseconds: 80),
        );

        // Registering the observer routes listWindows through the persistent
        // control channel, which is the path that previously lacked a timeout.
        final stuckReload = (service..watchWindowChanges(session, 'work'))
            .listWindows(session, 'work');

        await expectLater(stuckReload, throwsA(isA<TimeoutException>()));

        // A subsequent reload succeeds once the control channel responds, proving
        // the timeout unblocks the window switcher instead of wedging it.
        final reconnectController = StreamController<Uint8List>();
        final reconnectSession = _buildRespondingControlSession(
          reconnectController,
          window: _fakeWindowJson,
        );
        when(
          () => client.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((_) async => reconnectSession);

        final windows = await service.listWindows(session, 'work');
        expect(windows, hasLength(1));
        expect(windows.single.name, 'Codex');

        await reconnectController.close();
        await stdoutController.close();
        await service.clearCache(900);
      },
    );

    test(
      'refreshWindows starts a new query after an older request fails',
      () async {
        final client = _MockSshClient();
        final installer = _MockMonkeyMuxInstaller();
        final session = _buildSession(client, connectionId: 901);
        final stdoutController = StreamController<Uint8List>();
        final controlSession = _buildSilentControlSession(stdoutController);
        final requests = <Map<String, Object?>>[];

        when(
          () => installer.ensureInstalled(session),
        ).thenAnswer((_) async => _fakeInstallation);
        when(
          () => client.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((_) async => controlSession);
        when(() => controlSession.write(any())).thenAnswer((invocation) {
          final data = invocation.positionalArguments.single as List<int>;
          requests.add(jsonDecode(utf8.decode(data)) as Map<String, Object?>);
        });

        final service = MonkeyMuxService(
          installer: installer,
          agentSessionMetadataPeriodicRefreshInterval: Duration.zero,
        )..watchWindowChanges(session, 'work');
        final firstRequest = service.listWindows(session, 'work');
        final freshRequest = service.refreshWindows(session, 'work');
        await pumpEventQueue();

        expect(requests, hasLength(1));
        _respondToControlError(stdoutController, requests.single);
        await expectLater(
          firstRequest,
          throwsA(isA<MonkeyMuxInstallException>()),
        );
        await pumpEventQueue();

        expect(requests, hasLength(2));
        _respondToWindowListRequest(
          stdoutController,
          requests.last,
          terminalBracketedPasteMode: true,
        );
        final windows = await freshRequest;

        expect(windows.single.terminalBracketedPasteMode, isTrue);

        await stdoutController.close();
        await service.clearCache(901);
      },
    );
    test(
      'listWindows fails instead of hanging when the watcher is disposed',
      () async {
        final client = _MockSshClient();
        final installer = _MockMonkeyMuxInstaller();
        final session = _buildSession(client, connectionId: 902);
        final stdoutController = StreamController<Uint8List>();
        final controlSession = _buildSilentControlSession(stdoutController);

        when(
          () => installer.ensureInstalled(session),
        ).thenAnswer((_) async => _fakeInstallation);
        when(
          () => client.execute(any(), pty: any(named: 'pty')),
        ).thenAnswer((_) async => controlSession);

        final service = MonkeyMuxService(
          installer: installer,
          agentSessionMetadataPeriodicRefreshInterval: Duration.zero,
        );
        final subscription = service
            .watchWindowChanges(session, 'work')
            .listen((_) {});
        final stuckReload = service.listWindows(session, 'work');
        final reloadFailed = expectLater(
          stuckReload,
          throwsA(isA<MonkeyMuxInstallException>()),
        );
        await pumpEventQueue();

        // Tearing down the last window-change listener disposes the shared
        // control channel. The in-flight reload used to stay pending forever,
        // and because it is cached as the shared window-list request every
        // later reload reused it, leaving the switcher on a perpetual spinner.
        await subscription.cancel();
        await reloadFailed;

        final reconnectController = StreamController<Uint8List>();
        when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer(
          (_) async => _buildRespondingControlSession(
            reconnectController,
            window: _fakeWindowJson,
          ),
        );
        final resubscribed = service
            .watchWindowChanges(session, 'work')
            .listen((_) {});

        final windows = await service.listWindows(session, 'work');
        expect(windows, hasLength(1));
        expect(windows.single.name, 'Codex');

        await resubscribed.cancel();
        await reconnectController.close();
        await stdoutController.close();
        await service.clearCache(902);
      },
    );

    test('listWindows recovers after the control channel never opens', () async {
      final client = _MockSshClient();
      final installer = _MockMonkeyMuxInstaller();
      final session = _buildSession(client, connectionId: 903);
      final neverOpens = Completer<SSHSession>();

      when(
        () => installer.ensureInstalled(session),
      ).thenAnswer((_) async => _fakeInstallation);
      // A channel open that never resolves used to block runCommand before the
      // request deadline was armed, so no timeout could ever fire.
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) => neverOpens.future);

      final service = MonkeyMuxService(
        installer: installer,
        agentSessionMetadataPeriodicRefreshInterval: Duration.zero,
        controlResponseTimeout: const Duration(milliseconds: 80),
      )..watchWindowChanges(session, 'work');

      await expectLater(
        service.listWindows(session, 'work'),
        throwsA(isA<TimeoutException>()),
      );

      // The wedged start attempt must not be reused: every later reload would
      // await the same dead future and time out without opening a channel.
      final reconnectController = StreamController<Uint8List>();
      final reconnectSession = _buildRespondingControlSession(
        reconnectController,
        window: _fakeWindowJson,
      );
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => reconnectSession);

      final windows = await service.listWindows(session, 'work');
      expect(windows, hasLength(1));
      expect(windows.single.name, 'Codex');

      // A channel that opens after its attempt was abandoned is closed rather
      // than installed over the live one.
      final abandoned = _buildSilentControlSession(
        StreamController<Uint8List>(),
      );
      neverOpens.complete(abandoned);
      await pumpEventQueue();
      verify(abandoned.close).called(1);

      await reconnectController.close();
      await service.clearCache(903);
    });

    test('gives every queued control command a distinct id', () async {
      final client = _MockSshClient();
      final installer = _MockMonkeyMuxInstaller();
      final session = _buildSession(client, connectionId: 904);
      final stdoutController = StreamController<Uint8List>();
      final controlSession = _buildSilentControlSession(stdoutController);
      final requests = <Map<String, Object?>>[];

      when(
        () => installer.ensureInstalled(session),
      ).thenAnswer((_) async => _fakeInstallation);
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => controlSession);
      when(() => controlSession.write(any())).thenAnswer((invocation) {
        final data = invocation.positionalArguments.single as List<int>;
        requests.add(jsonDecode(utf8.decode(data)) as Map<String, Object?>);
      });

      final service = MonkeyMuxService(
        installer: installer,
        agentSessionMetadataPeriodicRefreshInterval: Duration.zero,
      )..watchWindowChanges(session, 'work');
      // Commands created in the same tick used to share a microsecond
      // timestamp id, so the second overwrote the first in the pending map and
      // the first caller never received a response.
      final windowList = service.listWindows(session, 'work');
      final panePath = service.currentPanePath(session, 'work');
      await pumpEventQueue();

      expect(requests, hasLength(2));
      expect(requests.first['id'], isNot(requests.last['id']));

      for (final request in requests) {
        _respondToWindowListRequest(
          stdoutController,
          request,
          terminalBracketedPasteMode: false,
        );
      }
      await windowList;
      await panePath;

      await stdoutController.close();
      await service.clearCache(904);
    });
  });

  group('MonkeyMuxService.detectedVersion', () {
    setUpAll(() => registerFallbackValue(Uint8List(0)));

    test('reads the running server version from the control hello', () async {
      final client = _MockSshClient();
      final installer = _MockMonkeyMuxInstaller();
      final session = _buildSession(client, connectionId: 909);
      final commands = <String>[];
      when(
        () => installer.ensureInstalled(session),
      ).thenAnswer((_) async => _fakeInstallation);
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        invocation,
      ) async {
        commands.add(invocation.positionalArguments.single as String);
        return _buildOutputSession(
          '{"type":"hello","status":"ok","version":"0.2.4",'
          '"capabilities":[]}\n',
        );
      });

      final version = await MonkeyMuxService(
        installer: installer,
      ).detectedVersion(session, 'work');

      expect(version, '0.2.4');
      expect(
        commands.single,
        "'/home/tester/.monkeyssh/bin/monkeymux' control --json 'work'",
      );
    });

    test(
      'counts native ACP windows from the initial control snapshot',
      () async {
        final client = _MockSshClient();
        final installer = _MockMonkeyMuxInstaller();
        final session = _buildSession(client, connectionId: 917);
        when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer(
          (_) async => _buildOutputSession(
            '{"type":"hello","status":"ok","version":"0.2.4",'
            '"capabilities":["shutdown","acp-window-v1"]}\n'
            '{"type":"window_list","status":"ok","windows":['
            '{"id":"@1","index":0,"name":"Pi","active":true,'
            '"nativeAcpBridgeId":"0123456789abcdef0123456789abcdef",'
            '"nativeAcpProviderId":"builtin:pi-acp"},'
            '{"id":"@2","index":1,"name":"shell","active":false}]}\n',
          ),
        );

        final status = await MonkeyMuxService(
          installer: installer,
        ).runningServerStatus(session, _fakeInstallation, 'work');

        expect(status, isNotNull);
        expect(status!.version, '0.2.4');
        expect(status.hasNativeAcpWindows, isTrue);
        expect(status.nativeAcpWindowCount, 1);
      },
    );
  });

  group('MonkeyMuxService.installedHelperVersion', () {
    setUpAll(() => registerFallbackValue(Uint8List(0)));

    // `attach` restarts a running server only when its version differs from the
    // version compiled into the helper binary, so the binary — not the bundled
    // manifest label — decides whether an update would actually apply.
    test('reads the version the installed binary reports', () async {
      final client = _MockSshClient();
      final installer = _MockMonkeyMuxInstaller();
      final session = _buildSession(client, connectionId: 910);
      final commands = <String>[];
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        invocation,
      ) async {
        commands.add(invocation.positionalArguments.single as String);
        return _buildOutputSession('0.1.89\n');
      });

      final version = await MonkeyMuxService(
        installer: installer,
      ).installedHelperVersion(session, _fakeInstallation);

      expect(version, '0.1.89');
      expect(
        commands.single,
        "'/home/tester/.monkeyssh/bin/monkeymux' version",
      );
    });

    test('quotes the helper path for Windows remotes', () async {
      final client = _MockSshClient();
      final installer = _MockMonkeyMuxInstaller();
      final session = _buildSession(client, connectionId: 911);
      final commands = <String>[];
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        invocation,
      ) async {
        commands.add(invocation.positionalArguments.single as String);
        return _buildOutputSession('0.1.90\r\n');
      });

      final version = await MonkeyMuxService(installer: installer)
          .installedHelperVersion(
            session,
            const MonkeyMuxInstallation(
              executablePath: r'C:\Program Files\mm\monkeymux.exe',
              platform: 'windows-amd64',
              version: '0.1.90',
            ),
          );

      expect(version, '0.1.90');
      expect(commands.single, r'"C:\Program Files\mm\monkeymux.exe" version');
    });

    test('returns null when the probe produces no output', () async {
      final client = _MockSshClient();
      final installer = _MockMonkeyMuxInstaller();
      final session = _buildSession(client, connectionId: 912);
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => _buildOutputSession(''));

      final version = await MonkeyMuxService(
        installer: installer,
      ).installedHelperVersion(session, _fakeInstallation);

      expect(version, isNull);
    });

    test('skips login shell banner text before the version line', () async {
      final client = _MockSshClient();
      final installer = _MockMonkeyMuxInstaller();
      final session = _buildSession(client, connectionId: 914);
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer(
        (_) async => _buildOutputSession(
          'Welcome to Ubuntu 24.04 LTS\n\nLast login: Mon Jul 20\n0.1.89\n',
        ),
      );

      final version = await MonkeyMuxService(
        installer: installer,
      ).installedHelperVersion(session, _fakeInstallation);

      expect(version, '0.1.89');
    });

    test('returns null when no line looks like a version', () async {
      final client = _MockSshClient();
      final installer = _MockMonkeyMuxInstaller();
      final session = _buildSession(client, connectionId: 915);
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer(
        (_) async => _buildOutputSession('monkeymux: command not found\n'),
      );

      final version = await MonkeyMuxService(
        installer: installer,
      ).installedHelperVersion(session, _fakeInstallation);

      expect(version, isNull);
    });

    test('accepts a pre-release version suffix', () async {
      final client = _MockSshClient();
      final installer = _MockMonkeyMuxInstaller();
      final session = _buildSession(client, connectionId: 916);
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => _buildOutputSession('0.1.90-dev.3\n'));

      final version = await MonkeyMuxService(
        installer: installer,
      ).installedHelperVersion(session, _fakeInstallation);

      expect(version, '0.1.90-dev.3');
    });

    test('returns null when the probe fails', () async {
      final client = _MockSshClient();
      final installer = _MockMonkeyMuxInstaller();
      final session = _buildSession(client, connectionId: 913);
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenThrow(SSHStateError('channel closed'));

      final version = await MonkeyMuxService(
        installer: installer,
      ).installedHelperVersion(session, _fakeInstallation);

      expect(version, isNull);
    });
  });
}

class _MockSshClient extends Mock implements SSHClient {}

class _MockExecSession extends Mock implements SSHSession {}

class _MockChannel extends Mock implements SSHChannel {}

class _MockByteSink extends Mock implements StreamSink<Uint8List> {}

class _MockMonkeyMuxInstaller extends Mock
    implements MonkeyMuxInstallerService {}

const _fakeInstallation = MonkeyMuxInstallation(
  executablePath: '/home/tester/.monkeyssh/bin/monkeymux',
  platform: 'linux-amd64',
  version: '0.1.89',
);

const _fakeWindowJson = <String, Object?>{
  'id': '@1',
  'index': 0,
  'name': 'Codex',
  'active': true,
  'currentCommand': 'codex',
};

SshSession _buildSession(SSHClient client, {int connectionId = 1}) =>
    SshSession(
      connectionId: connectionId,
      hostId: 1,
      client: client,
      config: const SshConnectionConfig(
        hostname: 'example.com',
        port: 22,
        username: 'tester',
      ),
    );

/// Builds an exec session that emits [output] on stdout and then closes.
SSHSession _buildOutputSession(String output) {
  final session = _MockExecSession();
  final stdinSink = _MockByteSink();
  when(stdinSink.close).thenAnswer((_) async {});
  when(() => session.stdout).thenAnswer(
    (_) => Stream<Uint8List>.value(Uint8List.fromList(utf8.encode(output))),
  );
  when(() => session.stderr).thenAnswer((_) => const Stream<Uint8List>.empty());
  when(() => session.done).thenAnswer((_) async {});
  when(() => session.stdin).thenAnswer((_) => stdinSink);
  when(session.close).thenAnswer((_) {});
  return session;
}

SSHSession _buildSilentControlSession(
  StreamController<Uint8List> stdoutController,
) {
  final session = _MockExecSession();
  final stdinSink = _MockByteSink();
  when(stdinSink.close).thenAnswer((_) async {});
  when(() => session.stdout).thenAnswer((_) => stdoutController.stream);
  when(() => session.stderr).thenAnswer((_) => const Stream<Uint8List>.empty());
  when(() => session.done).thenAnswer((_) => Completer<void>().future);
  when(() => session.stdin).thenAnswer((_) => stdinSink);
  when(session.close).thenAnswer((_) {});
  when(() => session.write(any())).thenAnswer((_) {});
  return session;
}

SSHSession _buildRespondingControlSession(
  StreamController<Uint8List> stdoutController, {
  required Map<String, Object?> window,
}) {
  final session = _buildSilentControlSession(stdoutController);
  when(() => session.write(any())).thenAnswer((invocation) {
    final data = invocation.positionalArguments.single as List<int>;
    final request = jsonDecode(utf8.decode(data)) as Map<String, Object?>;
    final response = jsonEncode({
      'id': request['id'],
      'type': 'window_list',
      'status': 'ok',
      'windows': [window],
    });
    scheduleMicrotask(
      () =>
          stdoutController.add(Uint8List.fromList(utf8.encode('$response\n'))),
    );
  });
  return session;
}

void _respondToWindowListRequest(
  StreamController<Uint8List> stdoutController,
  Map<String, Object?> request, {
  required bool terminalBracketedPasteMode,
}) {
  final response = jsonEncode({
    'id': request['id'],
    'type': 'window_list',
    'status': 'ok',
    'windows': [
      {
        ..._fakeWindowJson,
        'terminalBracketedPasteMode': terminalBracketedPasteMode,
      },
    ],
  });
  stdoutController.add(Uint8List.fromList(utf8.encode('$response\n')));
}

void _respondToControlError(
  StreamController<Uint8List> stdoutController,
  Map<String, Object?> request,
) {
  final response = jsonEncode({
    'id': request['id'],
    'type': 'error',
    'status': 'error',
    'error': 'stale request failed',
  });
  stdoutController.add(Uint8List.fromList(utf8.encode('$response\n')));
}

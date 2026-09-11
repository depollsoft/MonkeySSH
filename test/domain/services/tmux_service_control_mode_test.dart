import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/terminal_theme.dart';
import 'package:monkeyssh/domain/models/terminal_themes.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/domain/services/tmux_service.dart';

String _tmuxSendKeysHex(String value) => value.codeUnits
    .map((codeUnit) => codeUnit.toRadixString(16).padLeft(2, '0'))
    .join(' ');

void main() {
  setUpAll(() {
    registerFallbackValue(Uint8List(0));
  });

  group('control mode command builders', () {
    test('attach command starts tmux in control mode without wait-exit', () {
      expect(
        buildTmuxControlModeAttachCommand('dev\'s session'),
        'tmux -CC attach-session -f '
        'ignore-size,no-output '
        r"-t 'dev'\''s session'",
      );
    });

    test(
      'attach command includes reusable tmux client flags when provided',
      () {
        expect(
          buildTmuxControlModeAttachCommand(
            'main',
            extraFlags: '-x 160 -S /tmp/tmux-socket -n editor',
          ),
          "tmux -S '/tmp/tmux-socket' -CC attach-session -f "
          'ignore-size,no-output '
          "-t 'main'",
        );
      },
    );

    test('extracts only reusable client flags from tmux extra flags', () {
      expect(
        resolveTmuxClientFlagsFromExtraFlags(
          r'-x 160 -S "/tmp/tmux socket" -y 48 \; set status off',
        ),
        "-S '/tmp/tmux socket'",
      );
      expect(
        resolveTmuxClientFlagsFromExtraFlags('-L alerts -f ~/.tmux.conf'),
        r"""-L 'alerts' -f "$HOME"'/.tmux.conf'""",
      );
      expect(resolveTmuxClientFlagsFromExtraFlags('-x 200 -n editor'), isNull);
    });

    test('shell-quotes reusable client flag values', () {
      expect(
        resolveTmuxClientFlagsFromExtraFlags(r'-S "$(touch /tmp/pwn)"'),
        r"-S '$(touch /tmp/pwn)'",
      );
      expect(
        resolveTmuxClientFlagsFromExtraFlags('-L `id` -f /tmp/>out'),
        "-L '`id`' -f '/tmp/>out'",
      );
      expect(
        resolveTmuxClientFlagsFromExtraFlags(
          '-S/tmp/sock;id -Lname&&id -f/tmp/sock|id',
        ),
        "-S '/tmp/sock;id' -L 'name&&id' -f '/tmp/sock|id'",
      );
      expect(
        resolveTmuxClientFlagsFromExtraFlags('-S /tmp/socket ; set status off'),
        "-S '/tmp/socket'",
      );
      expect(
        resolveTmuxClientFlagsFromExtraFlags("""-S "" -L ''"""),
        "-S '' -L ''",
      );
    });

    test(
      'subscription command watches all windows in the attached session',
      () {
        const sep = tmuxWindowFieldSeparator;
        expect(
          buildTmuxWindowSubscriptionCommand('flutty-1-42'),
          'refresh-client -B '
          "'flutty-1-42:@*:"
          '#{window_index}$sep#{window_name}$sep#{window_active}$sep'
          '#{pane_current_command}$sep#{pane_current_path}$sep'
          '#{window_flags}$sep#{pane_title}$sep#{window_activity}$sep'
          '#{pane_start_command}$sep'
          '#{@flutty_agent_tool}$sep'
          '#{window_id}$sep'
          '#{pane_pid}$sep'
          '#{@flutty_agent_session_id}$sep'
          '#{@flutty_agent_session_title}$sep'
          "#{@flutty_agent_session_confidence}'",
        );
      },
    );

    test('refresh command redraws non-control clients for a session', () {
      expect(
        buildTmuxRefreshForegroundClientsCommand("dev's session"),
        r'SEP=$(printf "\037"); '
        'tmux -u list-clients -t '
        r"'dev'\''s session' -F "
        r'"#{client_control_mode}${SEP}#{client_name}" '
        '2>/dev/null | '
        r'while IFS="$SEP" read -r control client; do '
        r'[ "$control" = 0 ] || continue; '
        r'[ -n "$client" ] || continue; '
        r'tmux -u refresh-client -t "$client" 2>/dev/null || true; '
        'done',
      );
    });

    test('refresh command reuses tmux client flags', () {
      expect(
        buildTmuxRefreshForegroundClientsCommand(
          'main',
          extraFlags: '-S /tmp/tmux-socket -x 160 -L alerts',
        ),
        contains(
          'tmux -u -S '
          "'/tmp/tmux-socket' -L 'alerts' "
          r'refresh-client -t "$client"',
        ),
      );
    });

    test('parses foreground client names for control refresh', () {
      expect(
        parseForegroundClientNamesForRefresh(
          [
            '1\x1fcontrol-client',
            '0\x1f/dev/ttys001',
            '0\x1fandroid-client',
            '0\x1f',
            '',
          ].join('\n'),
        ),
        ['/dev/ttys001', 'android-client'],
      );
    });

    test('reads the active remote tmux server version', () async {
      final client = _MockSshClient();
      final session = _buildSession(client, connectionId: 1067);
      const service = TmuxService();
      final commands = <String>[];

      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        invocation,
      ) async {
        commands.add(invocation.positionalArguments.single as String);
        return _buildOpenExecSession(stdout: '3.4\n${_doneMarker()}');
      });

      final version = await service.detectedVersion(
        session,
        'work',
        extraFlags: '-S /tmp/tmux-socket',
      );

      expect(version, '3.4');
      expect(
        commands.single,
        contains(
          "tmux -u -S '/tmp/tmux-socket' display-message -p "
          "-t 'work:' '#{version}'",
        ),
      );
    });

    test('returns null when the active tmux version is unavailable', () async {
      final client = _MockSshClient();
      final session = _buildSession(client, connectionId: 1068);
      const service = TmuxService();

      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer(
        (_) => Future<SSHSession>.error(SSHChannelOpenError(2, 'open failed')),
      );

      expect(await service.detectedVersion(session, 'work'), isNull);
    });

    test('theme refresh command updates pane palette before redraw', () {
      final command = buildTmuxRefreshTerminalThemeCommand(
        "dev's session",
        TerminalThemes.dracula,
      );

      expect(command, contains(r"tmux -u list-panes -s -t 'dev'\''s session'"));
      expect(command, contains(r'set-option -p -t "$pane"'));
      expect(
        RegExp(r'tmux -u set-option -p -t "\$pane"').allMatches(command),
        hasLength(1),
      );
      expect(command, contains(r'\; set-option -p -t "$pane"'));
      expect(command, contains("'pane-colours[5]' '#ff79c6'"));
      expect(command, contains("'pane-colours[6]' '#8be9fd'"));
      expect(
        command,
        contains(
          r'#{pane_active}${SEP}#{alternate_on}${SEP}#{pane_current_command}${SEP}#{pane_start_command}',
        ),
      );
      expect(
        command,
        contains(
          r'{ while IFS="$SEP" read -r pane active alternate pane_command pane_start_command',
        ),
      );
      expect(command, isNot(contains(r'if [ "$active" = 1 ]')));
      expect(command, isNot(contains('window_active')));
      expect(command, isNot(contains(r'[ "$alternate" = 1 ]')));
      expect(command, isNot(contains(r'[ "$theme_refresh_tui" = 1 ]')));
      expect(command, isNot(contains('theme_refresh_tui=0')));
      expect(command, contains('flutty_set_agent_tool_from_command_name'));
      expect(command, isNot(contains('flutty_set_agent_tool_from_exact_name')));
      expect(command, contains('flutty_is_generic_runtime_command_name'));
      expect(command, contains('flutty_set_agent_tool_from_command_text'));
      expect(command, contains(r'current_agent_tool=$agent_tool'));
      expect(
        command,
        contains(r'flutty_set_agent_tool_from_command_name "$pane_command"'),
      );
      expect(
        command,
        contains(r'flutty_is_generic_runtime_command_name "$pane_command"'),
      );
      expect(
        command,
        contains(
          r'flutty_set_agent_tool_from_command_text "$pane_start_command"',
        ),
      );
      expect(command, contains('claude|claude-*'));
      expect(command, contains('copilot|copilot-*'));
      expect(command, contains('codex|codex-*'));
      expect(command, contains('opencode|opencode-*'));
      expect(command, contains('agy|agy-*|antigravity|antigravity-*'));
      // Gemini CLI is unsupported: it must not be classified as an agent
      // pane nor receive focus-transition injections.
      expect(command, isNot(contains('gemini')));
      expect(command, contains('node|nodejs|npm|npx|bun|deno|python|python3'));
      expect(command, isNot(contains(r'case "$pane_title" in')));
      expect(command, isNot(contains('*Copilot*|*copilot*')));
      expect(command, isNot(contains('*Codex*|*codex*')));
      expect(command, isNot(contains('*OpenCode*|*opencode*')));
      expect(command, isNot(contains('foreground_tui=1')));
      expect(command, isNot(contains(r'[ "$active" = 1 ]')));
      expect(command, contains('flutty_theme_refresh_pane'));
      expect(command, contains(') & ;;'));
      expect(command, contains('done; wait; };'));
      expect(command, contains(r'if [ -n "$current_agent_tool" ]; then'));
      expect(command, contains(r'case "$agent_tool" in'));
      expect(command, contains('copilot|codex)'));
      expect(command, contains('opencode|claude|antigravity)'));
      final directBranchStart = command.indexOf(
        r'if [ -n "$current_agent_tool" ]; then',
      );
      expect(directBranchStart, isNonNegative);
      final directBranch = command.substring(directBranchStart);
      expect(directBranch.indexOf(r'case "$agent_tool" in'), greaterThan(0));
      expect(command, contains(r'send-keys -t "$pane" -H'));
      expect(command, contains(r'refresh-client -t "$client" -r "$pane":'));
      expect(command, contains(r'#{client_control_mode}${SEP}#{client_name}'));
      expect(command, contains(r'while IFS="$SEP" read -r control client'));
      expect(command, contains(r'[ "$control" = 0 ] || continue;'));
      expect(
        command,
        contains(
          buildTerminalThemeModeReport(isDark: TerminalThemes.dracula.isDark),
        ),
      );
      expect(
        command,
        contains(
          buildTerminalThemeOscResponse(
            theme: TerminalThemes.dracula,
            code: '10',
            args: const ['?'],
          ),
        ),
      );
      expect(
        command,
        contains(
          buildTerminalThemeOscResponse(
            theme: TerminalThemes.dracula,
            code: '11',
            args: const ['?'],
          ),
        ),
      );
      expect(command, contains('1b 5b 4f'));
      expect(command, contains('1b 5b 49'));
      final copilotCodexBranchStart = directBranch.indexOf('copilot|codex)');
      final otherAgentBranchStart = directBranch.indexOf(
        'opencode|claude|antigravity)',
      );
      final focusOutHex = _tmuxSendKeysHex('\x1b[O');
      final focusInHex = _tmuxSendKeysHex('\x1b[I');
      final themeModeHexPrefix = _tmuxSendKeysHex('\x1b[?997;');
      final oscHexPrefix = _tmuxSendKeysHex('\x1b]');
      expect(copilotCodexBranchStart, isNonNegative);
      expect(otherAgentBranchStart, greaterThan(copilotCodexBranchStart));
      final copilotCodexBranch = directBranch.substring(
        copilotCodexBranchStart,
        otherAgentBranchStart,
      );
      final otherAgentBranch = directBranch.substring(otherAgentBranchStart);
      expect(copilotCodexBranch, contains(focusInHex));
      expect(copilotCodexBranch, isNot(contains(focusOutHex)));
      expect(copilotCodexBranch, isNot(contains(themeModeHexPrefix)));
      expect(copilotCodexBranch, isNot(contains(oscHexPrefix)));
      expect(otherAgentBranch, contains(focusOutHex));
      expect(otherAgentBranch, contains(focusInHex));
      expect(otherAgentBranch, isNot(contains(themeModeHexPrefix)));
      expect(otherAgentBranch, isNot(contains(oscHexPrefix)));
      expect(command, isNot(contains('sleep 0.25')));
      final tmuxCacheReports = [
        buildTerminalThemeModeReport(isDark: TerminalThemes.dracula.isDark),
        buildTerminalThemeRefreshReports(TerminalThemes.dracula),
      ];
      expect(
        RegExp(
          r'refresh-client -t "\$client" -r "\$pane":',
        ).allMatches(command),
        hasLength(tmuxCacheReports.length),
      );
      for (final report in tmuxCacheReports) {
        expect(command, contains(report));
      }
      expect(
        command,
        contains(
          buildTerminalThemeRefreshReportList(TerminalThemes.dracula).join(),
        ),
      );
      expect(command, contains(r'send-keys -t "$pane" -H 1b 5b 49'));
      expect(command, contains(r'send-keys -t "$pane" -H 1b 5b 4f'));
      expect(
        command,
        isNot(contains(r'send-keys -t "$pane" -H 1b 5b 3f 39 39 37')),
      );
      expect(command, isNot(contains(r'send-keys -t "$pane" -H 1b 5d')));
      expect(command, contains(r"tmux -u list-clients -t 'dev'\''s session'"));
    });

    test('theme refresh command reuses tmux client flags', () {
      final command = buildTmuxRefreshTerminalThemeCommand(
        'main',
        TerminalThemes.githubLightDefault,
        extraFlags: '-S /tmp/tmux-socket -x 160 -L alerts',
      );

      expect(
        command,
        contains(
          'tmux -u -S '
          "'/tmp/tmux-socket' -L 'alerts' "
          'list-panes',
        ),
      );
      expect(
        command,
        contains(
          'tmux -u -S '
          "'/tmp/tmux-socket' -L 'alerts' "
          r"""set-option -p -t "$pane" 'pane-colours[0]'""",
        ),
      );
      expect(
        command,
        contains(
          'tmux -u -S '
          "'/tmp/tmux-socket' -L 'alerts' "
          r'refresh-client -t "$client" -r "$pane":',
        ),
      );
      expect(
        command,
        contains(
          'tmux -u -S '
          "'/tmp/tmux-socket' -L 'alerts' "
          r'send-keys -t "$pane" -H',
        ),
      );
      expect(
        command,
        contains(
          'tmux -u -S '
          "'/tmp/tmux-socket' -L 'alerts' "
          r'refresh-client -t "$client"',
        ),
      );
    });

    test('detectInstalledAgentTools caches empty results', () async {
      final client = _MockSshClient();
      final session = _buildSession(client, connectionId: 20);
      const service = TmuxService();
      final execSession = _buildOpenExecSession(stdout: _doneMarker());

      _stubExec(client, (_) async => execSession);

      final first = await service.detectInstalledAgentTools(session);
      final second = await service.detectInstalledAgentTools(session);

      expect(first, isEmpty);
      expect(second, isEmpty);
      verify(() => client.execute(any(), pty: any(named: 'pty'))).called(1);
    });

    test('invalidation forces a fresh installed-agent probe', () async {
      final client = _MockSshClient();
      final session = _buildSession(client, connectionId: 22);
      const service = TmuxService();
      var call = 0;
      _stubExec(client, (_) async {
        call += 1;
        return _buildOpenExecSession(
          stdout: call == 1
              ? '/opt/homebrew/bin/claude\n${_doneMarker()}'
              : '/opt/homebrew/bin/opencode\n${_doneMarker()}',
        );
      });

      final before = await service.detectInstalledAgentTools(session);
      service.invalidateInstalledAgentTools(session.connectionId);
      final after = await service.detectInstalledAgentTools(session);

      expect(before, {AgentLaunchTool.claudeCode});
      expect(after, {AgentLaunchTool.openCode});
      verify(() => client.execute(any(), pty: any(named: 'pty'))).called(2);
      service.invalidateInstalledAgentTools(session.connectionId);
    });

    for (final clearConnection in [false, true]) {
      test(
        'late tool probe cannot refill cache after clear=$clearConnection',
        () async {
          final client = _MockSshClient();
          final session = _buildSession(client, connectionId: 23);
          const service = TmuxService();
          final pending = Completer<SSHSession>();
          var opens = 0;
          when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer(
            (_) => opens++ == 0
                ? pending.future
                : Future.value(
                    _buildOpenExecSession(
                      stdout: '/bin/opencode\n${_doneMarker()}',
                    ),
                  ),
          );
          addTearDown(() => service.clearCache(23));
          final old = service.detectInstalledAgentTools(session);
          final oldResult = expectLater(
            old,
            clearConnection
                ? throwsA(isA<TmuxCommandException>())
                : completion({AgentLaunchTool.claudeCode}),
          );
          await untilCalled(
            () => client.execute(any(), pty: any(named: 'pty')),
          );
          if (clearConnection) {
            await service.clearCache(23);
          } else {
            service.invalidateInstalledAgentTools(23);
          }
          expect(await service.detectInstalledAgentTools(session), {
            AgentLaunchTool.openCode,
          });
          final lateSession = _buildOpenExecSession(
            stdout: '/bin/claude\n${_doneMarker()}',
          );
          pending.complete(lateSession);
          await oldResult;
          verify(lateSession.close).called(1);
          expect(await service.detectInstalledAgentTools(session), {
            AgentLaunchTool.openCode,
          });
          expect(opens, 2);
        },
      );
    }

    test('prefetchInstalledAgentTools warms the detection cache', () async {
      final client = _MockSshClient();
      final session = _buildSession(client, connectionId: 21);
      const service = TmuxService();
      final execSession = _buildOpenExecSession(
        stdout: '/opt/homebrew/bin/codex\n${_doneMarker()}',
      );

      _stubExec(client, (_) async => execSession);

      await service.prefetchInstalledAgentTools(session);
      final tools = await service.detectInstalledAgentTools(session);

      expect(tools, {AgentLaunchTool.codex});
      verify(() => client.execute(any(), pty: any(named: 'pty'))).called(1);
    });

    test(
      'detectInstalledAgentTools uses PowerShell on Windows remotes',
      () async {
        final client = _MockSshClient();
        when(
          () => client.remoteVersion,
        ).thenReturn('SSH-2.0-OpenSSH_for_Windows_9.5');
        final session = _buildSession(client, connectionId: 66);
        const service = TmuxService();
        final execSession = _buildClosedExecSession(
          stdout: 'C:/Users/demo/AppData/Roaming/npm/copilot.cmd\n',
        );

        _stubExec(client, (_) async => execSession);

        final tools = await service.detectInstalledAgentTools(session);

        expect(tools, {AgentLaunchTool.copilotCli});
        verify(
          () => client.execute(
            any(
              that: allOf(
                startsWith('powershell -NoProfile -NonInteractive '),
                isNot(contains('command -v')),
              ),
            ),
            pty: any(named: 'pty'),
          ),
        ).called(1);
        verify(execSession.close).called(1);
      },
    );

    test(
      'detectInstalledAgentTools caches empty Windows output after timeout',
      () async {
        final client = _MockSshClient();
        when(
          () => client.remoteVersion,
        ).thenReturn('SSH-2.0-OpenSSH_for_Windows_9.5');
        final session = _buildSession(client, connectionId: 67);
        const service = TmuxService(
          execOutputTimeout: Duration(milliseconds: 1),
        );
        final execSession = _buildOpenExecSession();

        _stubExec(client, (_) async => execSession);

        final first = await service.detectInstalledAgentTools(session);
        final second = await service.detectInstalledAgentTools(session);

        expect(first, isEmpty);
        expect(second, isEmpty);
        verify(() => client.execute(any(), pty: any(named: 'pty'))).called(1);
        verify(execSession.close).called(1);
      },
    );

    test('isTmuxActiveOrThrow ignores unrelated tmux clients', () async {
      final client = _MockSshClient();
      final session = _buildSession(client, connectionId: 22);
      const service = TmuxService();
      _queueExec(client, [
        _buildOpenExecSession(stdout: 'zsh\n/usr/bin/tmux\n${_doneMarker()}'),
        _buildOpenExecSession(stdout: _doneMarker()),
        _buildOpenExecSession(stdout: _doneMarker()),
      ]);

      final active = await service.isTmuxActiveOrThrow(session);

      expect(active, isFalse);
      final foregroundCommand =
          verify(
                () => client.execute(
                  captureAny(that: contains('list-clients')),
                  pty: any(named: 'pty'),
                ),
              ).captured.single
              as String;
      expect(foregroundCommand, contains('#{client_pid}'));
      expect(foregroundCommand, contains('#{client_control_mode}'));
      expect(foregroundCommand, contains('connection_pid='));
      expect(foregroundCommand, isNot(contains('exit 0')));
      expect(foregroundCommand, contains('break 2'));
      expect(foregroundCommand, isNot(contains('#{client_tty}')));
      // BusyBox `ps` has no `-p`, so the ancestry walk must have an exact
      // `/proc` PPID source or MonkeySSH's own tmux client stops being found.
      expect(foregroundCommand, contains(r'/proc/$1/status'));
      expect(foregroundCommand, contains('PPid:'));
      expect(
        foregroundCommand,
        isNot(contains(r'ps -p "$$"')),
        reason: 'the connection PID must go through the portable ppid_of()',
      );
      // The probe runs on remote POSIX shells, so it must at least parse.
      final syntaxCheck = Process.runSync('sh', [
        '-n',
        '-c',
        foregroundCommand,
      ]);
      expect(
        syntaxCheck.exitCode,
        0,
        reason:
            'generated probe is not valid POSIX shell: ${syntaxCheck.stderr}',
      );
      verifyNever(
        () => client.execute(
          any(that: contains('list-sessions')),
          pty: any(named: 'pty'),
        ),
      );
    });

    test(
      'foregroundSessionNameOrThrow never falls back to another connection',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client, connectionId: 23);
        const service = TmuxService();
        _queueExec(client, [
          _buildOpenExecSession(stdout: 'zsh\n/usr/bin/tmux\n${_doneMarker()}'),
          _buildOpenExecSession(stdout: _doneMarker()),
        ]);

        final sessionName = await service.foregroundSessionNameOrThrow(session);

        expect(sessionName, isNull);
        verify(
          () => client.execute(
            any(that: contains('list-clients')),
            pty: any(named: 'pty'),
          ),
        ).called(1);
        // `tmux display-message` resolves the host's most recently used
        // session, which may belong to a different SSH login, so it must never
        // be consulted for foreground ownership.
        verifyNever(
          () => client.execute(
            any(that: contains('display-message')),
            pty: any(named: 'pty'),
          ),
        );
      },
    );

    test('currentSessionName returns the foreground tmux client', () async {
      final client = _MockSshClient();
      final session = _buildSession(client, connectionId: 24);
      const service = TmuxService();
      final execSessions = _queueExec(client, [
        _buildOpenExecSession(stdout: 'zsh\n/usr/bin/tmux\n${_doneMarker()}'),
        _buildOpenExecSession(stdout: 'work\n${_doneMarker()}'),
      ]);

      final sessionName = await service.currentSessionName(session);

      expect(sessionName, 'work');
      expect(execSessions, isEmpty);
      verify(
        () => client.execute(
          any(that: contains('list-clients')),
          pty: any(named: 'pty'),
        ),
      ).called(1);
      verifyNever(
        () => client.execute(
          any(that: contains('display-message')),
          pty: any(named: 'pty'),
        ),
      );
    });

    test(
      'hasSessionOrThrow returns false for a missing tmux session',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client, connectionId: 30);
        const service = TmuxService();
        _queueExec(client, [
          _buildOpenExecSession(
            stdout: 'bash\n/usr/bin/tmux\n${_doneMarker()}',
          ),
          _buildOpenExecSession(stdout: '0\n${_doneMarker()}'),
        ]);

        final exists = await service.hasSessionOrThrow(session, 'missing');

        expect(exists, isFalse);
        verify(
          () => client.execute(
            any(that: contains('tmux -u has-session')),
            pty: any(named: 'pty'),
          ),
        ).called(1);
      },
    );

    test(
      'hasSessionOrThrow propagates indeterminate command failures',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client, connectionId: 31);
        const service = TmuxService();
        _queueExec(client, [
          _buildOpenExecSession(
            stdout: 'bash\n/usr/bin/tmux\n${_doneMarker()}',
          ),
          _buildOpenExecSession(stdout: _doneMarker(2)),
        ]);

        await expectLater(
          service.hasSessionOrThrow(session, 'work'),
          throwsA(isA<TmuxCommandException>()),
        );
      },
    );

    test('hasSessionOrThrow dedupes concurrent session probes', () async {
      final client = _MockSshClient();
      final session = _buildSession(client, connectionId: 33);
      const service = TmuxService();
      _queueExec(client, [
        _buildOpenExecSession(stdout: 'zsh\n/usr/bin/tmux\n${_doneMarker()}'),
        _buildOpenExecSession(stdout: '1\n${_doneMarker()}'),
      ]);

      final results = await Future.wait([
        service.hasSessionOrThrow(session, 'work'),
        service.hasSessionOrThrow(session, 'work'),
      ]);

      expect(results, [isTrue, isTrue]);
      verify(
        () => client.execute(
          any(that: contains('command -v tmux')),
          pty: any(named: 'pty'),
        ),
      ).called(1);
      verify(
        () => client.execute(
          any(that: contains('tmux -u has-session')),
          pty: any(named: 'pty'),
        ),
      ).called(1);
    });

    test(
      'listWindows serves the last cached snapshot when channels are exhausted',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client, connectionId: 32);
        const service = TmuxService();
        const sep = tmuxWindowFieldSeparator;
        var executeCalls = 0;
        final windowLine = [
          '0',
          'shell',
          '1',
          'bash',
          '/tmp/project',
          '*',
          'title',
          '100',
          'bash',
          '',
          '@4',
        ].join(sep);
        final execSession = _buildOpenExecSession(
          stdout: '$windowLine\n${_doneMarker()}',
        );

        _stubExec(client, (_) async {
          executeCalls += 1;
          if (executeCalls == 1) {
            return execSession;
          }
          return Future<SSHSession>.error(
            SSHChannelOpenError(2, 'open failed'),
          );
        });

        final initial = await service.listWindows(session, 'main');
        final cached = await service.listWindows(session, 'main');

        expect(initial, hasLength(1));
        expect(cached, initial);
        expect(cached.single.name, 'shell');
        expect(cached.single.id, '@4');
        verify(() => client.execute(any(), pty: any(named: 'pty'))).called(2);
      },
    );

    test(
      'tmux exec opens are deferred while channel backoff is active',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client, connectionId: 35);
        const service = TmuxService();
        var executeCalls = 0;

        _stubExec(client, (_) async {
          executeCalls += 1;
          return Future<SSHSession>.error(
            SSHChannelOpenError(2, 'open failed'),
          );
        });

        await expectLater(
          service.listWindows(session, 'main'),
          throwsA(isA<SSHChannelOpenError>()),
        );
        await Future<void>.delayed(Duration.zero);

        await expectLater(
          service.listWindows(session, 'main'),
          throwsA(
            predicate<Object>(
              (error) => error is! SSHChannelOpenError,
              'does not open another SSH channel',
            ),
          ),
        );

        expect(executeCalls, 1);
        expect(TmuxService.hasExecChannelBackoffEntry(35), true);
        expect(TmuxService.execChannelBackoffFailureCountForTesting(35), 1);
      },
    );

    test('currentPanePath reuses cached active window snapshots', () async {
      final client = _MockSshClient();
      final session = _buildSession(client, connectionId: 37);
      const service = TmuxService();
      var executeCalls = 0;

      _stubExec(client, (_) async {
        executeCalls += 1;
        return _buildOpenExecSession(
          stdout:
              '${_tmuxWindowLine(id: '@77', panePid: 77)}\n${_doneMarker()}',
        );
      });

      await service.listWindows(session, 'main');

      final path = await service.currentPanePath(session, 'main');
      final context = await service.currentPaneContext(session, 'main');

      expect(path, '/tmp/project');
      expect(context?.currentPath, '/tmp/project');
      expect(context?.currentCommand, 'copilot');
      expect(executeCalls, 1);
    });

    test('listWindows debounces Copilot metadata refresh bursts', () async {
      final client = _MockSshClient();
      final session = _buildSession(client, connectionId: 34);
      const service = TmuxService(
        agentSessionMetadataRefreshDebounce: Duration(milliseconds: 30),
      );
      final commands = <String>[];
      final windowLines = Queue<String>.of([
        _tmuxWindowLine(id: '@42', panePid: 42, title: 'First'),
        _tmuxWindowLine(id: '@88', panePid: 88, title: 'Second'),
      ]);

      _stubExec(client, (command) async {
        commands.add(command);
        if (command.contains('list-windows')) {
          return _buildOpenExecSession(
            stdout: '${windowLines.removeFirst()}\n${_doneMarker()}',
          );
        }
        return _buildOpenExecSession(stdout: _doneMarker());
      });

      await service.listWindows(session, 'main');
      await service.listWindows(session, 'main');

      expect(
        commands.where(_isCopilotMetadataCommand),
        isEmpty,
        reason: 'metadata refresh should wait for the debounce window',
      );

      await Future<void>.delayed(const Duration(milliseconds: 80));

      final metadataCommands = commands
          .where(_isCopilotMetadataCommand)
          .toList(growable: false);
      expect(metadataCommands, hasLength(1));
      expect(metadataCommands.single, contains("pane_pids='42 88'"));
    });

    test('agent session metadata refreshes periodically for watches', () async {
      final client = _MockSshClient();
      final session = _buildSession(client, connectionId: 38);
      const service = TmuxService(
        agentSessionMetadataRefreshDebounce: Duration(milliseconds: 5),
        agentSessionMetadataPeriodicRefreshInterval: Duration(milliseconds: 40),
      );
      final commands = <String>[];

      _stubExec(client, (command) async {
        commands.add(command);
        if (command.contains('list-windows')) {
          return _buildOpenExecSession(
            stdout:
                '${_tmuxWindowLine(id: '@42', panePid: 42)}\n${_doneMarker()}',
          );
        }
        return _buildOpenExecSession(stdout: _doneMarker());
      });

      service.watchWindowChanges(session, 'main');
      await service.listWindows(session, 'main');
      await Future<void>.delayed(const Duration(milliseconds: 25));

      expect(commands.where(_isCopilotMetadataCommand), hasLength(1));

      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(
        commands.where(_isCopilotMetadataCommand).length,
        greaterThanOrEqualTo(2),
      );
    });

    test('Copilot metadata refreshes wait for exec channel backoff', () async {
      final client = _MockSshClient();
      final session = _buildSession(client, connectionId: 35);
      const service = TmuxService(
        agentSessionMetadataRefreshDebounce: Duration(milliseconds: 10),
      );
      var metadataAttempts = 0;

      _stubExec(client, (command) async {
        if (command.contains('list-windows')) {
          return _buildOpenExecSession(
            stdout:
                '${_tmuxWindowLine(id: '@42', panePid: 42)}\n${_doneMarker()}',
          );
        }
        if (_isCopilotMetadataCommand(command)) {
          metadataAttempts += 1;
          if (metadataAttempts == 1) {
            return Future<SSHSession>.error(
              SSHChannelOpenError(2, 'open failed'),
            );
          }
          return _buildOpenExecSession(stdout: _doneMarker());
        }
        return _buildOpenExecSession(stdout: _doneMarker());
      });

      await service.listWindows(session, 'main');
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(metadataAttempts, 1);
      expect(
        TmuxService.hasExecChannelBackoffEntry(session.connectionId),
        true,
      );

      await service.listWindows(session, 'main');
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(
        metadataAttempts,
        1,
        reason: 'metadata refreshes should not hammer SSH during backoff',
      );

      await Future<void>.delayed(const Duration(milliseconds: 1800));

      expect(metadataAttempts, 2);
      expect(
        TmuxService.hasExecChannelBackoffEntry(session.connectionId),
        false,
      );
    });
  });

  group('parseTmuxWindowChangeEventFromControlLine', () {
    const subscriptionName = 'flutty-1-42';
    const sep = tmuxWindowFieldSeparator;

    test('returns a window snapshot event for matching subscriptions', () {
      final snapshotValue = [
        '1',
        'renamed',
        '1',
        'sleep',
        '/tmp',
        '*',
        'custom-title',
        '1712930000',
        'sleep 30',
        'copilot',
        '@12',
        '4321',
        'copilot-session',
        'Copilot live title',
        'medium',
      ].join(sep);
      final event = parseTmuxWindowChangeEventFromControlLine(
        '${r'%subscription-changed flutty-1-42 $1 @1 1 %1 : '}$snapshotValue',
        subscriptionName: subscriptionName,
      );

      expect(event, isA<TmuxWindowSnapshotEvent>());
      final snapshot = event! as TmuxWindowSnapshotEvent;
      expect(snapshot.window.index, 1);
      expect(snapshot.window.name, 'renamed');
      expect(snapshot.window.isActive, isTrue);
      expect(snapshot.window.paneTitle, 'custom-title');
      expect(snapshot.window.paneStartCommand, 'sleep 30');
      expect(snapshot.window.agentTool, AgentLaunchTool.copilotCli);
      expect(snapshot.window.id, '@12');
      expect(snapshot.window.panePid, 4321);
      expect(snapshot.window.activeAgentSessionId, 'copilot-session');
      expect(snapshot.window.agentSessionTitle, 'Copilot live title');
      expect(
        snapshot.window.activeAgentSessionConfidence,
        AgentSessionConfidence.medium,
      );
    });

    test('normalizes the wrapped first control-mode line', () {
      final snapshotValue = [
        '0',
        'shell',
        '1',
        'sleep',
        '/tmp',
        '*',
        'wrapped-title',
        '1712930000',
        'sleep 30',
        '',
        '@3',
      ].join(sep);
      final event = parseTmuxWindowChangeEventFromControlLine(
        '\u001bP1000p'
        '${r'%subscription-changed flutty-1-42 $1 @1 1 %1 : '}'
        '$snapshotValue',
        subscriptionName: subscriptionName,
      );

      expect(event, isA<TmuxWindowSnapshotEvent>());
      final snapshot = event! as TmuxWindowSnapshotEvent;
      expect(snapshot.window.displayTitle, 'wrapped-title');
      expect(snapshot.window.id, '@3');
    });

    test(
      'returns reload events for lifecycle notifications without snapshots',
      () {
        for (final line in [
          '%window-add @1',
          '%window-close @1',
          '%unlinked-window-add @1',
          '%unlinked-window-close @1',
          '%pane-mode-changed %1',
        ]) {
          expect(
            parseTmuxWindowChangeEventFromControlLine(
              line,
              subscriptionName: subscriptionName,
            ),
            isA<TmuxWindowReloadEvent>(),
          );
        }
      },
    );

    test(
      'ignores noise and notifications that should rely on snapshots instead',
      () {
        for (final line in [
          r'%subscription-changed other-subscription $1 @1 1 %1 : updated',
          '%window-renamed @1 🔥 test-emoji',
          r'%session-window-changed $1 @1',
          '%begin 1 2 0',
          '%output %1 hello',
          '',
        ]) {
          expect(
            parseTmuxWindowChangeEventFromControlLine(
              line,
              subscriptionName: subscriptionName,
            ),
            isNull,
          );
        }
      },
    );
  });

  group('diagnosticTmuxControlLineKind', () {
    test('returns only the control marker category', () {
      for (final (line, kind) in [
        (
          r'%subscription-changed flutty-1-42 $1 @1 1 %1 : private details',
          'subscription_changed',
        ),
        ('%window-renamed @1 private-name', 'window_renamed'),
        ('', 'empty'),
        ('unrecognized payload', 'other'),
      ]) {
        expect(diagnosticTmuxControlLineKind(line), kind);
        expect(diagnosticTmuxControlLineKind('\x1bP1000p$line\x1b\\'), kind);
      }
    });
  });

  group('shouldScheduleTmuxWindowReloadFallback', () {
    const subscriptionName = 'flutty-1-42';

    test(
      'schedules fallback reloads for window signals that may miss snapshots',
      () {
        for (final line in [
          r'%subscription-changed flutty-1-42 $1 @1 1 %1 : malformed',
          r'%session-window-changed $1 @1',
          '%window-add @1',
          '%window-renamed @1 renamed-window',
        ]) {
          expect(
            shouldScheduleTmuxWindowReloadFallback(
              line,
              subscriptionName: subscriptionName,
            ),
            isTrue,
          );
        }
      },
    );

    test('ignores unrelated control-mode noise', () {
      for (final line in [
        r'%subscription-changed other-subscription $1 @1 1 %1 : value',
        '%output %1 hello',
      ]) {
        expect(
          shouldScheduleTmuxWindowReloadFallback(
            line,
            subscriptionName: subscriptionName,
          ),
          isFalse,
        );
      }
    });

    test('preserves add and close reloads through later snapshots', () {
      for (final (line, preserved) in [
        ('%window-add @1', true),
        ('%unlinked-window-close @1', true),
        (r'%session-window-changed $1 @1', false),
      ]) {
        expect(shouldPreserveTmuxWindowReloadThroughSnapshots(line), preserved);
        expect(
          shouldPreserveTmuxWindowReloadThroughSnapshots(
            '\x1bP1000p$line\x1b\\',
          ),
          preserved,
        );
      }
    });
  });

  group('tmux window action helpers', () {
    test('parses the current pane path from display-message output', () {
      expect(
        parseTmuxCurrentPaneContext('/tmp/project\n')?.currentPath,
        '/tmp/project',
      );
      expect(
        parseTmuxCurrentPaneContext('\n  /tmp/workspace  \n')?.currentPath,
        '/tmp/workspace',
      );
      final context = parseTmuxCurrentPaneContext('/tmp/project\x1fzsh\n');
      expect(context?.currentPath, '/tmp/project');
      expect(context?.currentCommand, 'zsh');
      expect(parseTmuxCurrentPaneContext(' \n \n')?.currentPath, isNull);
    });

    test(
      'hasForegroundClient requires the primary terminal session to match',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client, connectionId: 24);
        const service = TmuxService();
        final execSessions = _queueExec(client, [
          _buildOpenExecSession(stdout: 'zsh\n/usr/bin/tmux\n${_doneMarker()}'),
          _buildOpenExecSession(stdout: 'other\n${_doneMarker()}'),
        ]);

        final hasForegroundClient = await service.hasForegroundClient(
          session,
          'work',
        );

        expect(hasForegroundClient, isFalse);
        expect(execSessions, isEmpty);
        final foregroundCommand =
            verify(
                  () => client.execute(
                    captureAny(that: contains('list-clients')),
                    pty: any(named: 'pty'),
                  ),
                ).captured.single
                as String;
        expect(foregroundCommand, contains('#{client_pid}'));
        expect(foregroundCommand, contains('#{client_control_mode}'));
      },
    );
  });

  group('tmux exec recovery', () {
    test('listWindows propagates exec channel open timeouts', () async {
      final client = _MockSshClient();
      final session = _buildSession(client, connectionId: 36);
      const service = TmuxService(execOpenTimeout: Duration(milliseconds: 1));

      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) => Completer<SSHSession>().future);

      await expectLater(
        service.listWindows(session, 'main'),
        throwsA(isA<TimeoutException>()),
      );
    });

    test(
      'listWindows completes when stdout stays open after the done marker',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client);
        const service = TmuxService();
        final execSession = _buildOpenExecSession(
          stdout:
              '1\x1feditor\x1f1\x1fvim\x1f/tmp\x1f*\x1fvim-title\x1f1712930000\n'
              '${_doneMarker()}',
        );

        _stubExec(client, (_) async => execSession);

        final windows = await service.listWindows(session, 'main');

        expect(windows, hasLength(1));
        expect(windows.single.index, 1);
        expect(windows.single.name, 'editor');
        verify(execSession.close).called(1);
      },
    );

    test('listWindows uses only reusable client flags when provided', () async {
      final client = _MockSshClient();
      final session = _buildSession(client);
      const service = TmuxService();
      final execSession = _buildOpenExecSession(
        stdout:
            '1\x1feditor\x1f1\x1fvim\x1f/tmp\x1f*\x1fvim-title\x1f1712930000\n'
            '${_doneMarker()}',
      );

      _stubExec(client, (_) async => execSession);

      await service.listWindows(
        session,
        'main',
        extraFlags: r'-S /tmp/socket -x 160 \; set status off',
      );

      final command =
          verify(
                () => client.execute(captureAny(), pty: any(named: 'pty')),
              ).captured.single
              as String;
      expect(
        command,
        contains("tmux -u -S '/tmp/socket' list-windows -t 'main' -F "),
      );
      expect(command, isNot(contains('set status off')));
    });

    test('listWindows coalesces duplicate in-flight reloads', () async {
      final client = _MockSshClient();
      final session = _buildSession(client);
      const service = TmuxService();
      final openCompleter = Completer<SSHSession>();
      final execSession = _buildOpenExecSession(
        stdout:
            '1\x1feditor\x1f1\x1fvim\x1f/tmp\x1f*\x1fvim-title\x1f1712930000\n'
            '${_doneMarker()}',
      );

      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) => openCompleter.future);

      final first = service.listWindows(session, 'main');
      final second = service.listWindows(session, 'main');
      openCompleter.complete(execSession);

      final results = await Future.wait([first, second]);

      expect(results[0], hasLength(1));
      expect(results[1], orderedEquals(results[0]));
      expect(
        () => results[0].add(
          const TmuxWindow(index: 2, name: 'other', isActive: false),
        ),
        throwsUnsupportedError,
      );
      verify(() => client.execute(any(), pty: any(named: 'pty'))).called(1);
      verify(execSession.close).called(1);
    });

    test('listWindows reads split markers and fragmented large output', () async {
      final client = _MockSshClient();
      final session = _buildSession(client);
      const service = TmuxService();
      final title = 'x' * 100000;
      final exec = _buildOpenExecSession();
      final bytes = utf8.encode(
        '1\x1feditor\x1f1\x1fvim\x1f/tmp\x1f*\x1f$title\x1f1712930000\n${_doneMarker()}',
      );
      when(() => exec.stdout).thenAnswer(
        (_) => Stream<Uint8List>.multi((controller) {
          for (var offset = 0; offset < bytes.length; offset += 7) {
            controller.add(
              Uint8List.fromList(
                bytes.sublist(offset, (offset + 7).clamp(0, bytes.length)),
              ),
            );
          }
        }),
      );
      _stubExec(client, (_) async => exec);
      final windows = await service.listWindows(session, 'main');
      expect(windows.single.paneTitle, title);
      verify(exec.close).called(1);
    });

    test('listWindows ignores done-marker text inside tmux fields', () async {
      final client = _MockSshClient();
      final session = _buildSession(client);
      const service = TmuxService();
      final execSession = _buildOpenExecSession(
        stdout:
            '1\x1f$_execDoneMarker\x1f1\x1fvim\x1f/tmp\x1f*\x1ftitle $_execDoneMarker:1\x1f1712930000\n'
            '${_doneMarker()}',
      );

      _stubExec(client, (_) async => execSession);

      final windows = await service.listWindows(session, 'main');

      expect(windows, hasLength(1));
      expect(windows.single.name, _execDoneMarker);
      expect(windows.single.paneTitle, 'title $_execDoneMarker:1');
      verify(execSession.close).called(1);
    });

    test(
      'createWindow tags agent windows and targets the created index',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client);
        const service = TmuxService();
        final commandSession = _buildOpenExecSession(stdout: _doneMarker());
        _queueExec(client, [
          _buildOpenExecSession(stdout: '4\n${_doneMarker()}'),
          _buildOpenExecSession(stdout: _doneMarker()),
          commandSession,
        ]);

        await service.createWindow(
          session,
          'main',
          command: 'copilot --resume copilot-session --allow-all-tools',
          name: 'copilot',
          workingDirectory: '/tmp/project',
        );
        await untilCalled(commandSession.close);

        verify(
          () => client.execute(
            any(
              that: contains(
                "tmux -u new-window -P -F '#{window_index}' -t "
                "'main' -c '/tmp/project' -n 'copilot'",
              ),
            ),
            pty: any(named: 'pty'),
          ),
        ).called(1);
        verify(
          () => client.execute(
            any(
              that: contains(
                "tmux -u set-option -w -t 'main:4' "
                r"@flutty_agent_tool 'copilot' \; "
                "set-option -w -t 'main:4' "
                r"@flutty_agent_session_id 'copilot-session' \; "
                "set-option -w -t 'main:4' "
                r"@flutty_agent_session_confidence 'high' \; "
                "set-option -w -t 'main:4' @flutty_agent_session_updated_at",
              ),
            ),
            pty: any(named: 'pty'),
          ),
        ).called(1);
        verify(
          () => client.execute(
            any(
              that: contains(
                "tmux -u send-keys -t 'main:4' "
                "'copilot --resume copilot-session --allow-all-tools' Enter",
              ),
            ),
            pty: any(named: 'pty'),
          ),
        ).called(1);
      },
    );

    test(
      'createWindow does not tag Gemini CLI launches as agent windows',
      () async {
        // Gemini CLI support was removed: a window that launches `gemini`
        // is treated as a plain shell command, so no @flutty_agent_* window
        // options are written for it.
        final client = _MockSshClient();
        final session = _buildSession(client);
        const service = TmuxService();
        final commandSession = _buildOpenExecSession(stdout: _doneMarker());
        _queueExec(client, [
          _buildOpenExecSession(stdout: '4\n${_doneMarker()}'),
          commandSession,
        ]);

        await service.createWindow(
          session,
          'main',
          command: 'gemini --resume gemini-session --yolo',
          name: 'gemini',
          workingDirectory: '/tmp/project',
        );
        await untilCalled(commandSession.close);

        verify(
          () => client.execute(
            any(
              that: contains(
                "tmux -u new-window -P -F '#{window_index}' -t "
                "'main' -c '/tmp/project' -n 'gemini'",
              ),
            ),
            pty: any(named: 'pty'),
          ),
        ).called(1);
        verifyNever(
          () => client.execute(
            any(that: contains('@flutty_agent_tool')),
            pty: any(named: 'pty'),
          ),
        );
        verify(
          () => client.execute(
            any(
              that: contains(
                "tmux -u send-keys -t 'main:4' "
                "'gemini --resume gemini-session --yolo' Enter",
              ),
            ),
            pty: any(named: 'pty'),
          ),
        ).called(1);
      },
    );

    test(
      'watchWindowChanges attaches with only reusable client flags',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client);
        const service = TmuxService();
        final stdoutController = StreamController<Uint8List>();
        final controlSession = _buildInteractiveExecSession(
          stdoutController: stdoutController,
          onWrite: (value) {
            if (value.startsWith('refresh-client ')) {
              scheduleMicrotask(
                () => stdoutController.add(
                  _utf8Bytes('%begin 1 1 0\n%end 1 1 0\n'),
                ),
              );
            }
          },
        );
        _queueExec(client, [
          _buildOpenExecSession(stdout: 'zsh\n/usr/bin/tmux\n${_doneMarker()}'),
          controlSession,
        ]);

        final subscription = service
            .watchWindowChanges(
              session,
              'main',
              extraFlags: r'-S /tmp/socket -x 160 \; set status off',
            )
            .listen((_) {});
        addTearDown(() async {
          await subscription.cancel();
          await service.clearCache(1);
          await stdoutController.close();
        });
        await untilCalled(
          () => client.execute(
            any(that: contains('attach-session')),
            pty: any(named: 'pty'),
          ),
        );
        await untilCalled(() => controlSession.write(any()));

        final command =
            verify(
                  () => client.execute(
                    captureAny(that: contains('attach-session')),
                    pty: any(named: 'pty'),
                  ),
                ).captured.single
                as String;
        expect(
          command,
          contains(
            "/usr/bin/tmux -u -S '/tmp/socket' -CC attach-session -f "
            'ignore-size,no-output ',
          ),
        );
        expect(command, isNot(contains('set status off')));
      },
    );

    test(
      'clearCache detaches an active control-mode watcher before closing it',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client, connectionId: 73);
        const service = TmuxService();
        final stdoutController = StreamController<Uint8List>();
        final writes = <String>[];
        final controlSession = _buildInteractiveExecSession(
          stdoutController: stdoutController,
          onWrite: (value) {
            writes.add(value);
            if (value.startsWith('refresh-client ')) {
              scheduleMicrotask(
                () => stdoutController.add(
                  _utf8Bytes('%begin 1 1 0\n%end 1 1 0\n'),
                ),
              );
            }
          },
        );
        _queueExec(client, [
          _buildOpenExecSession(stdout: 'zsh\n/usr/bin/tmux\n${_doneMarker()}'),
          controlSession,
        ]);

        final subscription = service
            .watchWindowChanges(session, 'main')
            .listen((_) {});
        addTearDown(() async {
          await subscription.cancel();
          await stdoutController.close();
        });
        await untilCalled(() => controlSession.write(any()));

        await service.clearCache(73);

        expect(writes, contains('detach-client -P\n\n'));
        verify(controlSession.close).called(1);
      },
    );

    test(
      'resubscribe replaces a disposing watcher and keeps shared ownership',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client, connectionId: 76);
        const service = TmuxService();
        final closing = Completer<void>();
        final oldOutput = StreamController<Uint8List>();
        final newOutput = StreamController<Uint8List>();
        final oldControl = _buildInteractiveExecSession(
          stdoutController: oldOutput,
          stdinClose: closing.future,
        );
        final newControl = _buildInteractiveExecSession(
          stdoutController: newOutput,
        );
        final sessions = Queue<SSHSession>.from([
          _buildOpenExecSession(stdout: 'zsh\n/usr/bin/tmux\n${_doneMarker()}'),
          oldControl,
          newControl,
        ]);
        _stubExec(client, (_) async => sessions.removeFirst());
        final first = service
            .watchWindowChanges(session, 'main')
            .listen((_) {});
        await untilCalled(() => oldControl.write(any()));
        await first.cancel();
        final events = <TmuxWindowChangeEvent>[];
        final replacementStream = service.watchWindowChanges(session, 'main');
        final replacement = replacementStream.listen(events.add);
        addTearDown(() async {
          if (!closing.isCompleted) closing.complete();
          await replacement.cancel();
          await service.clearCache(76);
          await oldOutput.close();
          await newOutput.close();
        });
        await untilCalled(() => newControl.write(any()));
        closing.complete();
        await untilCalled(oldControl.close);
        await Future<void>.delayed(Duration.zero);
        final sharedEvents = <TmuxWindowChangeEvent>[];
        final shared = service
            .watchWindowChanges(session, 'main')
            .listen(sharedEvents.add);
        newOutput.add(_utf8Bytes('%window-add @2\n'));
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(events, contains(isA<TmuxWindowReloadEvent>()));
        expect(sharedEvents, contains(isA<TmuxWindowReloadEvent>()));
        await shared.cancel();
        verifyNever(newControl.close);
        verify(() => client.execute(any(), pty: any(named: 'pty'))).called(3);
        expect(sessions, isEmpty);
      },
    );

    test(
      'clearCache waits for disposal that subscription cancel started',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client, connectionId: 74);
        const service = TmuxService();
        final stdoutController = StreamController<Uint8List>();
        final stdinCloseCompleter = Completer<void>();
        final controlSession = _buildInteractiveExecSession(
          stdoutController: stdoutController,
          stdinClose: stdinCloseCompleter.future,
          onWrite: (value) {
            if (value.startsWith('refresh-client ')) {
              scheduleMicrotask(
                () => stdoutController.add(
                  _utf8Bytes('%begin 1 1 0\n%end 1 1 0\n'),
                ),
              );
            }
          },
        );
        _queueExec(client, [
          _buildOpenExecSession(stdout: 'zsh\n/usr/bin/tmux\n${_doneMarker()}'),
          controlSession,
        ]);

        final subscription = service
            .watchWindowChanges(session, 'main')
            .listen((_) {});
        addTearDown(() async {
          if (!stdinCloseCompleter.isCompleted) {
            stdinCloseCompleter.complete();
          }
          await subscription.cancel();
          await stdoutController.close();
        });
        await untilCalled(() => controlSession.write(any()));

        await subscription.cancel();
        await Future<void>.delayed(Duration.zero);

        var clearCacheCompleted = false;
        final clearCacheFuture = service.clearCache(74).then((_) {
          clearCacheCompleted = true;
        });
        await Future<void>.delayed(Duration.zero);

        expect(clearCacheCompleted, isFalse);

        stdinCloseCompleter.complete();
        await clearCacheFuture;

        expect(clearCacheCompleted, isTrue);
        verify(controlSession.close).called(1);
      },
    );

    test(
      'clearCache waits for a starting watcher and detaches it after open',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client, connectionId: 75);
        const service = TmuxService();
        final stdoutController = StreamController<Uint8List>.broadcast();
        final controlOpenCompleter = Completer<SSHSession>();
        final writes = <String>[];
        final controlSession = _buildInteractiveExecSession(
          stdoutController: stdoutController,
          onWrite: writes.add,
        );
        var executeCalls = 0;

        when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
          invocation,
        ) {
          executeCalls += 1;
          final command = invocation.positionalArguments.single as String;
          if (command.contains('command -v tmux')) {
            return Future.value(
              _buildOpenExecSession(
                stdout: 'zsh\n/usr/bin/tmux\n${_doneMarker()}',
              ),
            );
          }
          expect(command, contains('attach-session'));
          return controlOpenCompleter.future;
        });

        final subscription = service
            .watchWindowChanges(session, 'main')
            .listen((_) {});
        addTearDown(() async {
          if (!controlOpenCompleter.isCompleted) {
            controlOpenCompleter.complete(controlSession);
          }
          await subscription.cancel();
          await stdoutController.close();
        });
        await untilCalled(
          () => client.execute(
            any(that: contains('attach-session')),
            pty: any(named: 'pty'),
          ),
        );

        var clearCacheCompleted = false;
        final clearCacheFuture = service.clearCache(75).then((_) {
          clearCacheCompleted = true;
        });
        await Future<void>.delayed(Duration.zero);

        expect(clearCacheCompleted, isFalse);

        controlOpenCompleter.complete(controlSession);
        await clearCacheFuture;

        expect(clearCacheCompleted, isTrue);
        expect(writes, ['detach-client -P\n\n']);
        expect(executeCalls, 2);
        verify(controlSession.close).called(1);
        verifyNever(() => controlSession.stdout);
        expect(TmuxService.hasConnectionStateForTesting(75), isFalse);
      },
    );

    test('selectWindow ignores the target window redraw activity', () async {
      final client = _MockSshClient();
      final session = _buildSession(client, connectionId: 1070);
      const service = TmuxService(
        windowSwitchActivityGracePeriod: Duration(milliseconds: 20),
      );
      const sep = tmuxWindowFieldSeparator;
      var listCalls = 0;
      final redrawActivity = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      String windowLine(int activity) => [
        '1',
        'shell',
        '0',
        'zsh',
        '/home/user/project',
        '',
        'shell',
        '$activity',
        'zsh',
        '',
        '@2',
        '',
        '',
        '',
        '',
      ].join(sep);

      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        invocation,
      ) async {
        final command = invocation.positionalArguments.single as String;
        if (command.contains('command -v tmux')) {
          return _buildOpenExecSession(
            stdout: '/usr/bin/tmux\n${_doneMarker()}',
          );
        }
        if (command.contains('list-windows')) {
          listCalls += 1;
          final activity = listCalls < 4 ? redrawActivity : redrawActivity + 1;
          final reportedActivity = listCalls == 1 ? 100 : activity;
          return _buildOpenExecSession(
            stdout: '${windowLine(reportedActivity)}\n${_doneMarker()}',
          );
        }
        return _buildOpenExecSession(stdout: _doneMarker());
      });
      addTearDown(() => service.clearCache(session.connectionId));

      final beforeSwitch = await service.listWindows(session, 'main');
      expect(beforeSwitch.single.lastActivityEpochSeconds, 100);

      await service.selectWindow(session, 'main', 1, windowId: '@2');
      final afterRedraw = await service.listWindows(session, 'main');
      expect(afterRedraw.single.lastActivityEpochSeconds, 100);

      await Future<void>.delayed(const Duration(milliseconds: 30));
      final afterGracePeriod = await service.listWindows(session, 'main');
      expect(afterGracePeriod.single.lastActivityEpochSeconds, 100);

      final afterRealOutput = await service.listWindows(session, 'main');
      expect(
        afterRealOutput.single.lastActivityEpochSeconds,
        redrawActivity + 1,
      );
    });

    for (final scenario in [
      'slow command',
      'snapshot during slow command',
      'new activity within grace period',
      'first activity after grace period',
      'failed command',
      'cleared connection',
      'unknown baseline',
      'stable window ID',
      'switch to another window',
    ]) {
      test('selectWindow redraw suppression handles $scenario', () async {
        final client = _MockSshClient();
        final session = _buildSession(client, connectionId: 1071);
        const service = TmuxService(
          windowSwitchActivityGracePeriod: Duration(milliseconds: 100),
        );
        final selectOpened = Completer<void>();
        final selectResult = Completer<SSHSession>();
        var activity = scenario == 'unknown baseline' ? null : 100;
        var targetIndex = 1;
        var otherActivity = 0;
        final unknownBaseline = activity == null;
        String windowLine(int index, String id, int? timestamp) => [
          '$index',
          'shell',
          '0',
          'zsh',
          '/home/user/project',
          '',
          'shell',
          if (timestamp == null) '' else '$timestamp',
          'zsh',
          '',
          id,
          '',
          '',
          '',
          '',
        ].join(tmuxWindowFieldSeparator);
        _stubExec(client, (command) async {
          if (command.contains('command -v tmux')) {
            return _buildOpenExecSession(
              stdout: 'zsh\n/usr/bin/tmux\n${_doneMarker()}',
            );
          }
          if (command.contains('select-window')) {
            if (selectOpened.isCompleted) {
              return _buildOpenExecSession(stdout: _doneMarker());
            }
            selectOpened.complete();
            return selectResult.future;
          }
          if (command.contains('list-windows')) {
            return _buildOpenExecSession(
              stdout:
                  '${windowLine(targetIndex, '@2', activity)}\n'
                  '${windowLine(2, '@3', otherActivity == 0 ? activity : otherActivity)}\n${_doneMarker()}',
            );
          }
          return _buildOpenExecSession(stdout: _doneMarker());
        });
        addTearDown(() => service.clearCache(session.connectionId));
        await service.listWindows(session, 'main');
        final switching = service.selectWindow(
          session,
          'main',
          1,
          windowId: '@2',
        );
        await selectOpened.future;
        if (scenario == 'switch to another window') {
          // Complete the second selection while the first SSH command is still
          // pending. Both targets must retain their own redraw baseline.
          await service.selectWindow(session, 'main', 2, windowId: '@3');
          otherActivity = 300;
        }
        if (scenario.contains('slow command')) {
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
        activity = 200;
        if (scenario == 'snapshot during slow command') {
          final during = await service.listWindows(session, 'main');
          expect(during.first.lastActivityEpochSeconds, 100);
          expect(during.last.lastActivityEpochSeconds, 200);
        }
        final failed = scenario == 'failed command';
        final switchExpectation = failed
            ? expectLater(switching, throwsA(isA<TmuxCommandException>()))
            : switching;
        selectResult.complete(
          _buildOpenExecSession(stdout: _doneMarker(failed ? 1 : 0)),
        );
        await switchExpectation;
        if (scenario == 'cleared connection') {
          await service.clearCache(session.connectionId);
          expect(
            TmuxService.hasConnectionStateForTesting(session.connectionId),
            isFalse,
          );
        }
        if (scenario == 'first activity after grace period') {
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
        if (scenario == 'stable window ID') targetIndex = 7;
        final shouldPreserve =
            !failed &&
            scenario != 'cleared connection' &&
            scenario != 'first activity after grace period';
        final after = await service.listWindows(session, 'main');
        expect(
          after.first.lastActivityEpochSeconds,
          shouldPreserve ? (unknownBaseline ? null : 100) : 200,
        );
        expect(
          after.last.lastActivityEpochSeconds,
          scenario == 'switch to another window' ? 100 : 200,
        );
        // A second timestamp must be visible even inside the grace period.
        activity = 201;
        final realOutput = await service.listWindows(session, 'main');
        expect(realOutput.first.lastActivityEpochSeconds, 201);
      });
    }

    for (final selectFails in [false, true]) {
      test('selectWindow filters control snapshots, fails=$selectFails', () async {
        final client = _MockSshClient();
        final session = _buildSession(client, connectionId: 70);
        const service = TmuxService();
        final stdoutController = StreamController<Uint8List>();
        final writes = <String>[];
        final snapshots = <TmuxWindowSnapshotEvent>[];
        var failNextSelect = selectFails;
        var redrawActivity = 200;
        String windowLine(int activity) => [
          '2',
          'shell',
          '1',
          'zsh',
          '/tmp',
          '*',
          'shell',
          '$activity',
          'zsh',
          '',
          '@2',
          '',
          '',
          '',
          '',
        ].join(tmuxWindowFieldSeparator);
        void emitSnapshot(int activity) {
          final refresh = writes.firstWhere(
            (value) => value.startsWith('refresh-client '),
          );
          final name = RegExp(
            r"flutty-[^:'\s]+",
          ).firstMatch(refresh)!.group(0)!;
          stdoutController.add(
            _utf8Bytes(
              '%subscription-changed $name \$1 @2 2 %2 : ${windowLine(activity)}\n',
            ),
          );
        }

        final controlSession = _buildInteractiveExecSession(
          stdoutController: stdoutController,
          onWrite: (value) {
            writes.add(value);
            if (value.startsWith('refresh-client ') ||
                value.startsWith('select-window ')) {
              scheduleMicrotask(() {
                final selecting = value.startsWith('select-window ');
                if (selecting) emitSnapshot(redrawActivity);
                final marker = selecting && failNextSelect ? '%error' : '%end';
                stdoutController.add(
                  _utf8Bytes('%begin 1 1 0\n$marker 1 1 0\n'),
                );
                if (selecting) failNextSelect = false;
              });
            }
          },
        );
        _stubExec(client, (command) async {
          if (command.contains('list-windows')) {
            return _buildOpenExecSession(
              stdout: '${windowLine(100)}\n${_doneMarker()}',
            );
          }
          if (command.contains('command -v tmux')) {
            return _buildOpenExecSession(
              stdout: 'zsh\n/usr/bin/tmux\n${_doneMarker()}',
            );
          }
          expect(command, contains('attach-session'));
          return controlSession;
        });
        final baseline = await service.listWindows(session, 'main');
        expect(baseline.single.lastActivityEpochSeconds, 100);
        final subscription = service.watchWindowChanges(session, 'main').listen(
          (event) {
            if (event is TmuxWindowSnapshotEvent) snapshots.add(event);
          },
        );
        addTearDown(() async {
          await subscription.cancel();
          await service.clearCache(session.connectionId);
          await stdoutController.close();
        });
        await untilCalled(() => controlSession.write(any()));
        final switching = service.selectWindow(session, 'main', 2);
        if (selectFails) {
          await expectLater(switching, throwsA(isA<TmuxCommandException>()));
        } else {
          await switching;
        }
        await Future<void>.delayed(Duration.zero);
        expect(snapshots.first.window.lastActivityEpochSeconds, 100);
        if (selectFails) {
          expect(
            snapshots.map((event) => event.window.lastActivityEpochSeconds),
            [100, 200],
          );
          // The restored timestamp must also become the next switch's baseline.
          redrawActivity = 201;
          await service.selectWindow(session, 'main', 2);
          await Future<void>.delayed(Duration.zero);
          expect(snapshots.last.window.lastActivityEpochSeconds, 200);
        }
        emitSnapshot(202);
        await Future<void>.delayed(Duration.zero);
        expect(snapshots.last.window.lastActivityEpochSeconds, 202);
        expect(writes, contains("select-window -t 'main':2\n"));
        verifyNever(
          () => client.execute(
            any(that: contains('select-window')),
            pty: any(named: 'pty'),
          ),
        );
      });
    }

    test(
      'createWindow falls back to exec while watcher open is pending',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client, connectionId: 4010);
        const service = TmuxService();
        final opening = Completer<SSHSession>();
        final watcherStarted = Completer<void>();
        final commands = <String>[];
        _stubExec(client, (command) async {
          commands.add(command);
          if (command.contains('command -v tmux')) {
            return _buildOpenExecSession(
              stdout: 'zsh\n/usr/bin/tmux\n${_doneMarker()}',
            );
          }
          if (command.contains('-CC attach-session')) {
            watcherStarted.complete();
            return opening.future;
          }
          return _buildOpenExecSession(stdout: '4\n${_doneMarker()}');
        });
        final subscription = service
            .watchWindowChanges(session, 'main')
            .listen((_) {});
        await watcherStarted.future;
        await service.createWindow(session, 'main', command: 'echo ready');
        await pumpEventQueue();
        expect(
          commands.where((command) => command.contains('new-window')),
          hasLength(1),
        );
        expect(
          commands.where((command) => command.contains('send-keys')),
          hasLength(1),
        );
        expect(
          commands.singleWhere((command) => command.contains('send-keys')),
          contains("send-keys -t 'main:4' 'echo ready' Enter"),
        );
        final cleanup = service.clearCache(session.connectionId);
        final lateChannel = _buildOpenExecSession();
        opening.complete(lateChannel);
        await cleanup;
        await subscription.cancel();
        verify(lateChannel.close).called(1);
        expect(
          TmuxService.hasConnectionStateForTesting(session.connectionId),
          isFalse,
        );
      },
    );

    test('createWindow uses an active control-mode watcher', () async {
      final client = _MockSshClient();
      final session = _buildSession(client, connectionId: 71);
      const service = TmuxService();
      final stdoutController = StreamController<Uint8List>();
      final writes = <String>[];
      final controlSession = _buildInteractiveExecSession(
        stdoutController: stdoutController,
        onWrite: (value) {
          writes.add(value);
          if (value.startsWith('refresh-client ')) {
            scheduleMicrotask(
              () => stdoutController.add(
                _utf8Bytes('%begin 1 1 0\n%end 1 1 0\n'),
              ),
            );
          } else if (value.startsWith('new-window ')) {
            scheduleMicrotask(
              () => stdoutController.add(
                _utf8Bytes('%begin 1 1 0\n4\n%end 1 1 0\n'),
              ),
            );
          } else if (value.startsWith('set-option ') ||
              value.startsWith('send-keys ')) {
            scheduleMicrotask(
              () => stdoutController.add(
                _utf8Bytes('%begin 1 1 0\n%end 1 1 0\n'),
              ),
            );
          }
        },
      );
      _queueExec(client, [
        _buildOpenExecSession(stdout: 'zsh\n/usr/bin/tmux\n${_doneMarker()}'),
        controlSession,
      ]);

      final subscription = service
          .watchWindowChanges(session, 'main')
          .listen((_) {});
      await untilCalled(() => controlSession.write(any()));

      await service.createWindow(
        session,
        'main',
        command: 'copilot --resume copilot-session --allow-all-tools',
        name: 'copilot',
        workingDirectory: '/tmp/project',
      );

      expect(
        writes,
        contains(
          "new-window -P -F '#{window_index}' -t 'main' "
          "-c '/tmp/project' -n 'copilot'\n",
        ),
      );
      expect(
        writes.any(
          (write) =>
              write.contains("@flutty_agent_tool 'copilot'") &&
              write.contains("@flutty_agent_session_id 'copilot-session'") &&
              write.contains("@flutty_agent_session_confidence 'high'") &&
              write.contains('@flutty_agent_session_updated_at '),
        ),
        isTrue,
      );
      expect(
        writes,
        contains(
          "send-keys -t 'main:4' "
          "'copilot --resume copilot-session --allow-all-tools' Enter\n",
        ),
      );
      verifyNever(
        () => client.execute(
          any(that: contains('new-window')),
          pty: any(named: 'pty'),
        ),
      );

      await subscription.cancel();
      await stdoutController.close();
    });

    test(
      'listWindows uses an active control-mode watcher during exec backoff',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client, connectionId: 72);
        const service = TmuxService();
        const sep = tmuxWindowFieldSeparator;
        final stdoutController = StreamController<Uint8List>();
        final writes = <String>[];
        final windowLine = [
          '1',
          'fresh',
          '1',
          'nvim',
          '/tmp/project',
          '*',
          'fresh-title',
          '200',
          'nvim',
          '',
          '@9',
        ].join(sep);
        final controlSession = _buildInteractiveExecSession(
          stdoutController: stdoutController,
          onWrite: (value) {
            writes.add(value);
            if (value.startsWith('refresh-client ')) {
              scheduleMicrotask(
                () => stdoutController.add(
                  _utf8Bytes('%begin 1 1 0\n%end 1 1 0\n'),
                ),
              );
            } else if (value.startsWith('list-windows ')) {
              scheduleMicrotask(
                () => stdoutController.add(
                  _utf8Bytes('%begin 2 1 0\n$windowLine\n%end 2 1 0\n'),
                ),
              );
            }
          },
        );
        var executeCalls = 0;

        _stubExec(client, (_) async {
          executeCalls += 1;
          if (executeCalls == 1) {
            return _buildOpenExecSession(
              stdout: 'zsh\n/usr/bin/tmux\n${_doneMarker()}',
            );
          }
          if (executeCalls == 2) {
            return controlSession;
          }
          if (executeCalls == 3) {
            return Future<SSHSession>.error(
              SSHChannelOpenError(2, 'open failed'),
            );
          }
          throw StateError('Unexpected SSH exec call $executeCalls');
        });

        final subscription = service
            .watchWindowChanges(session, 'main')
            .listen((_) {});
        addTearDown(() async {
          await service.clearCache(72);
          await subscription.cancel();
          await stdoutController.close();
        });
        await untilCalled(() => controlSession.write(any()));
        await Future<void>.delayed(Duration.zero);

        await expectLater(
          service.hasSessionOrThrow(session, 'main'),
          throwsA(isA<SSHChannelOpenError>()),
        );
        expect(TmuxService.hasExecChannelBackoffEntry(72), isTrue);

        final windows = await service.listWindows(session, 'main');

        expect(windows, hasLength(1));
        expect(windows.single.name, 'fresh');
        expect(windows.single.id, '@9');
        expect(
          writes,
          contains(
            predicate<String>((value) => value.startsWith('list-windows ')),
          ),
        );
        expect(executeCalls, 3);
      },
    );

    const service = TmuxService();
    for (final (name, action, flags, id, command) in [
      (
        'selectWindow completes when stdout stays open after the done marker',
        service.selectWindow,
        null,
        null,
        "tmux -u select-window -t 'main':2",
      ),
      (
        'selectWindow uses only reusable client flags when provided',
        service.selectWindow,
        r'-S /tmp/socket -x 160 \; set status off',
        null,
        "tmux -u -S '/tmp/socket' select-window -t 'main':2",
      ),
      (
        'selectWindow targets stable window IDs when provided',
        service.selectWindow,
        null,
        '@12',
        "tmux -u select-window -t '@12'",
      ),
      (
        'killWindow targets stable window IDs when provided',
        service.killWindow,
        null,
        '@12',
        "tmux -u kill-window -t '@12'",
      ),
      (
        'killWindow waits for the done marker so failures can surface',
        service.killWindow,
        null,
        null,
        "tmux -u kill-window -t 'main':2",
      ),
    ]) {
      test(name, () async {
        final client = _MockSshClient();
        final session = _buildSession(client);
        final execSession = _buildOpenExecSession(stdout: _doneMarker());
        _stubExec(client, (_) async => execSession);
        await action(session, 'main', 2, extraFlags: flags, windowId: id);
        verify(
          () => client.execute(
            any(that: contains(command)),
            pty: any(named: 'pty'),
          ),
        ).called(1);
        verify(execSession.close).called(1);
      });
    }

    test('killWindow propagates missing marker failures', () async {
      final client = _MockSshClient();
      final session = _buildSession(client);
      const service = TmuxService();
      final execSession = _buildClosedExecSession(stdout: 'tmux failed\n');

      _stubExec(client, (_) async => execSession);

      await expectLater(
        service.killWindow(session, 'main', 2),
        throwsA(
          isA<TmuxCommandException>().having(
            (error) => error.message,
            'message',
            contains('closed before tmux command completed'),
          ),
        ),
      );
      verify(execSession.close).called(1);
    });

    test('killWindow propagates non-zero tmux command exit status', () async {
      final client = _MockSshClient();
      final session = _buildSession(client);
      const service = TmuxService();
      final execSession = _buildOpenExecSession(stdout: _doneMarker(1));

      _stubExec(client, (_) async => execSession);

      await expectLater(
        service.killWindow(session, 'main', 2),
        throwsA(
          isA<TmuxCommandException>().having(
            (error) => error.message,
            'message',
            contains('exit status 1'),
          ),
        ),
      );
      verify(execSession.close).called(1);
    });

    test('detectInstalledAgentTools propagates output timeouts', () async {
      final client = _MockSshClient();
      final session = _buildSession(client);
      const service = TmuxService(execOutputTimeout: Duration(milliseconds: 1));
      final execSession = _buildOpenExecSession();

      _stubExec(client, (_) async => execSession);

      await expectLater(
        service.detectInstalledAgentTools(session),
        throwsA(isA<TimeoutException>()),
      );
      verify(execSession.close).called(1);
    });

    test(
      'detectInstalledAgentTools reports EOF before marker separately',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client);
        const service = TmuxService();
        final execSession = _buildClosedExecSession(stdout: 'partial output\n');

        _stubExec(client, (_) async => execSession);

        await expectLater(
          service.detectInstalledAgentTools(session),
          throwsA(isA<TmuxCommandException>()),
        );
        verify(execSession.close).called(1);
      },
    );

    test(
      'detectInstalledAgentTools parses output before an open stdout hangs',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client);
        const service = TmuxService();
        final execSession = _buildOpenExecSession(
          stdout: '/opt/homebrew/bin/claude\n${_doneMarker()}',
        );

        _stubExec(client, (_) async => execSession);

        final tools = await service.detectInstalledAgentTools(session);

        expect(tools, {AgentLaunchTool.claudeCode});
        verify(execSession.close).called(1);
      },
    );
  });

  group('decideTmuxHeartbeatAction', () {
    const heartbeat = Duration(seconds: 5);

    test('noop while control-mode notifications are flowing', () {
      for (final silence in [
        Duration.zero,
        const Duration(milliseconds: 4999),
      ]) {
        expect(
          decideTmuxHeartbeatAction(
            silence: silence,
            heartbeatInterval: heartbeat,
          ),
          TmuxControlHeartbeatAction.noop,
        );
      }
    });

    test('synthesizes a refresh once the channel has been silent for the '
        'heartbeat interval', () {
      for (final silence in [
        heartbeat,
        const Duration(seconds: 20),
        const Duration(minutes: 5),
      ]) {
        expect(
          decideTmuxHeartbeatAction(
            silence: silence,
            heartbeatInterval: heartbeat,
          ),
          TmuxControlHeartbeatAction.refresh,
        );
      }
    });
  });

  group('tmuxCommandNeedsLoginProfile', () {
    test(
      'pure server query/control commands do not need the login profile',
      () {
        for (final command in <String>[
          'tmux -u list-clients',
          'tmux -u select-window -t work:2',
          'tmux -u display-message -p "#{client_name}"',
          'tmux -u list-windows -t work',
          'tmux -u has-session -t work',
          'tmux -u refresh-client',
          'tmux -u show-options -g',
        ]) {
          expect(
            tmuxCommandNeedsLoginProfile(command),
            isFalse,
            reason: command,
          );
        }
      },
    );

    test('shell-spawning commands still need the login profile', () {
      for (final command in <String>[
        'tmux -u new-window -t work',
        'tmux -u new-session -s work',
        'tmux -u split-window -t work:1',
        'tmux -u run-shell "echo hi"',
        'tmux -u if-shell "true" "display ok"',
        'tmux -u respawn-pane -t work:1',
      ]) {
        expect(tmuxCommandNeedsLoginProfile(command), isTrue, reason: command);
      }
    });

    test('non-tmux and binary-resolving commands keep the login profile', () {
      for (final command in <String>[
        // Agent-tool detection resolves CLIs via command -v inside an
        // interactive shell, which needs ~/.zprofile's PATH (Homebrew) sourced
        // by the outer shell.
        r'''SH="${SHELL:-/bin/sh}"; "$SH" -ic 'for c in claude codex; do command -v "$c"; done' || true''',
        // Foreground-client check: process-tree walk with shell substitution.
        r'sep=$(printf "\037"); tmux -u list-clients -F "#{client_pid}"',
        // Theme refresh with a client-report subshell.
        r'tmux -u set-option -p -t "%1" pane-colours[0] "#fff"; clients=$(tmux -u list-clients)',
        'which tmux',
      ]) {
        expect(tmuxCommandNeedsLoginProfile(command), isTrue, reason: command);
      }
    });
  });

  group('channel backoff helpers', () {
    test('identifies transient channel-open failures', () {
      expect(
        shouldBackOffTmuxExecChannelAfterFailure(
          SSHChannelOpenError(2, 'open failed'),
        ),
        isTrue,
      );
      expect(
        shouldUseCachedTmuxWindowsAfterListFailure(
          SSHChannelOpenError(2, 'open failed'),
        ),
        isTrue,
      );
      expect(
        shouldBackOffTmuxExecChannelAfterFailure(StateError('tmux missing')),
        isFalse,
      );
    });

    test('backs off control restarts more slowly after channel failures', () {
      expect(
        resolveTmuxControlRestartDelay(0, channelOpenFailure: false),
        const Duration(seconds: 1),
      );
      expect(
        resolveTmuxControlRestartDelay(0, channelOpenFailure: true),
        const Duration(seconds: 5),
      );
      expect(
        resolveTmuxControlRestartDelay(2, channelOpenFailure: true),
        const Duration(seconds: 20),
      );
      expect(
        resolveTmuxControlRestartDelay(4, channelOpenFailure: true),
        const Duration(seconds: 30),
      );
    });

    test('uses capped exec channel cooldowns', () {
      expect(resolveTmuxExecChannelBackoffDelay(1), const Duration(seconds: 2));
      expect(resolveTmuxExecChannelBackoffDelay(2), const Duration(seconds: 4));
      expect(
        resolveTmuxExecChannelBackoffDelay(6),
        const Duration(seconds: 30),
      );
    });
  });

  group('clearCache lifecycle', () {
    // Connection IDs 60-69 reserved for this group to avoid static-cache
    // collisions with other groups in the same test run.

    for (final pathProbe in [true, false]) {
      for (final openingPending in [true, false]) {
        for (final fails in [true, false]) {
          test('clear pending ${pathProbe ? 'path' : 'windows'} '
              '${openingPending ? 'open' : 'output'}, fails=$fails', () async {
            const service = TmuxService();
            final client = _MockSshClient();
            final session = _buildSession(client, connectionId: 4000);
            final otherClient = _MockSshClient();
            final other = _buildSession(otherClient, connectionId: 4001);
            when(
              () => otherClient.execute(any(), pty: any(named: 'pty')),
            ).thenAnswer(
              (_) async => _buildOpenExecSession(
                stdout: '/usr/bin/codex\n${_doneMarker()}',
              ),
            );
            await service.detectInstalledAgentTools(other);
            final opening = Completer<SSHSession>();
            final output = StreamController<Uint8List>();
            final exec = _buildOpenExecSession();
            when(() => exec.stdout).thenAnswer((_) => output.stream);
            when(
              () => client.execute(any(), pty: any(named: 'pty')),
            ).thenAnswer((_) => opening.future);
            final request = pathProbe
                ? service.hasSessionOrThrow(session, 'main')
                : service.listWindows(session, 'main');
            final result = pathProbe || openingPending || fails
                ? expectLater(
                    request,
                    throwsA(
                      pathProbe || !fails
                          ? isA<TmuxCommandException>()
                          : isA<SSHChannelOpenError>(),
                    ),
                  )
                : expectLater(request, completion(isA<List<TmuxWindow>>()));
            await untilCalled(
              () => client.execute(any(), pty: any(named: 'pty')),
            );
            if (!openingPending) {
              opening.complete(exec);
              await untilCalled(() => exec.stdout);
            }
            await service.clearCache(session.connectionId);
            expect(TmuxService.hasConnectionStateForTesting(4000), isFalse);
            if (openingPending) {
              if (fails) {
                opening.completeError(SSHChannelOpenError(2, 'open failed'));
              } else {
                opening.complete(exec);
              }
            } else if (fails) {
              output.addError(SSHChannelOpenError(2, 'output failed'));
            } else {
              output.add(
                _utf8Bytes(
                  pathProbe
                      ? 'zsh\n/usr/bin/tmux\n${_doneMarker()}'
                      : '${_tmuxWindowLine(id: '@42', panePid: 42)}\n${_doneMarker()}',
                ),
              );
            }
            await result;
            await pumpEventQueue();
            expect(TmuxService.hasConnectionStateForTesting(4000), isFalse);
            expect(TmuxService.hasTmuxPathCacheEntry(4000), isFalse);
            expect(TmuxService.hasWindowSnapshotCacheEntry(4000), isFalse);
            expect(TmuxService.hasExecChannelBackoffEntry(4000), isFalse);
            expect(TmuxService.hasInstalledAgentToolsCacheEntry(4001), isTrue);
            if (!openingPending || !fails) verify(exec.close).called(1);
            if (!openingPending) await output.close();
            await service.clearCache(other.connectionId);
          });
        }
      }
    }

    test(
      'late metadata open failure cannot schedule recovery after clear',
      () async {
        const service = TmuxService(
          agentSessionMetadataRefreshDebounce: Duration.zero,
        );
        final client = _MockSshClient();
        final session = _buildSession(client, connectionId: 4002);
        final metadataOpen = Completer<SSHSession>();
        final metadataStarted = Completer<void>();
        _stubExec(client, (command) async {
          if (_isCopilotMetadataCommand(command)) {
            metadataStarted.complete();
            return metadataOpen.future;
          }
          return _buildOpenExecSession(
            stdout:
                '${_tmuxWindowLine(id: '@42', panePid: 42)}\n${_doneMarker()}',
          );
        });
        await service.listWindows(session, 'main');
        await metadataStarted.future;
        await service.clearCache(session.connectionId);
        metadataOpen.completeError(SSHChannelOpenError(2, 'open failed'));
        await pumpEventQueue();
        expect(TmuxService.hasConnectionStateForTesting(4002), isFalse);
        expect(TmuxService.hasExecChannelBackoffEntry(4002), isFalse);
        verify(() => client.execute(any(), pty: any(named: 'pty'))).called(2);
      },
    );

    test(
      'clears installed agent tools cache so subsequent call re-probes SSH',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client, connectionId: 60);
        const service = TmuxService();

        when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer(
          (_) async => _buildOpenExecSession(
            stdout: '/opt/homebrew/bin/claude\n${_doneMarker()}',
          ),
        );

        // Seed the agent-tools cache.
        final first = await service.detectInstalledAgentTools(session);
        expect(first, {AgentLaunchTool.claudeCode});
        expect(TmuxService.hasInstalledAgentToolsCacheEntry(60), isTrue);

        // Clear and verify the cache entry is gone.
        await service.clearCache(60);
        expect(TmuxService.hasInstalledAgentToolsCacheEntry(60), isFalse);

        // A subsequent call must re-probe via SSH rather than serve stale data.
        final second = await service.detectInstalledAgentTools(session);
        expect(second, {AgentLaunchTool.claudeCode});
        verify(() => client.execute(any(), pty: any(named: 'pty'))).called(2);
      },
    );

    test(
      'clears tmux path cache so subsequent path probe is re-issued',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client, connectionId: 61);
        const service = TmuxService();
        // hasSessionOrThrow issues two SSH execs: (1) the path probe and
        // (2) the has-session command.  A second call skips the probe.
        final execQueue = Queue<SSHSession>.of([
          _buildOpenExecSession(stdout: 'zsh\n/usr/bin/tmux\n${_doneMarker()}'),
          _buildOpenExecSession(stdout: '1\n${_doneMarker()}'),
          // After clearCache a fresh path probe is issued again.
          _buildOpenExecSession(stdout: 'zsh\n/usr/bin/tmux\n${_doneMarker()}'),
          _buildOpenExecSession(stdout: '1\n${_doneMarker()}'),
        ]);
        _stubExec(client, (_) async => execQueue.removeFirst());

        // Seed the path cache via a method that calls _cacheTmuxPath.
        await service.hasSessionOrThrow(session, 'work');
        expect(TmuxService.hasTmuxPathCacheEntry(61), isTrue);

        // Clear and verify the cache entry is gone.
        await service.clearCache(61);
        expect(TmuxService.hasTmuxPathCacheEntry(61), isFalse);

        // A subsequent call must re-probe the tmux binary path.
        await service.hasSessionOrThrow(session, 'work');
        expect(TmuxService.hasTmuxPathCacheEntry(61), isTrue);
        verify(
          () => client.execute(
            any(that: contains('command -v tmux')),
            pty: any(named: 'pty'),
          ),
        ).called(2);
      },
    );

    test(
      'clears window snapshot cache so stale windows are not served',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client, connectionId: 62);
        const service = TmuxService();
        const sep = tmuxWindowFieldSeparator;
        final windowLine = [
          '0',
          'editor',
          '1',
          'nvim',
          '/home/user/project',
          '*',
          'editor',
          '200',
          'nvim',
          '',
          '@1',
        ].join(sep);

        when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer(
          (_) async =>
              _buildOpenExecSession(stdout: '$windowLine\n${_doneMarker()}'),
        );

        // listWindows populates _windowSnapshotCache when results are non-empty.
        final windows = await service.listWindows(session, 'main');
        expect(windows, hasLength(1));
        expect(TmuxService.hasWindowSnapshotCacheEntry(62), isTrue);

        // After clearCache the snapshot is gone.
        await service.clearCache(62);
        expect(TmuxService.hasWindowSnapshotCacheEntry(62), isFalse);
      },
    );

    test(
      'clears exec-channel backoff so the next exec channel is not throttled',
      () async {
        final client = _MockSshClient();
        final session = _buildSession(client, connectionId: 63);
        const service = TmuxService();

        // Trigger a channel-open failure so a backoff entry is recorded.
        when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer(
          (_) async =>
              Future<SSHSession>.error(SSHChannelOpenError(2, 'open failed')),
        );
        await expectLater(
          service.listWindows(session, 'main'),
          throwsA(isA<SSHChannelOpenError>()),
        );
        expect(TmuxService.hasExecChannelBackoffEntry(63), isTrue);

        // clearCache must remove the backoff so the next open is attempted.
        await service.clearCache(63);
        expect(TmuxService.hasExecChannelBackoffEntry(63), isFalse);
      },
    );

    test(
      'clearCache for one connection does not affect another connection',
      () async {
        final clientA = _MockSshClient();
        final clientB = _MockSshClient();
        final sessionA = _buildSession(clientA, connectionId: 64);
        final sessionB = _buildSession(clientB, connectionId: 65);
        const service = TmuxService();

        for (final client in [clientA, clientB]) {
          when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer(
            (_) async => _buildOpenExecSession(
              stdout: '/opt/homebrew/bin/codex\n${_doneMarker()}',
            ),
          );
        }

        await service.detectInstalledAgentTools(sessionA);
        await service.detectInstalledAgentTools(sessionB);
        expect(TmuxService.hasInstalledAgentToolsCacheEntry(64), isTrue);
        expect(TmuxService.hasInstalledAgentToolsCacheEntry(65), isTrue);

        // Clearing A must not affect B.
        await service.clearCache(64);
        expect(TmuxService.hasInstalledAgentToolsCacheEntry(64), isFalse);
        expect(TmuxService.hasInstalledAgentToolsCacheEntry(65), isTrue);

        // Clean up B.
        await service.clearCache(65);
      },
    );
  });
}

SshSession _buildSession(SSHClient client, {int connectionId = 1}) {
  addTearDown(() => const TmuxService().clearCache(connectionId));
  return SshSession(
    connectionId: connectionId,
    hostId: 1,
    client: client,
    config: const SshConnectionConfig(
      hostname: 'example.com',
      port: 22,
      username: 'tester',
    ),
  );
}

String _tmuxWindowLine({
  required String id,
  required int panePid,
  String title = 'Title',
}) => [
  '0',
  'copilot',
  '1',
  'copilot',
  '/tmp/project',
  '*',
  title,
  '100',
  'copilot',
  '',
  id,
  '$panePid',
].join(tmuxWindowFieldSeparator);

bool _isCopilotMetadataCommand(String command) =>
    command.contains('ps -eo pid=,ppid=,comm=,args=');

class _MockSshClient extends Mock implements SSHClient {
  @override
  bool get isClosed => false;
}

class _MockExecSession extends Mock implements SSHSession {}

class _MockByteSink extends Mock implements StreamSink<Uint8List> {}

const _execDoneMarker = '__flutty_tmux_exec_done__';

String _doneMarker([int status = 0]) => '$_execDoneMarker:$status\n';

Stream<Uint8List> _openUtf8Stream(String value) =>
    Stream<Uint8List>.multi((controller) {
      if (value.isNotEmpty) {
        scheduleMicrotask(
          () => controller.add(Uint8List.fromList(utf8.encode(value))),
        );
      }
    });

Stream<Uint8List> _closedUtf8Stream(String value) =>
    Stream<Uint8List>.fromIterable(
      value.isEmpty ? const [] : [Uint8List.fromList(utf8.encode(value))],
    );

Uint8List _utf8Bytes(String value) => Uint8List.fromList(utf8.encode(value));

void _ignoreInvocation(Invocation _) {}

SSHSession _buildOpenExecSession({
  String stdout = '',
  String stderr = '',
  Future<void>? done,
}) {
  final session = _MockExecSession();
  final doneFuture = done ?? Completer<void>().future;
  when(() => session.stdout).thenAnswer((_) => _openUtf8Stream(stdout));
  when(() => session.stderr).thenAnswer((_) => _openUtf8Stream(stderr));
  when(() => session.done).thenAnswer((_) => doneFuture);
  when(session.close).thenAnswer(_ignoreInvocation);
  return session;
}

SSHSession _buildClosedExecSession({String stdout = '', String stderr = ''}) {
  final session = _MockExecSession();
  when(() => session.stdout).thenAnswer((_) => _closedUtf8Stream(stdout));
  when(() => session.stderr).thenAnswer((_) => _closedUtf8Stream(stderr));
  when(() => session.done).thenAnswer((_) => Future<void>.value());
  when(session.close).thenAnswer(_ignoreInvocation);
  return session;
}

SSHSession _buildInteractiveExecSession({
  required StreamController<Uint8List> stdoutController,
  void Function(String)? onWrite,
  String stderr = '',
  Future<void>? done,
  Future<void>? stdinClose,
}) {
  final session = _MockExecSession();
  final doneFuture = done ?? Completer<void>().future;
  final stdinSink = _MockByteSink();
  when(stdinSink.close).thenAnswer((_) => stdinClose ?? Future<void>.value());
  when(() => session.stdout).thenAnswer((_) => stdoutController.stream);
  when(() => session.stderr).thenAnswer((_) => _openUtf8Stream(stderr));
  when(() => session.done).thenAnswer((_) => doneFuture);
  when(() => session.stdin).thenAnswer((_) => stdinSink);
  when(session.close).thenAnswer(_ignoreInvocation);
  when(() => session.write(any())).thenAnswer((invocation) {
    final data = invocation.positionalArguments.single as List<int>;
    onWrite?.call(utf8.decode(data));
  });
  return session;
}

void _stubExec(
  SSHClient client,
  FutureOr<SSHSession> Function(String) response,
) {
  when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer(
    (call) async => response(call.positionalArguments.single as String),
  );
}

Queue<SSHSession> _queueExec(SSHClient client, List<SSHSession> responses) {
  final queue = Queue<SSHSession>.of(responses);
  _stubExec(client, (_) => queue.removeFirst());
  return queue;
}

// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/terminal_progress.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';

void main() {
  group('TmuxWindow', () {
    test('parses from tmux format string with all fields', () {
      const sep = tmuxWindowFieldSeparator;
      final line = [
        '0',
        'vim',
        '1',
        'vim',
        '/home/user/project',
        '*',
        'Editing main.dart',
        '1712930000',
        'vim main.dart',
        '',
        '@8',
        '4321',
        'session-123',
        'Live session title',
        'high',
      ].join(sep);
      final window = TmuxWindow.fromTmuxFormat(line);

      expect(window.index, 0);
      expect(window.id, '@8');
      expect(window.panePid, 4321);
      expect(window.name, 'vim');
      expect(window.isActive, true);
      expect(window.currentCommand, 'vim');
      expect(window.currentPath, '/home/user/project');
      expect(window.flags, '*');
      expect(window.paneTitle, 'Editing main.dart');
      expect(window.paneStartCommand, 'vim main.dart');
      expect(window.activeAgentSessionId, 'session-123');
      expect(window.agentSessionTitle, 'Live session title');
      expect(window.activeAgentSessionConfidence, AgentSessionConfidence.high);
      expect(window.displayTitle, 'Live session title');
      expect(window.hasAlert, false);
    });

    test('drops session metadata only for explicitly unsupported tools', () {
      for (final tool in ['gemini', 'future-agent', 'copilot', '']) {
        final window = TmuxWindow.fromTmuxFormat(
          [
            '0',
            'Project shell',
            '1',
            'zsh',
            '/tmp/project',
            '',
            '',
            '',
            '',
            tool,
            '@1',
            '123',
            'legacy-session',
            'Stale conversation title',
            'high',
          ].join(tmuxWindowFieldSeparator),
        );
        if (tool == 'gemini' || tool == 'future-agent') {
          expect(window.agentTool, isNull);
          expect(window.activeAgentSessionId, isNull);
          expect(window.agentSessionTitle, isNull);
          expect(window.activeAgentSessionConfidence, isNull);
          expect(window.displayTitle, 'Project shell');
        } else {
          expect(window.activeAgentSessionId, 'legacy-session');
          expect(window.agentSessionTitle, 'Stale conversation title');
          expect(
            window.activeAgentSessionConfidence,
            AgentSessionConfidence.high,
          );
        }
      }
    });

    test(
      'unsupported tool markers block weak inference and survive updates',
      () {
        for (final command in ['node', 'zsh', 'copilot']) {
          final window = TmuxWindow.fromTmuxFormat(
            [
              '0',
              'Codex',
              '1',
              command,
              '/tmp/project',
              '',
              'Claude Code',
              '',
              'gemini --resume old-session',
              'gemini',
              '@1',
              '123',
              'legacy-session',
              'Stale title',
              'high',
            ].join(tmuxWindowFieldSeparator),
          );
          final expected = command == 'copilot'
              ? AgentLaunchTool.copilotCli
              : null;
          expect(window.hasUnsupportedAgentTool, isTrue);
          expect(window.agentSessionId, isNull);
          expect(window.foregroundAgentTool, expected);
          expect(window.activeAgentSessionId, isNull);
          expect(window.agentSessionTitle, isNull);
          expect(
            window.copyWith(isActive: false).foregroundAgentTool,
            expected,
          );
          expect(window.copyWith(), window);
          expect(window.copyWith().hashCode, window.hashCode);
          final supported = window.copyWith(agentTool: AgentLaunchTool.codex);
          expect(supported.hasUnsupportedAgentTool, isFalse);
          expect(supported, isNot(window));
          final old = window.copyWith(
            hasUnsupportedAgentTool: false,
            activeAgentSessionId: 'old-session',
            agentSessionTitle: 'Old title',
          );
          for (final event in [
            TmuxWindowSnapshotEvent(window),
            TmuxWindowListEvent([window]),
          ]) {
            final merged = applyTmuxWindowChangeEvent([old], event).single;
            expect(merged.hasUnsupportedAgentTool, isTrue);
            expect(merged.activeAgentSessionId, isNull);
            expect(merged.agentSessionTitle, isNull);
          }
        }
      },
    );

    test('preserves pipe characters in pane titles', () {
      const line =
          '1\x1flogs\x1f0\x1ftail\x1f/var/log\x1f-\x1fapi | worker | errors\x1f1712930000';
      final window = TmuxWindow.fromTmuxFormat(line);

      expect(window.paneTitle, 'api | worker | errors');
      expect(window.lastActivityEpochSeconds, 1712930000);
      expect(window.displayTitle, 'api | worker | errors');
    });

    test('parses with minimal fields', () {
      const line = '2\x1fbash\x1f0';
      final window = TmuxWindow.fromTmuxFormat(line);

      expect(window.index, 2);
      expect(window.name, 'bash');
      expect(window.isActive, false);
      expect(window.currentCommand, isNull);
      expect(window.currentPath, isNull);
      expect(window.flags, isNull);
      expect(window.paneTitle, isNull);
      expect(window.displayTitle, 'bash');
    });

    test('strips placeholder underscores from emoji-mangled window names', () {
      const window = TmuxWindow(
        index: 1,
        name: '__ test-emoji',
        isActive: false,
      );

      expect(window.displayTitle, 'test-emoji');
      expect(window.secondaryTitle, isNull);
    });

    test('exposes secondaryTitle when pane title differs from window name', () {
      const window = TmuxWindow(
        index: 1,
        name: 'claude',
        isActive: false,
        currentCommand: 'claude',
        paneTitle: '✨ Editing main.dart',
      );

      expect(window.displayTitle, '✨ Editing main.dart');
      expect(window.handleTitle, '✨ Editing main.dart');
      expect(window.secondaryTitle, 'claude');
    });

    test('handleTitle falls back to the display title when needed', () {
      const window = TmuxWindow(
        index: 1,
        name: '__ test-emoji',
        isActive: false,
        paneTitle: '🔥 test-emoji',
      );

      expect(window.handleTitle, 'test-emoji');
    });

    test('handleTitle still prefers the window name when it is distinct', () {
      const window = TmuxWindow(
        index: 1,
        name: 'workspace',
        isActive: false,
        currentCommand: 'claude',
        currentPath: '/src/workspace',
        paneTitle: '✨ Editing main.dart',
      );

      expect(window.handleTitle, 'workspace');
    });

    test(
      'handleTitle uses the pane title for runtime-backed agent windows',
      () {
        const window = TmuxWindow(
          index: 1,
          name: 'Copilot CLI',
          isActive: true,
          currentCommand: 'node',
          currentPath: r'C:\src\MonkeySSH',
          paneTitle: 'Fix Windows session titles',
          agentTool: AgentLaunchTool.copilotCli,
        );

        expect(window.displayTitle, 'Fix Windows session titles');
        expect(window.handleTitle, 'Fix Windows session titles');
      },
    );

    test(
      'prefers decorated window name when pane title is the plain version',
      () {
        const window = TmuxWindow(
          index: 1,
          name: '🔥 test-emoji',
          isActive: false,
          paneTitle: 'test-emoji',
        );

        expect(window.displayTitle, '🔥 test-emoji');
        expect(window.secondaryTitle, isNull);
      },
    );

    test('drops placeholder underscore pane title in favor of plain title', () {
      const window = TmuxWindow(
        index: 1,
        name: 'test-session-setup',
        isActive: false,
        paneTitle: '_ Test session setup',
      );

      expect(window.displayTitle, 'Test session setup');
    });

    test(
      'uses agent and worktree context when pane title is the default host',
      () {
        const window = TmuxWindow(
          index: 1,
          name: 'codex',
          isActive: false,
          currentCommand: 'codex',
          currentPath: '/Users/depoll/Code/flutty.worktrees/fix-title/lib',
          paneTitle: 'mac-mini.home',
        );

        expect(window.displayTitle, 'Codex · fix-title');
        expect(window.handleTitle, 'Codex · fix-title');
        expect(window.secondaryTitle, isNull);
      },
    );

    test('uses useful CLI-provided pane titles over agent fallbacks', () {
      const window = TmuxWindow(
        index: 1,
        name: 'copilot',
        isActive: false,
        currentCommand: 'copilot',
        currentPath: '/Users/depoll/Code/flutty',
        paneTitle: '✨ Editing main.dart',
      );

      expect(window.displayTitle, '✨ Editing main.dart');
      expect(window.secondaryTitle, 'copilot');
    });

    test('uses agent context when Codex only reports the project title', () {
      const window = TmuxWindow(
        index: 1,
        name: 'codex',
        isActive: false,
        currentCommand: 'codex-aarch64-apple-darwin',
        currentPath: '/Users/depoll/Code/flutty',
        paneTitle: 'flutty',
      );

      expect(window.displayTitle, 'Codex · flutty');
      expect(window.handleTitle, 'Codex · flutty');
      expect(window.secondaryTitle, isNull);
    });

    test('uses agent context when Claude only reports its brand title', () {
      const window = TmuxWindow(
        index: 1,
        name: 'claude',
        isActive: false,
        currentCommand: '2.1.119',
        currentPath: '/Users/depoll/Code/flutty',
        paneTitle: '✳ Claude Code',
      );

      expect(window.displayTitle, 'Claude Code · flutty');
      expect(window.handleTitle, 'Claude Code · flutty');
      expect(window.secondaryTitle, isNull);
    });

    test('uses agent context when an agent only reports ready status', () {
      const window = TmuxWindow(
        index: 1,
        name: 'cursor-agent',
        isActive: false,
        currentCommand: 'node',
        currentPath: '/Users/depoll/Code/flutty',
        paneTitle:
            '◇  Ready (flutty)                                                               ',
      );

      expect(window.displayTitle, 'Cursor Agent · flutty');
      expect(window.handleTitle, 'Cursor Agent · flutty');
      expect(window.secondaryTitle, isNull);
    });

    test('uses app agent metadata when tmux exposes only wrapper names', () {
      const sep = tmuxWindowFieldSeparator;
      final line = [
        '1',
        'node',
        '0',
        'node',
        '/Users/depoll/Code/flutty',
        '',
        'mac-mini.home',
        '1712930000',
        'zsh',
        'cursor-agent',
      ].join(sep);
      final window = TmuxWindow.fromTmuxFormat(line);

      expect(window.agentTool, AgentLaunchTool.cursorAgent);
      expect(window.foregroundAgentTool, AgentLaunchTool.cursorAgent);
      expect(window.displayTitle, 'Cursor Agent · flutty');
      expect(window.handleTitle, 'Cursor Agent · flutty');
    });

    test('shows resumed agent session metadata from pane start commands', () {
      const window = TmuxWindow(
        index: 1,
        name: 'agent',
        isActive: false,
        currentPath: '/Users/depoll/Code/flutty',
        paneTitle: 'localhost',
        paneStartCommand: 'codex resume rollout-2026-04-26-session',
      );

      expect(window.foregroundAgentTool, AgentLaunchTool.codex);
      expect(window.agentSessionId, 'rollout-2026-04-26-session');
      expect(window.displayTitle, 'Codex · flutty');
      expect(window.secondaryTitle, 'active session');
    });

    test(
      'shows resumed Antigravity session metadata from pane start commands',
      () {
        const window = TmuxWindow(
          index: 1,
          name: 'agent',
          isActive: false,
          currentPath: '/Users/depoll/Code/flutty',
          paneTitle: 'localhost',
          paneStartCommand:
              'agy --conversation rollout-2026-04-26-conversation',
        );

        expect(window.foregroundAgentTool, AgentLaunchTool.antigravity);
        expect(window.agentSessionId, 'rollout-2026-04-26-conversation');
        expect(window.displayTitle, 'Antigravity · flutty');
        expect(window.secondaryTitle, 'active session');
      },
    );

    test('uses foreground command to label MonkeyMux Codex windows', () {
      const window = TmuxWindow(
        index: 5,
        name: 'flutty',
        isActive: true,
        currentCommand: 'codex',
        currentPath: '/Users/depoll/Code/flutty',
        paneTitle: 'flutty',
      );

      expect(window.foregroundAgentTool, AgentLaunchTool.codex);
      expect(window.displayTitle, 'Codex · flutty');
      expect(window.handleTitle, 'Codex · flutty');
      expect(window.secondaryTitle, isNull);
    });

    test('ignores decorative shell titles for agent windows', () {
      const window = TmuxWindow(
        index: 2,
        name: '|~',
        isActive: false,
        currentCommand: 'copilot',
        currentPath: '/Users/depoll/Code/flutty',
        paneTitle: '|~',
      );

      expect(window.foregroundAgentTool, AgentLaunchTool.copilotCli);
      expect(window.displayTitle, 'Copilot CLI · flutty');
      expect(window.handleTitle, 'Copilot CLI · flutty');
      expect(window.secondaryTitle, isNull);
    });

    test('shows live agent session titles when available', () {
      const window = TmuxWindow(
        index: 1,
        name: 'copilot',
        isActive: false,
        currentCommand: 'copilot',
        currentPath: '/Users/depoll/Code/flutty',
        paneTitle: 'localhost',
        activeAgentSessionId: '12345678-1234-1234-1234-1234567890ab',
        agentSessionTitle: 'Fix tmux session labels',
      );

      expect(window.agentSessionId, '12345678-1234-1234-1234-1234567890ab');
      expect(window.displayTitle, 'Fix tmux session labels');
      expect(window.handleTitle, 'Fix tmux session labels');
      expect(window.secondaryTitle, 'Copilot CLI');
    });

    test('shows live session titles alongside useful window titles', () {
      const window = TmuxWindow(
        index: 1,
        name: 'copilot',
        isActive: false,
        currentCommand: 'copilot',
        paneTitle: 'Editing main.dart',
        activeAgentSessionId: 'session-1',
        agentSessionTitle: 'Fix tmux session labels',
      );

      expect(window.displayTitle, 'Fix tmux session labels');
      expect(window.handleTitle, 'Fix tmux session labels');
      expect(window.secondaryTitle, 'Copilot CLI · Editing main.dart');
    });

    test('uses session names as titles and window titles as context', () {
      const window = TmuxWindow(
        index: 1,
        name: 'codex',
        isActive: false,
        currentCommand: 'codex',
        paneTitle: 'Editing main.dart',
        activeAgentSessionId: '12345678-1234-1234-1234-1234567890ab',
        agentSessionTitle: 'Fix live session labels',
        activeAgentSessionConfidence: AgentSessionConfidence.medium,
      );

      expect(window.displayTitle, 'Fix live session labels');
      expect(window.handleTitle, 'Fix live session labels');
      expect(window.secondaryTitle, 'Codex · Editing main.dart');
    });

    test('does not show raw session ids as titles', () {
      const window = TmuxWindow(
        index: 1,
        name: 'codex',
        isActive: false,
        currentCommand: 'codex',
        paneTitle: 'Editing main.dart',
        activeAgentSessionId: '12345678-1234-1234-1234-1234567890ab',
        activeAgentSessionConfidence: AgentSessionConfidence.medium,
      );

      expect(window.displayTitle, 'Editing main.dart');
      expect(window.secondaryTitle, 'Codex · active session');
    });

    test('copyWith can clear live agent session metadata', () {
      const window = TmuxWindow(
        index: 1,
        name: 'copilot',
        isActive: false,
        currentCommand: 'copilot',
        activeAgentSessionId: 'session-1',
        agentSessionTitle: 'Fix tmux session labels',
      );

      final cleared = window.copyWith(clearActiveAgentSessionMetadata: true);

      expect(cleared.activeAgentSessionId, isNull);
      expect(cleared.agentSessionTitle, isNull);
    });

    test('collapses live session titles that match useful window titles', () {
      const window = TmuxWindow(
        index: 1,
        name: 'copilot',
        isActive: false,
        currentCommand: 'copilot',
        paneTitle: 'Improve Theme Picker Keyboard UX',
        activeAgentSessionId: 'session-1',
        agentSessionTitle: 'Improve Theme Picker Keyboard UX',
      );

      expect(window.displayTitle, 'Improve Theme Picker Keyboard UX');
      expect(window.handleTitle, 'Improve Theme Picker Keyboard UX');
      expect(window.secondaryTitle, 'Copilot CLI');
    });

    test('handles empty command and path', () {
      const line = '1\x1fshell\x1f0\x1f\x1f';
      final window = TmuxWindow.fromTmuxFormat(line);

      expect(window.currentCommand, isNull);
      expect(window.currentPath, isNull);
    });

    test('detects alert flag', () {
      const line = '3\x1fbuild\x1f0\x1fmake\x1f/tmp\x1f#\x1fBuilding project';
      final window = TmuxWindow.fromTmuxFormat(line);

      expect(window.hasAlert, true);
      expect(window.statusLabel, 'alert');
    });

    test('computes idle state from activity epoch dynamically', () {
      final activityEpoch =
          (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 20;
      final window = TmuxWindow.fromTmuxFormat(
        '3\x1fclaude\x1f1\x1fclaude\x1f/tmp\x1f*\x1fWaiting\x1f$activityEpoch',
      );

      expect(window.lastActivityEpochSeconds, activityEpoch);
      expect(window.idleSeconds, greaterThanOrEqualTo(20));
      expect(window.isIdle, isTrue);
      expect(window.statusLabel, 'waiting');
    });

    test('throws on too few fields', () {
      expect(
        () => TmuxWindow.fromTmuxFormat('0\x1fvim'),
        throwsFormatException,
      );
    });

    test('statusLabel returns correct values', () {
      const active = TmuxWindow(index: 0, name: 'vim', isActive: true);
      const running = TmuxWindow(
        index: 1,
        name: 'build',
        isActive: false,
        currentCommand: 'make',
      );
      const idle = TmuxWindow(index: 2, name: 'bash', isActive: false);
      const waiting = TmuxWindow(
        index: 3,
        name: 'claude',
        isActive: false,
        currentCommand: 'claude',
        idleSeconds: 120,
      );
      const activeWaiting = TmuxWindow(
        index: 4,
        name: 'codex',
        isActive: true,
        currentCommand: 'codex',
        idleSeconds: 120,
      );

      expect(active.statusLabel, 'running');
      expect(running.statusLabel, 'running');
      expect(idle.statusLabel, 'running');
      expect(waiting.statusLabel, 'waiting');
      expect(waiting.isIdle, true);
      expect(activeWaiting.statusLabel, 'waiting');
      expect(activeWaiting.isIdle, true);
    });

    test(
      'foregroundAgentTool prefers the current command then window name',
      () {
        const currentCommandWindow = TmuxWindow(
          index: 1,
          name: 'node',
          isActive: false,
          currentCommand: 'copilot',
        );
        const namedWindow = TmuxWindow(
          index: 2,
          name: 'codex',
          isActive: false,
          currentCommand: 'node',
        );
        const unknownWindow = TmuxWindow(
          index: 3,
          name: 'vim',
          isActive: false,
          paneTitle: 'Editing main.dart',
        );

        expect(
          currentCommandWindow.foregroundAgentTool,
          AgentLaunchTool.copilotCli,
        );
        expect(namedWindow.foregroundAgentTool, AgentLaunchTool.codex);
        expect(unknownWindow.foregroundAgentTool, isNull);
      },
    );

    test('foregroundAgentTool prefers live command over stale metadata', () {
      const window = TmuxWindow(
        index: 1,
        name: 'stale copilot',
        isActive: true,
        currentCommand: 'codex',
        agentTool: AgentLaunchTool.copilotCli,
      );

      expect(window.foregroundAgentTool, AgentLaunchTool.codex);
    });

    test('foregroundAgentTool detects agent terminal titles', () {
      const copilotTitleWindow = TmuxWindow(
        index: 1,
        name: 'Copilot CLI · flutty',
        isActive: false,
        currentCommand: 'node',
      );
      const claudePaneTitleWindow = TmuxWindow(
        index: 2,
        name: 'zsh',
        isActive: false,
        currentCommand: 'node',
        paneTitle: 'Claude Code - fixing tests',
      );

      expect(
        copilotTitleWindow.foregroundAgentTool,
        AgentLaunchTool.copilotCli,
      );
      expect(
        claudePaneTitleWindow.foregroundAgentTool,
        AgentLaunchTool.claudeCode,
      );
    });

    test('recognizes Grok Build windows and resume session IDs', () {
      const window = TmuxWindow(
        index: 3,
        name: 'grok',
        isActive: false,
        currentCommand: 'grok',
        paneTitle: 'Grok Build · session resumption',
      );

      expect(window.foregroundAgentTool, AgentLaunchTool.grokBuild);
      expect(
        agentSessionIdFromLaunchCommand(
          "grok --resume '019f6cb5-f7e4'",
          tool: AgentLaunchTool.grokBuild,
        ),
        '019f6cb5-f7e4',
      );
      expect(
        agentSessionIdFromLaunchCommand(
          'grok -r 019f6cb5-short',
          tool: AgentLaunchTool.grokBuild,
        ),
        '019f6cb5-short',
      );
      expect(
        agentSessionIdFromLaunchCommand(
          'grok --load=019f6cb5-compat',
          tool: AgentLaunchTool.grokBuild,
        ),
        '019f6cb5-compat',
      );
    });

    test('copyWith can clear the activity timestamp', () {
      const window = TmuxWindow(
        index: 0,
        name: 'shell',
        isActive: false,
        lastActivityEpochSeconds: 100,
      );

      final cleared = window.copyWith(clearLastActivityEpochSeconds: true);

      expect(cleared.lastActivityEpochSeconds, isNull);
    });

    test('equality works correctly', () {
      const a = TmuxWindow(index: 0, name: 'vim', isActive: true);
      const b = TmuxWindow(index: 0, name: 'vim', isActive: true);
      const c = TmuxWindow(index: 1, name: 'bash', isActive: false);

      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });
  });

  group('applyTmuxWindowChangeEvent', () {
    test(
      'replaces an existing window snapshot and clears prior active state',
      () {
        const windows = <TmuxWindow>[
          TmuxWindow(index: 0, id: '@1', name: 'first', isActive: true),
          TmuxWindow(index: 1, id: '@2', name: 'second', isActive: false),
        ];

        final updated = applyTmuxWindowChangeEvent(
          windows,
          const TmuxWindowSnapshotEvent(
            TmuxWindow(
              index: 1,
              id: '@2',
              name: 'second-renamed',
              isActive: true,
              paneTitle: 'editing',
            ),
          ),
        );

        expect(updated[0].isActive, isFalse);
        expect(updated[1].isActive, isTrue);
        expect(updated[1].name, 'second-renamed');
        expect(updated[1].paneTitle, 'editing');
      },
    );

    test('retains inactive objects and sorts an unsorted snapshot input', () {
      const first = TmuxWindow(
        index: 0,
        id: '@1',
        name: 'first',
        isActive: false,
      );
      const second = TmuxWindow(
        index: 1,
        id: '@2',
        name: 'second',
        isActive: false,
      );
      final updated = applyTmuxWindowChangeEvent([
        second,
        first,
      ], TmuxWindowSnapshotEvent(second.copyWith(isActive: true)));
      expect(updated.map((window) => window.index), [0, 1]);
      expect(updated.first, same(first));
      expect(updated.clear, throwsUnsupportedError);
    });

    test('full lists retain first ID/index metadata without ID fallback', () {
      const first = TmuxWindow(
        index: 0,
        id: '@1',
        name: 'first',
        isActive: false,
        currentCommand: 'copilot',
        agentSessionTitle: 'First title',
      );
      final windows = [
        first,
        first.copyWith(agentSessionTitle: 'Duplicate title'),
      ];
      final updated = applyTmuxWindowChangeEvent(
        windows,
        const TmuxWindowListEvent([
          TmuxWindow(
            index: 2,
            id: '@1',
            name: 'first',
            isActive: false,
            currentCommand: 'copilot',
          ),
          TmuxWindow(
            index: 0,
            name: 'index',
            isActive: false,
            currentCommand: 'copilot',
          ),
          TmuxWindow(
            index: 0,
            id: '@2',
            name: 'new',
            isActive: false,
            currentCommand: 'copilot',
          ),
        ]),
      );
      expect(updated.map((window) => window.agentSessionTitle), [
        'First title',
        'First title',
        null,
      ]);
      expect(updated.map((window) => window.index), [2, 0, 0]);
      expect(updated.clear, throwsUnsupportedError);
    });

    test('matches snapshots by stable window ID when indexes changed', () {
      const windows = <TmuxWindow>[
        TmuxWindow(index: 1, id: '@7', name: 'agent', isActive: false),
        TmuxWindow(index: 2, id: '@8', name: 'shell', isActive: true),
      ];

      final updated = applyTmuxWindowChangeEvent(
        windows,
        const TmuxWindowSnapshotEvent(
          TmuxWindow(index: 3, id: '@7', name: 'agent', isActive: true),
        ),
      );

      expect(updated, hasLength(2));
      expect(updated.firstWhere((window) => window.id == '@7').index, 3);
      expect(updated.firstWhere((window) => window.id == '@8').isActive, false);
    });

    test(
      'replaces fresh terminal progress without resurrecting stale values',
      () {
        const windows = <TmuxWindow>[
          TmuxWindow(
            index: 0,
            id: '@1',
            name: 'build',
            isActive: true,
            terminalProgress: TerminalProgress(
              state: TerminalProgressState.normal,
              percentage: 25,
            ),
          ),
        ];

        final updated = applyTmuxWindowChangeEvent(
          windows,
          const TmuxWindowSnapshotEvent(
            TmuxWindow(
              index: 0,
              id: '@1',
              name: 'build',
              isActive: true,
              terminalProgress: TerminalProgress(
                state: TerminalProgressState.error,
                percentage: 80,
              ),
            ),
          ),
        );

        expect(
          updated.single.terminalProgress,
          const TerminalProgress(
            state: TerminalProgressState.error,
            percentage: 80,
          ),
        );

        final cleared = applyTmuxWindowChangeEvent(
          updated,
          const TmuxWindowSnapshotEvent(
            TmuxWindow(index: 0, id: '@1', name: 'build', isActive: true),
          ),
        );
        expect(cleared.single.terminalProgress, isNull);
      },
    );

    test('adds a new window snapshot in index order', () {
      const windows = <TmuxWindow>[
        TmuxWindow(index: 0, name: 'first', isActive: true),
      ];

      final updated = applyTmuxWindowChangeEvent(
        windows,
        const TmuxWindowSnapshotEvent(
          TmuxWindow(index: 2, name: 'third', isActive: false),
        ),
      );

      expect(updated.map((window) => window.index).toList(), [0, 2]);
    });

    test('preserves live agent session metadata across tmux snapshots', () {
      const windows = <TmuxWindow>[
        TmuxWindow(
          index: 1,
          id: '@7',
          panePid: 42,
          name: 'copilot',
          isActive: true,
          currentCommand: 'copilot',
          activeAgentSessionId: 'session-1',
          agentSessionTitle: 'Fix tmux session labels',
        ),
      ];

      final updated = applyTmuxWindowChangeEvent(
        windows,
        const TmuxWindowSnapshotEvent(
          TmuxWindow(
            index: 1,
            id: '@7',
            panePid: 42,
            name: 'copilot',
            isActive: true,
            currentCommand: 'copilot',
            paneTitle: 'localhost',
          ),
        ),
      );

      expect(updated.single.activeAgentSessionId, 'session-1');
      expect(updated.single.agentSessionTitle, 'Fix tmux session labels');
    });

    for (final fullList in [false, true]) {
      test('session metadata merge respects identity, list=$fullList', () {
        const existing = TmuxWindow(
          index: 1,
          id: '@7',
          panePid: 42,
          name: 'codex',
          isActive: true,
          currentCommand: 'codex',
          activeAgentSessionId: 'session-1',
          agentSessionTitle: 'Original title',
          activeAgentSessionConfidence: AgentSessionConfidence.medium,
        );
        final snapshot = existing
            .copyWith(clearActiveAgentSessionMetadata: true)
            .copyWith(activeAgentSessionId: 'session-1');
        for (final (incoming, expectedTitle, expectedConfidence) in [
          (snapshot, 'Original title', AgentSessionConfidence.medium),
          (
            snapshot.copyWith(
              activeAgentSessionConfidence: AgentSessionConfidence.high,
            ),
            'Original title',
            AgentSessionConfidence.high,
          ),
          (
            snapshot.copyWith(agentSessionTitle: 'Renamed session'),
            'Renamed session',
            null,
          ),
          (snapshot.copyWith(activeAgentSessionId: 'session-2'), null, null),
          (snapshot.copyWith(panePid: 43), null, null),
          (snapshot.copyWith(currentCommand: 'claude'), null, null),
          (snapshot.copyWith(hasUnsupportedAgentTool: true), null, null),
        ]) {
          final updated = applyTmuxWindowChangeEvent(
            [existing],
            fullList
                ? TmuxWindowListEvent([incoming])
                : TmuxWindowSnapshotEvent(incoming),
          ).single;
          expect(updated.agentSessionTitle, expectedTitle);
          expect(updated.activeAgentSessionId, incoming.activeAgentSessionId);
          expect(updated.activeAgentSessionConfidence, expectedConfidence);
        }

        // A title without a known session ID cannot be assigned to a new ID.
        final unknownSession = existing
            .copyWith(clearActiveAgentSessionMetadata: true)
            .copyWith(agentSessionTitle: 'Unbound title');
        final updated = applyTmuxWindowChangeEvent(
          [unknownSession],
          fullList
              ? TmuxWindowListEvent([snapshot])
              : TmuxWindowSnapshotEvent(snapshot),
        ).single;
        expect(updated.agentSessionTitle, isNull);
      });
    }
  });

  group('resolveTmuxReloadedWindows', () {
    test('preserves the prior non-empty window snapshot on empty reloads', () {
      const currentWindows = <TmuxWindow>[
        TmuxWindow(index: 0, name: 'shell', isActive: true),
      ];

      expect(resolveTmuxReloadedWindows(currentWindows, const <TmuxWindow>[]), [
        const TmuxWindow(index: 0, name: 'shell', isActive: true),
      ]);
    });

    test('keeps loading when no tmux windows have loaded yet', () {
      expect(resolveTmuxReloadedWindows(null, const <TmuxWindow>[]), isNull);
      expect(
        resolveTmuxReloadedWindows(const <TmuxWindow>[], const <TmuxWindow>[]),
        isNull,
      );
    });
  });

  group('shouldPreserveTmuxWindowSnapshotOnEmptyReload', () {
    test('preserves non-empty snapshots only up to the retry limit', () {
      const currentWindows = <TmuxWindow>[
        TmuxWindow(index: 0, name: 'shell', isActive: true),
      ];

      expect(
        shouldPreserveTmuxWindowSnapshotOnEmptyReload(
          currentWindows,
          consecutiveEmptyReloads: 1,
        ),
        isTrue,
      );
      expect(
        shouldPreserveTmuxWindowSnapshotOnEmptyReload(
          currentWindows,
          consecutiveEmptyReloads: 3,
        ),
        isTrue,
      );
      expect(
        shouldPreserveTmuxWindowSnapshotOnEmptyReload(
          currentWindows,
          consecutiveEmptyReloads: 4,
        ),
        isFalse,
      );
    });

    test('does not preserve empty or missing snapshots', () {
      expect(
        shouldPreserveTmuxWindowSnapshotOnEmptyReload(
          null,
          consecutiveEmptyReloads: 1,
        ),
        isFalse,
      );
      expect(
        shouldPreserveTmuxWindowSnapshotOnEmptyReload(
          const <TmuxWindow>[],
          consecutiveEmptyReloads: 1,
        ),
        isFalse,
      );
    });
  });

  group('resolveTmuxWindowReloadRetryDelay', () {
    test('uses exponential backoff with a cap', () {
      expect(resolveTmuxWindowReloadRetryDelay(0), const Duration(seconds: 2));
      expect(resolveTmuxWindowReloadRetryDelay(1), const Duration(seconds: 4));
      expect(resolveTmuxWindowReloadRetryDelay(2), const Duration(seconds: 8));
      expect(resolveTmuxWindowReloadRetryDelay(3), const Duration(seconds: 16));
      expect(resolveTmuxWindowReloadRetryDelay(4), const Duration(seconds: 30));
      expect(resolveTmuxWindowReloadRetryDelay(6), const Duration(seconds: 30));
    });
  });

  group('ToolSessionInfo', () {
    test('constructs with all fields', () {
      final info = ToolSessionInfo(
        toolName: 'Claude Code',
        sessionId: 'abc123',
        workingDirectory: '/home/user/project',
        lastActive: DateTime(2026, 4, 12),
        summary: 'Fix auth middleware',
      );

      expect(info.toolName, 'Claude Code');
      expect(info.sessionId, 'abc123');
      expect(info.summary, 'Fix auth middleware');
    });

    test('timeAgoLabel formats correctly', () {
      final now = DateTime.now();

      final justNow = ToolSessionInfo(
        toolName: 'Claude Code',
        sessionId: '1',
        lastActive: now,
      );
      expect(justNow.timeAgoLabel, 'just now');

      final minutesAgo = ToolSessionInfo(
        toolName: 'Claude Code',
        sessionId: '2',
        lastActive: now.subtract(const Duration(minutes: 30)),
      );
      expect(minutesAgo.timeAgoLabel, '30m ago');

      final hoursAgo = ToolSessionInfo(
        toolName: 'Claude Code',
        sessionId: '3',
        lastActive: now.subtract(const Duration(hours: 5)),
      );
      expect(hoursAgo.timeAgoLabel, '5h ago');

      final daysAgo = ToolSessionInfo(
        toolName: 'Claude Code',
        sessionId: '4',
        lastActive: now.subtract(const Duration(days: 3)),
      );
      expect(daysAgo.timeAgoLabel, '3d ago');

      final weeksAgo = ToolSessionInfo(
        toolName: 'Claude Code',
        sessionId: '5',
        lastActive: now.subtract(const Duration(days: 14)),
      );
      expect(weeksAgo.timeAgoLabel, '2w ago');
    });

    test('timeAgoLabel returns empty when lastActive is null', () {
      const info = ToolSessionInfo(toolName: 'Codex', sessionId: '1');
      expect(info.timeAgoLabel, '');
    });

    test('lastUpdatedLabel includes date and relative time', () {
      final now = DateTime.now();
      final lastActive = now.subtract(const Duration(hours: 5));
      final info = ToolSessionInfo(
        toolName: 'Claude Code',
        sessionId: '6',
        lastActive: lastActive,
      );

      final month = const [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ][lastActive.month - 1];
      expect(info.lastUpdatedLabel, '$month ${lastActive.day} | 5h ago');
    });

    test('equality uses toolName and sessionId', () {
      const a = ToolSessionInfo(
        toolName: 'Claude Code',
        sessionId: 'abc',
        summary: 'session A',
      );
      const b = ToolSessionInfo(
        toolName: 'Claude Code',
        sessionId: 'abc',
        summary: 'different summary',
      );
      const c = ToolSessionInfo(toolName: 'Codex', sessionId: 'abc');

      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });
  });

  group('parseTmuxSessionName', () {
    test('parses -s flag from new-session', () {
      expect(
        parseTmuxSessionName('tmux new-session -A -s myproject'),
        'myproject',
      );
    });

    test('parses combined -As flag', () {
      expect(parseTmuxSessionName('tmux new -As MonkeySSH'), 'MonkeySSH');
    });

    test('parses -t flag from attach', () {
      expect(parseTmuxSessionName('tmux attach -t dev'), 'dev');
    });

    test('parses quoted session name', () {
      expect(
        parseTmuxSessionName("tmux new-session -A -s 'my project'"),
        'my project',
      );
    });

    test('parses with cd prefix', () {
      expect(
        parseTmuxSessionName('cd /home/user && tmux new -As work'),
        'work',
      );
    });

    test('returns null for non-tmux command', () {
      expect(parseTmuxSessionName('htop'), isNull);
    });

    test('returns null for tmux subcommands containing flag-like suffixes', () {
      expect(parseTmuxSessionName('tmux list-sessions'), isNull);
      expect(
        parseTmuxSessionName('tmux list-sessions -F #{session_name}'),
        isNull,
      );
    });

    test('returns null for null/empty', () {
      expect(parseTmuxSessionName(null), isNull);
      expect(parseTmuxSessionName(''), isNull);
    });
  });

  group('buildTmuxCommand', () {
    test('builds basic command', () {
      expect(
        buildTmuxCommand(sessionName: 'dev'),
        r"tmux new-session -A -s 'dev' \; set-option -g focus-events on",
      );
    });

    test('includes working directory', () {
      expect(
        buildTmuxCommand(sessionName: 'dev', workingDirectory: '/home/user'),
        r"tmux new-session -A -s 'dev' -c '/home/user' \; set-option -g focus-events on",
      );
    });

    test('includes extra flags', () {
      expect(
        buildTmuxCommand(sessionName: 'dev', extraFlags: '-x 200 -y 50'),
        r"tmux new-session -A -s 'dev' -x 200 -y 50 \; set-option -g focus-events on",
      );
    });

    test('supports tmux commands in extra flags', () {
      expect(
        buildTmuxCommand(sessionName: 'dev', extraFlags: r'\; set status off'),
        r"tmux new-session -A -s 'dev' \; set status off \; set-option -g focus-events on",
      );
    });

    test('includes all options', () {
      expect(
        buildTmuxCommand(
          sessionName: 'dev',
          workingDirectory: '/tmp',
          extraFlags: '-n editor',
        ),
        r"tmux new-session -A -s 'dev' -c '/tmp' -n editor \; set-option -g focus-events on",
      );
    });
  });
}

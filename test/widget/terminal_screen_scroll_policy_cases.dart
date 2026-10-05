// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/presentation/screens/terminal/terminal_screen_policy.dart';

TmuxWindow _window({
  required int index,
  required bool isActive,
  bool? reportsMouseWheel,
  bool? mouseReportSgr,
  bool? bracketedPasteMode,
}) => TmuxWindow(
  index: index,
  name: 'w$index',
  isActive: isActive,
  terminalReportsMouseWheel: reportsMouseWheel,
  terminalMouseReportSgr: mouseReportSgr,
  terminalBracketedPasteMode: bracketedPasteMode,
);

void registerTerminalScreenScrollPolicyTests() {
  group('terminal_screen_scroll_policy', () {
    group('terminal scroll policy helpers', () {
      test(
        'simulates alt-buffer scroll on mobile when wheel reporting is off',
        () {
          expect(
            shouldUseSyntheticAltBufferScrollFallback(
              isUsingAltBuffer: true,
              terminalReportsMouseWheel: false,
            ),
            isTrue,
          );
        },
      );

      test('never simulates scroll outside the alt buffer', () {
        expect(
          shouldUseSyntheticAltBufferScrollFallback(
            isUsingAltBuffer: false,
            terminalReportsMouseWheel: false,
          ),
          isFalse,
        );
      });

      test('prefers explicit mouse reporting when the terminal reports wheel input', () {
        expect(
          shouldUseSyntheticAltBufferScrollFallback(
            isUsingAltBuffer: true,
            terminalReportsMouseWheel: true,
          ),
          isFalse,
        );
      });

      test(
        'does not synthesize arrows for agent tools without wheel reporting',
        () {
          expect(
            shouldUseSyntheticAltBufferScrollFallback(
              isUsingAltBuffer: true,
              terminalReportsMouseWheel: false,
              isAgentToolActive: true,
            ),
            isFalse,
          );
        },
      );
    });

    group('terminal touch scroll routing helper', () {
      test('routes mobile alt-buffer drags into terminal scroll input', () {
        expect(
          shouldRouteTouchScrollToTerminal(
            isMobile: true,
            isUsingAltBuffer: true,
            terminalReportsMouseWheel: false,
          ),
          isTrue,
        );
      });

      test(
        'keeps mobile agent drags in the viewport when wheel reporting is off',
        () {
          expect(
            shouldRouteTouchScrollToTerminal(
              isMobile: true,
              isUsingAltBuffer: true,
              terminalReportsMouseWheel: false,
              isAgentToolActive: true,
            ),
            isFalse,
          );
        },
      );

      test('routes mobile agent drags when wheel reporting is active', () {
        expect(
          shouldRouteTouchScrollToTerminal(
            isMobile: true,
            isUsingAltBuffer: true,
            terminalReportsMouseWheel: true,
            isAgentToolActive: true,
          ),
          isTrue,
        );
      });

      test('routes mobile mouse-reporting apps into terminal scroll input', () {
        expect(
          shouldRouteTouchScrollToTerminal(
            isMobile: true,
            isUsingAltBuffer: false,
            terminalReportsMouseWheel: true,
          ),
          isTrue,
        );
      });

      test('keeps plain mobile shell output scrollable in the viewport', () {
        expect(
          shouldRouteTouchScrollToTerminal(
            isMobile: true,
            isUsingAltBuffer: false,
            terminalReportsMouseWheel: false,
          ),
          isFalse,
        );
      });
    });

    group('terminal agent scroll context helper', () {
      test('uses startup tool before window metadata is loaded', () {
        expect(
          isAgentToolActiveForTerminalScroll(
            activeWindowTool: null,
            startupTool: AgentLaunchTool.copilotCli,
            hasWindowSnapshot: false,
          ),
          isTrue,
        );
      });

      test('prefers loaded window metadata over stale startup tool', () {
        expect(
          isAgentToolActiveForTerminalScroll(
            activeWindowTool: null,
            startupTool: AgentLaunchTool.copilotCli,
            hasWindowSnapshot: true,
          ),
          isFalse,
        );
      });

      test('detects current command while metadata catches up', () {
        expect(
          isAgentToolActiveForTerminalScroll(
            activeWindowTool: null,
            startupTool: null,
            hasWindowSnapshot: true,
            currentCommand: 'codex',
          ),
          isTrue,
        );
      });

      bool unlistedProgram({
        required bool isUsingAltBuffer,
        required bool terminalReportsMouseWheel,
        required bool bracketedPasteMode,
        String currentCommand = 'aider',
      }) => isAgentToolActiveForTerminalScroll(
        activeWindowTool: null,
        startupTool: null,
        hasWindowSnapshot: true,
        currentCommand: currentCommand,
        isUsingAltBuffer: isUsingAltBuffer,
        terminalReportsMouseWheel: terminalReportsMouseWheel,
        bracketedPasteMode: bracketedPasteMode,
      );

      test('treats an unlisted alt-screen REPL with bracketed paste as a '
          'line editor', () {
        expect(
          unlistedProgram(
            isUsingAltBuffer: true,
            terminalReportsMouseWheel: false,
            bracketedPasteMode: true,
          ),
          isTrue,
        );
      });

      test('keeps pagers, mouse TUIs and bare shells on the normal path', () {
        // A pager or htop in the alt screen never asks for bracketed paste.
        expect(
          unlistedProgram(
            isUsingAltBuffer: true,
            terminalReportsMouseWheel: false,
            bracketedPasteMode: false,
            currentCommand: 'less',
          ),
          isFalse,
        );
        // A mouse-aware TUI gets real wheel reports instead.
        expect(
          unlistedProgram(
            isUsingAltBuffer: true,
            terminalReportsMouseWheel: true,
            bracketedPasteMode: true,
          ),
          isFalse,
        );
        // zsh enables bracketed paste at its prompt, but in the main buffer.
        expect(
          unlistedProgram(
            isUsingAltBuffer: false,
            terminalReportsMouseWheel: false,
            bracketedPasteMode: true,
            currentCommand: 'zsh',
          ),
          isFalse,
        );
      });

      test('listed main-buffer agents keep the name fallback', () {
        for (final command in ['claude', 'copilot', 'codex', 'opencode']) {
          expect(
            unlistedProgram(
              isUsingAltBuffer: false,
              terminalReportsMouseWheel: false,
              bracketedPasteMode: false,
              currentCommand: command,
            ),
            isTrue,
            reason: command,
          );
        }
      });
    });

    group('terminal mux mouse mode scroll helpers', () {
      test('uses mux window mouse reporting when local mode is stale', () {
        expect(
          terminalReportsMouseWheelForScroll(
            localTerminalReportsMouseWheel: false,
            activeWindowReportsMouseWheel: true,
          ),
          isTrue,
        );
      });

      test('does not force SGR without mux SGR mode metadata', () {
        expect(
          shouldForceSgrTouchScroll(
            activeWindowReportsMouseWheel: true,
            activeWindowMouseReportSgr: false,
          ),
          isFalse,
        );
      });

      test('forces SGR when mux reports wheel and SGR modes', () {
        expect(
          shouldForceSgrTouchScroll(
            activeWindowReportsMouseWheel: true,
            activeWindowMouseReportSgr: true,
          ),
          isTrue,
        );
      });
    });

    group('active window terminal-mode signature', () {
      test('is null when no window is active', () {
        expect(
          activeTmuxWindowTerminalModeSignature([
            _window(index: 0, isActive: false, reportsMouseWheel: true),
          ]),
          isNull,
        );
      });

      test('captures the active window terminal mode state', () {
        final signature = activeTmuxWindowTerminalModeSignature([
          _window(
            index: 0,
            isActive: true,
            reportsMouseWheel: true,
            bracketedPasteMode: true,
          ),
          _window(index: 1, isActive: false, reportsMouseWheel: false),
        ]);
        expect(signature?.reportsMouseWheel, isTrue);
        expect(signature?.mouseReportSgr, isNull);
        expect(signature?.bracketedPasteMode, isTrue);
      });

      test('changes when the active window toggles mouse mode', () {
        final before = activeTmuxWindowTerminalModeSignature([
          _window(index: 0, isActive: true, reportsMouseWheel: false),
        ]);
        final after = activeTmuxWindowTerminalModeSignature([
          _window(index: 0, isActive: true, reportsMouseWheel: true),
        ]);
        expect(before == after, isFalse);
      });

      test('changes when the active window toggles SGR reporting', () {
        final before = activeTmuxWindowTerminalModeSignature([
          _window(
            index: 0,
            isActive: true,
            reportsMouseWheel: true,
            mouseReportSgr: false,
          ),
        ]);
        final after = activeTmuxWindowTerminalModeSignature([
          _window(
            index: 0,
            isActive: true,
            reportsMouseWheel: true,
            mouseReportSgr: true,
          ),
        ]);
        expect(before == after, isFalse);
      });

      test('changes when the active window toggles bracketed paste', () {
        final before = activeTmuxWindowTerminalModeSignature([
          _window(index: 0, isActive: true, bracketedPasteMode: false),
        ]);
        final after = activeTmuxWindowTerminalModeSignature([
          _window(index: 0, isActive: true, bracketedPasteMode: true),
        ]);
        expect(before == after, isFalse);
      });

      test('ignores mouse-mode changes on non-active windows', () {
        final before = activeTmuxWindowTerminalModeSignature([
          _window(index: 0, isActive: true, reportsMouseWheel: false),
          _window(index: 1, isActive: false, reportsMouseWheel: false),
        ]);
        final after = activeTmuxWindowTerminalModeSignature([
          _window(index: 0, isActive: true, reportsMouseWheel: false),
          _window(
            index: 1,
            isActive: false,
            reportsMouseWheel: true,
            bracketedPasteMode: true,
          ),
        ]);
        expect(before == after, isTrue);
      });
    });

    group('terminal output follow helpers', () {
      test('follows output when no scroll clients are attached yet', () {
        expect(
          shouldFollowTerminalOutput(
            hasScrollClients: false,
            currentOffset: 0,
            maxScrollExtent: 0,
          ),
          isTrue,
        );
      });

      test('keeps following when already at the bottom', () {
        expect(
          shouldFollowTerminalOutput(
            hasScrollClients: true,
            currentOffset: 99.5,
            maxScrollExtent: 100,
          ),
          isTrue,
        );
      });

      test(
        'stops following when the viewport is scrolled away from the bottom',
        () {
          expect(
            shouldFollowTerminalOutput(
              hasScrollClients: true,
              currentOffset: 72,
              maxScrollExtent: 100,
            ),
            isFalse,
          );
        },
      );
    });

    group('terminal scroll policy change helper', () {
      test('rebuilds when alt-buffer usage changes', () {
        expect(
          didTerminalScrollPolicyChange(
            previousIsUsingAltBuffer: false,
            nextIsUsingAltBuffer: true,
            previousReportsMouseWheel: false,
            nextReportsMouseWheel: false,
          ),
          isTrue,
        );
      });

      test('rebuilds when mouse-wheel reporting changes', () {
        expect(
          didTerminalScrollPolicyChange(
            previousIsUsingAltBuffer: true,
            nextIsUsingAltBuffer: true,
            previousReportsMouseWheel: false,
            nextReportsMouseWheel: true,
          ),
          isTrue,
        );
      });

      test('does not rebuild when scroll policy inputs are unchanged', () {
        expect(
          didTerminalScrollPolicyChange(
            previousIsUsingAltBuffer: true,
            nextIsUsingAltBuffer: true,
            previousReportsMouseWheel: true,
            nextReportsMouseWheel: true,
          ),
          isFalse,
        );
      });
    });

    group('monkeymux control-report suppression', () {
      bool suppress({
        bool isMonkeyMux = true,
        bool isMouseReport = true,
        bool isFocusReport = false,
        bool mouseReportingActive = false,
        bool focusReportingActive = false,
        bool isAgentToolActive = false,
        String? currentCommand = 'zsh',
      }) => shouldSuppressMonkeyMuxControlReport(
        isMonkeyMux: isMonkeyMux,
        isMouseReport: isMouseReport,
        isFocusReport: isFocusReport,
        mouseReportingActive: mouseReportingActive,
        focusReportingActive: focusReportingActive,
        isAgentToolActive: isAgentToolActive,
        currentCommand: currentCommand,
      );

      test('suppresses a mouse report for a bare shell foreground', () {
        expect(suppress(), isTrue);
      });

      test('suppresses a focus report for a bare shell foreground', () {
        expect(suppress(isMouseReport: false, isFocusReport: true), isTrue);
      });

      test('keeps mouse reports when the foreground app enabled mouse reporting '
          'even if the pane command probed as a shell', () {
        // Regression: opening the SFTP browser overwrites the tracked command
        // with the login shell (zsh) that Copilot runs under. The wheel report
        // must still reach the app so touch scroll keeps working.
        expect(suppress(mouseReportingActive: true), isFalse);
      });

      test('keeps focus reports when focus reporting is active', () {
        expect(
          suppress(
            isMouseReport: false,
            isFocusReport: true,
            focusReportingActive: true,
          ),
          isFalse,
        );
      });

      test('keeps reports when the active window is a coding agent', () {
        expect(suppress(isAgentToolActive: true), isFalse);
        expect(
          suppress(
            isMouseReport: false,
            isFocusReport: true,
            isAgentToolActive: true,
          ),
          isFalse,
        );
      });

      test('keeps reports when the tracked command is a known agent tool', () {
        expect(suppress(currentCommand: 'copilot'), isFalse);
      });

      test('never suppresses outside MonkeyMux', () {
        expect(suppress(isMonkeyMux: false), isFalse);
      });

      test('never suppresses non mouse/focus output', () {
        expect(suppress(isMouseReport: false), isFalse);
      });

      test('does not suppress when the command is unknown (non-shell)', () {
        expect(suppress(currentCommand: 'htop'), isFalse);
      });

      test('suppresses reports for every login shell, not just six', () {
        for (final shell in ['tcsh', '-ksh93', 'mksh', 'nu', 'pwsh.exe']) {
          expect(suppress(currentCommand: shell), isTrue, reason: shell);
        }
      });
    });
  });
}

// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';

void main() {
  group('buildAgentToolCommand', () {
    for (final (tool, yolo, expected) in const [
      (
        AgentLaunchTool.claudeCode,
        true,
        'claude --dangerously-skip-permissions',
      ),
      (AgentLaunchTool.copilotCli, true, 'copilot --yolo'),
      (AgentLaunchTool.codex, true, 'codex --yolo'),
      (
        AgentLaunchTool.openCode,
        true,
        r'OPENCODE_PERMISSION="{\"*\":\"allow\"}" opencode',
      ),
      (AgentLaunchTool.antigravity, true, 'agy --dangerously-skip-permissions'),
      (AgentLaunchTool.cursorAgent, true, 'cursor-agent --force'),
      (AgentLaunchTool.pi, false, 'pi'),
      (AgentLaunchTool.hermes, false, 'hermes'),
      (AgentLaunchTool.openclaw, false, 'openclaw tui'),
      (AgentLaunchTool.hermes, true, 'hermes --yolo'),
      (AgentLaunchTool.pi, true, 'pi'),
      (AgentLaunchTool.openclaw, true, 'openclaw tui'),
      (AgentLaunchTool.grokBuild, false, 'grok'),
      (AgentLaunchTool.grokBuild, true, 'grok --yolo'),
    ]) {
      test('${tool.name} launch with YOLO $yolo', () {
        expect(buildAgentToolCommand(tool, startInYoloMode: yolo), expected);
      });
    }

    test(
      'places profiles before terminal modes and preserves YOLO settings',
      () {
        expect(
          buildAgentToolCommand(
            AgentLaunchTool.hermes,
            launchProfile: 'work',
            startInYoloMode: true,
          ),
          "hermes --profile 'work' --yolo",
        );
        expect(
          buildAgentToolCommand(
            AgentLaunchTool.openclaw,
            launchProfile: 'ops',
            startInYoloMode: true,
          ),
          "openclaw --profile 'ops' tui",
        );
        expect(
          () => buildAgentToolCommand(
            AgentLaunchTool.claudeCode,
            launchProfile: 'unsupported',
          ),
          throwsFormatException,
        );
      },
    );
  });

  group('buildAgentResumeCommand', () {
    for (final (tool, session, yolo, expected) in const [
      (
        AgentLaunchTool.claudeCode,
        'claude-session',
        true,
        "claude --dangerously-skip-permissions --resume 'claude-session'",
      ),
      (
        AgentLaunchTool.copilotCli,
        'copilot-session',
        true,
        "copilot --yolo --resume 'copilot-session'",
      ),
      (
        AgentLaunchTool.codex,
        'codex-session',
        true,
        "codex --yolo resume 'codex-session'",
      ),
      (
        AgentLaunchTool.openCode,
        'opencode-session',
        true,
        r"""OPENCODE_PERMISSION="{\"*\":\"allow\"}" opencode --session 'opencode-session'""",
      ),
      (
        AgentLaunchTool.antigravity,
        'agy-session',
        true,
        "agy --dangerously-skip-permissions --conversation 'agy-session'",
      ),
      (
        AgentLaunchTool.cursorAgent,
        'cursor-session',
        true,
        "cursor-agent --force --resume 'cursor-session'",
      ),
      (
        AgentLaunchTool.openCode,
        '_continue',
        true,
        r'OPENCODE_PERMISSION="{\"*\":\"allow\"}" opencode --continue',
      ),
      (
        AgentLaunchTool.antigravity,
        '_continue',
        true,
        'agy --dangerously-skip-permissions --continue',
      ),
      (
        AgentLaunchTool.cursorAgent,
        '_continue',
        true,
        'cursor-agent --force --continue',
      ),
      (
        AgentLaunchTool.cursorAgent,
        'chat-42',
        false,
        "cursor-agent --resume 'chat-42'",
      ),
      (AgentLaunchTool.pi, 'abc123', false, "pi --session 'abc123'"),
      (AgentLaunchTool.pi, '_continue', false, 'pi --continue'),
      (
        AgentLaunchTool.hermes,
        '20250305_091523_a1b2',
        false,
        "hermes --resume '20250305_091523_a1b2'",
      ),
      (AgentLaunchTool.hermes, '_continue', true, 'hermes --yolo --continue'),
      (
        AgentLaunchTool.openclaw,
        'main',
        false,
        "openclaw tui --session 'main'",
      ),
      (AgentLaunchTool.openclaw, '_continue', false, 'openclaw tui'),
      (
        AgentLaunchTool.grokBuild,
        '019f6cb5-f7e4',
        false,
        "grok --resume '019f6cb5-f7e4'",
      ),
      (AgentLaunchTool.grokBuild, '_continue', true, 'grok --yolo --resume'),
    ]) {
      test('${tool.name} resumes $session with YOLO $yolo', () {
        expect(
          buildAgentResumeCommand(tool, session, startInYoloMode: yolo),
          expected,
        );
      });
    }
  });

  group('agentLaunchToolForCommandText', () {
    for (final (input, expected) in const [
      (
        r'OPENCODE_PERMISSION="{\"*\":\"allow\"}" /opt/bin/opencode -s abc',
        AgentLaunchTool.openCode,
      ),
      ('cd ~/repo && codex resume abc', AgentLaunchTool.codex),
      ('cursor-agent --resume abc', AgentLaunchTool.cursorAgent),
      ('cd ~/repo && cursor-agent --force', AgentLaunchTool.cursorAgent),
      ('node ./script.js', null),
      ("cd '/tmp/codex' && node", null),
      ('', null),
      ('openclaw tui', AgentLaunchTool.openclaw),
      ('cd ~/repo && grok --resume abc', AgentLaunchTool.grokBuild),
    ]) {
      test('$input resolves to $expected', () {
        expect(agentLaunchToolForCommandText(input), expected);
      });
    }
  });

  group('buildAgentLaunchCommand', () {
    test('builds a working-directory command without tmux', () {
      const preset = AgentLaunchPreset(
        tool: AgentLaunchTool.claudeCode,
        workingDirectory: '~/src/app',
        additionalArguments: '--resume',
      );

      expect(
        buildAgentLaunchCommand(preset),
        r'cd "$HOME/src/app" && claude --resume',
      );
    });

    test('builds a tmux command with quoted values', () {
      const preset = AgentLaunchPreset(
        tool: AgentLaunchTool.codex,
        workingDirectory: '~/src/app',
        tmuxSessionName: 'nightly review',
        tmuxExtraFlags: '-x 160 -y 48',
        additionalArguments: '--message "hello"',
      );

      expect(
        buildAgentLaunchCommand(preset),
        'tmux new-session -A -s \'nightly review\' -c '
        '"\$HOME/src/app" -x 160 -y 48 \'codex --message "hello"\' '
        r'\; set-option -g focus-events on',
      );
    });

    test('keeps MonkeyMux agent sessions as plain agent commands', () {
      const preset = AgentLaunchPreset(
        tool: AgentLaunchTool.codex,
        workingDirectory: '~/src/app',
        tmuxSessionName: 'nightly review',
        remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        tmuxExtraFlags: '-x 160 -y 48',
        tmuxDisableStatusBar: true,
        additionalArguments: '--message "hello"',
      );

      expect(preset.usesMonkeyMuxSession, isTrue);
      expect(preset.usesTmuxSession, isFalse);
      expect(
        buildAgentLaunchCommand(preset),
        r'cd "$HOME/src/app" && codex --message "hello"',
      );
    });

    test('ignores tmux flags when no tmux session is configured', () {
      const preset = AgentLaunchPreset(
        tool: AgentLaunchTool.codex,
        tmuxExtraFlags: '-x 160 -y 48',
        additionalArguments: '--message "hello"',
      );

      expect(buildAgentLaunchCommand(preset), 'codex --message "hello"');
    });

    test(
      'builds command for tmux with extra flags and no working directory',
      () {
        const preset = AgentLaunchPreset(
          tool: AgentLaunchTool.codex,
          tmuxSessionName: 'nightly review',
          tmuxExtraFlags: '-x 160 -y 48',
        );

        expect(
          buildAgentLaunchCommand(preset),
          'tmux new-session -A -s \'nightly review\' '
          '-x 160 -y 48 \'codex\' '
          r'\; set-option -g focus-events on',
        );
      },
    );

    test('quotes tmux flag values with spaces safely', () {
      const preset = AgentLaunchPreset(
        tool: AgentLaunchTool.codex,
        tmuxSessionName: 'nightly review',
        tmuxExtraFlags: '-n "review window"',
      );

      expect(
        buildAgentLaunchCommand(preset),
        "tmux new-session -A -s 'nightly review' -n 'review window' "
        r"'codex' \; set-option -g focus-events on",
      );
    });

    test('rejects tmux command separators in extra flags', () {
      const preset = AgentLaunchPreset(
        tool: AgentLaunchTool.codex,
        tmuxSessionName: 'nightly review',
        tmuxExtraFlags: r'-x 160 \; set status off',
      );

      expect(
        () => buildAgentLaunchCommand(preset),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains(r'\;'),
          ),
        ),
      );
    });

    test('can disable the tmux status bar for agent sessions', () {
      const preset = AgentLaunchPreset(
        tool: AgentLaunchTool.copilotCli,
        tmuxSessionName: 'copilot',
        tmuxDisableStatusBar: true,
      );

      expect(
        buildAgentLaunchCommand(preset),
        r"tmux new-session -A -s 'copilot' 'copilot' \; set status off \; set-option -g focus-events on",
      );
    });

    test('builds command for codex tool', () {
      const preset = AgentLaunchPreset(
        tool: AgentLaunchTool.codex,
        workingDirectory: '~/project',
      );

      expect(buildAgentLaunchCommand(preset), r'cd "$HOME/project" && codex');
    });

    test('builds command for openCode tool', () {
      const preset = AgentLaunchPreset(
        tool: AgentLaunchTool.openCode,
        workingDirectory: '~/work',
        tmuxSessionName: 'oc-session',
      );

      expect(
        buildAgentLaunchCommand(preset),
        "tmux new-session -A -s 'oc-session' -c "
        '"\$HOME/work" \'opencode\' '
        r'\; set-option -g focus-events on',
      );
    });

    test(
      'rejects removed Gemini presets without substituting another agent',
      () {
        const stored = {'tool': 'geminiCli', 'workingDirectory': '~/project'};
        expect(AgentLaunchPreset.tryFromJson(stored), isNull);
        expect(agentLaunchToolFromStorageName('geminiCli'), isNull);
        expect(
          AgentLaunchTool.uiDisplayOrder.map((tool) => tool.name),
          isNot(contains('geminiCli')),
        );
      },
    );

    test('adds yolo mode to supported presets', () {
      const preset = AgentLaunchPreset(
        tool: AgentLaunchTool.codex,
        workingDirectory: '~/project',
      );

      expect(
        buildAgentLaunchCommand(preset, startInYoloMode: true),
        r'cd "$HOME/project" && codex --yolo',
      );
    });

    test('normalizes existing codex yolo aliases', () {
      const preset = AgentLaunchPreset(
        tool: AgentLaunchTool.codex,
        additionalArguments: '--ask-for-approval never --model gpt-5.4',
      );

      expect(
        buildAgentLaunchCommand(preset, startInYoloMode: true),
        'codex --yolo --model gpt-5.4',
      );
    });

    test(
      'replaces conflicting codex approval and sandbox arguments in yolo mode',
      () {
        const preset = AgentLaunchPreset(
          tool: AgentLaunchTool.codex,
          additionalArguments:
              '--ask-for-approval on-request --sandbox workspace-write --model gpt-5.4',
        );

        expect(
          buildAgentLaunchCommand(preset, startInYoloMode: true),
          'codex --yolo --model gpt-5.4',
        );
      },
    );

    test(
      'rebuilds opencode in yolo mode with an allow-all permission override',
      () {
        const preset = AgentLaunchPreset(
          tool: AgentLaunchTool.openCode,
          workingDirectory: '~/project',
        );

        expect(
          buildAgentLaunchCommand(preset, startInYoloMode: true),
          r'cd "$HOME/project" && OPENCODE_PERMISSION="{\"*\":\"allow\"}" opencode',
        );
      },
    );
  });

  test('round-trips preset json', () {
    const preset = AgentLaunchPreset(
      tool: AgentLaunchTool.copilotCli,
      workingDirectory: '~/src/flutty',
      tmuxSessionName: 'copilot',
      tmuxExtraFlags: '-x 160 -y 48',
      tmuxDisableStatusBar: true,
      additionalArguments: '--resume',
    );

    final decoded = AgentLaunchPreset.tryFromJson(preset.toJson())!;

    expect(decoded.tool, preset.tool);
    expect(decoded.workingDirectory, preset.workingDirectory);
    expect(decoded.tmuxSessionName, preset.tmuxSessionName);
    expect(decoded.effectiveRemoteMuxBackend, preset.effectiveRemoteMuxBackend);
    expect(decoded.tmuxExtraFlags, preset.tmuxExtraFlags);
    expect(decoded.tmuxDisableStatusBar, isTrue);
    expect(decoded.additionalArguments, preset.additionalArguments);
  });

  test('decodes legacy session presets as tmux', () {
    final preset = AgentLaunchPreset.tryFromJson({
      'tool': 'codex',
      'tmuxSessionName': 'legacy-agent',
    })!;

    expect(preset.remoteMuxBackend, isNull);
    expect(preset.effectiveRemoteMuxBackend, RemoteMuxBackend.tmux);
    expect(preset.usesTmuxSession, isTrue);
  });

  test('round-trips new tool enum values through json', () {
    for (final tool in [
      AgentLaunchTool.codex,
      AgentLaunchTool.openCode,
      AgentLaunchTool.antigravity,
      AgentLaunchTool.cursorAgent,
    ]) {
      final preset = AgentLaunchPreset(tool: tool);
      final decoded = AgentLaunchPreset.tryFromJson(preset.toJson())!;
      expect(decoded.tool, tool, reason: '${tool.name} round-trip failed');
    }
  });

  group('AgentLaunchTool presentation', () {
    test('all tools have labels', () {
      for (final tool in AgentLaunchTool.values) {
        expect(tool.label, isNotEmpty, reason: '${tool.name} missing label');
      }
    });

    test('all tools have command names', () {
      for (final tool in AgentLaunchTool.values) {
        expect(
          tool.commandName,
          isNotEmpty,
          reason: '${tool.name} missing commandName',
        );
      }
    });

    test('new tool labels are correct', () {
      expect(AgentLaunchTool.codex.label, 'Codex');
      expect(AgentLaunchTool.openCode.label, 'OpenCode');
      expect(AgentLaunchTool.antigravity.label, 'Antigravity');
      expect(AgentLaunchTool.cursorAgent.label, 'Cursor Agent');
    });

    test('new tool command names are correct', () {
      expect(AgentLaunchTool.codex.commandName, 'codex');
      expect(AgentLaunchTool.openCode.commandName, 'opencode');
      expect(AgentLaunchTool.antigravity.commandName, 'agy');
      expect(AgentLaunchTool.cursorAgent.commandName, 'cursor-agent');
    });

    group('command name lookup', () {
      for (final (input, expected) in const [
        ('claude', AgentLaunchTool.claudeCode),
        ('/opt/homebrew/bin/codex', AgentLaunchTool.codex),
        (
          r'C:\Users\demo\AppData\Local\Programs\opencode.exe',
          AgentLaunchTool.openCode,
        ),
        (
          r'C:\Users\demo\AppData\Roaming\npm\copilot.cmd',
          AgentLaunchTool.copilotCli,
        ),
        ('gemini --yolo', null),
        ('gemini-cli', null),
        ('codex-cli', AgentLaunchTool.codex),
        ('agy --dangerously-skip-permissions', AgentLaunchTool.antigravity),
        ('antigravity', AgentLaunchTool.antigravity),
        ('antigravity-cli', AgentLaunchTool.antigravity),
        ('cursor-agent', AgentLaunchTool.cursorAgent),
        ('/Users/demo/.local/bin/cursor-agent', AgentLaunchTool.cursorAgent),
        ('vim', null),
        ('', null),
        ('claude-agent-acp', AgentLaunchTool.claudeCode),
        ('codex-acp', AgentLaunchTool.codex),
        ('cursor-agent-acp', AgentLaunchTool.cursorAgent),
        ('antigravity-acp', AgentLaunchTool.antigravity),
        ('agy-acp', AgentLaunchTool.antigravity),
        ('pi', AgentLaunchTool.pi),
        ('hermes', AgentLaunchTool.hermes),
        ('hermes-agent', AgentLaunchTool.hermes),
        ('openclaw', AgentLaunchTool.openclaw),
        ('/opt/homebrew/bin/pi', AgentLaunchTool.pi),
        ('grok', AgentLaunchTool.grokBuild),
      ]) {
        test('$input resolves to $expected', () {
          expect(agentLaunchToolForCommandName(input), expected);
        });
      }
    });

    test('does not duplicate an explicit Hermes yolo argument', () {
      expect(
        buildAgentToolCommand(
          AgentLaunchTool.hermes,
          additionalArguments: '--yolo --tui',
          startInYoloMode: true,
        ),
        'hermes --yolo --tui',
      );
    });

    test('normalizes explicit Grok permission arguments in yolo mode', () {
      expect(
        buildAgentToolCommand(
          AgentLaunchTool.grokBuild,
          additionalArguments: '--permission-mode ask --always-approve --trust',
          startInYoloMode: true,
        ),
        'grok --yolo --trust',
      );
    });

    test('quotes Windows profiles without cmd or PowerShell expansion', () {
      expect(
        buildAgentToolCommand(
          AgentLaunchTool.hermes,
          launchProfile: 'work & review',
          windows: true,
        ),
        contains('--profile "work & review"'),
      );
      for (final unsafe in [
        'unsafe%PATH%',
        r'unsafe$env:PATH',
        r'unsafe$(Get-Item .)',
        'unsafe`nvalue',
        'unsafe”value',
      ]) {
        expect(
          () => buildAgentToolCommand(
            AgentLaunchTool.hermes,
            launchProfile: unsafe,
            windows: true,
          ),
          throwsFormatException,
          reason: unsafe,
        );
      }
    });

    test('supportsYoloMode reflects each CLI startup capability', () {
      // Pi has no approval layer, and OpenClaw's YOLO preset is a persisted
      // exec-policy mutation rather than a per-launch flag.
      const withoutYolo = {AgentLaunchTool.pi, AgentLaunchTool.openclaw};
      for (final tool in AgentLaunchTool.values) {
        expect(
          tool.supportsYoloMode,
          !withoutYolo.contains(tool),
          reason: '${tool.name} yolo support is misreported',
        );
      }
    });
  });

  test('tryFromJson rejects unknown tool names instead of rewriting them', () {
    expect(AgentLaunchPreset.tryFromJson({'tool': 'unknownTool'}), isNull);
    expect(agentLaunchToolFromStorageName('codex'), AgentLaunchTool.codex);
    expect(agentLaunchToolFromStorageName('unknownTool'), isNull);
  });
}

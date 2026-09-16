import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/agent_management_service.dart';
import 'package:monkeyssh/domain/services/agent_session_discovery_service.dart';

void main() {
  const id = '01a0ac67-804e-7f22-8d0d-9a4e2ea626c9';
  const tool = AgentLaunchTool.museCode;

  test('Muse presets preserve identity and normalize permission overrides', () {
    const preset = AgentLaunchPreset(
      tool: tool,
      workingDirectory: '/work/project',
    );
    expect(AgentLaunchPreset.tryFromJson(preset.toJson())!.tool, tool);
    expect(buildAgentLaunchCommand(preset), "cd '/work/project' && muse");
    expect(
      buildAgentToolCommand(
        tool,
        startInYoloMode: true,
        additionalArguments:
            '--approval-mode untrusted --permission-profile=review --yolo --model muse',
      ),
      'muse --yolo --model muse',
    );
    expect(buildAgentResumeCommand(tool, id), "muse resume '$id'");
    expect(
      buildAgentResumeCommand(tool, '_continue', startInYoloMode: true),
      'muse --yolo resume --last',
    );
    expect(
      agentSessionIdFromLaunchCommand('muse resume --last', tool: tool),
      isNull,
    );
    expect(
      agentSessionIdFromLaunchCommand("muse --yolo resume '$id'", tool: tool),
      id,
    );
    expect(buildAgentResumeCommand(tool, "a'b"), "muse resume 'a'\"'\"'b'");
  });

  test(
    'Muse launcher, actual binary, adapter and window title share identity',
    () {
      for (final name in [
        'muse',
        '/home/u/.local/bin/muse-bin-1.3.0-R3233.1',
        'muse-code-acp',
      ]) {
        expect(agentLaunchToolForCommandName(name), tool);
      }
      expect(agentLaunchToolForCommandName('muse-bin-unrelated'), isNull);
      const window = TmuxWindow(
        id: '@1',
        index: 1,
        name: 'muse',
        isActive: true,
        currentCommand: 'muse-bin-1.3.0-R3233.1',
        paneTitle: 'Muse Code · task',
      );
      expect(window.foregroundAgentTool, tool);
    },
  );

  test(
    'Muse native chat uses a pinned separate adapter and terminal login',
    () {
      expect(
        agentLaunchToolForBuiltinAcpProviderId(acpMuseCodeProvider.id),
        tool,
      );
      expect(acpMuseCodeProvider.launchCommand.argv, ['muse-code-acp']);
      expect(acpMuseCodeProvider.adapterFallbackCommand!.argv, [
        'npx',
        '--yes',
        '@bex-co/muse-code-acp@0.6.0',
      ]);
      expect(acpMuseCodeProvider.terminalAuthCommand!.argv, ['muse', 'login']);
      expect(
        isApprovedAcpBuiltinLaunchOverride(
          acpMuseCodeProvider,
          AcpLaunchCommand(executable: '/opt/bin/muse-code-acp'),
        ),
        isTrue,
      );
      expect(
        isApprovedAcpBuiltinLaunchOverride(
          acpMuseCodeProvider,
          AcpLaunchCommand(
            executable: '/opt/bin/muse',
            arguments: const ['serve'],
          ),
        ),
        isFalse,
      );
    },
  );

  test('Muse probes disable updates and compare actual release revisions', () {
    final definition = agentCliRuntimeDefinitions.singleWhere(
      (d) => d.tool == tool,
    );
    expect(
      parseAgentVersion('Muse Code 1.3.0 (1.3.0-R3233.1)'),
      '1.3.0-R3233.1',
    );
    expect(compareAgentVersions('1.3.0-R999.1', '1.3.0-R1000.1'), lessThan(0));
    expect(
      buildAgentBatchProbeCommand([definition], windows: false),
      contains('MUSE_NO_AUTO_UPDATE=1'),
    );
    expect(
      buildAgentInstallCommand(definition, windows: false, update: false),
      contains('https://dev.meta.ai/install.sh'),
    );
    expect(
      buildAgentInstallCommand(definition, windows: true, update: false),
      isNull,
    );
    expect(
      buildAgentInstallCommand(
        definition,
        windows: false,
        update: true,
        detectionSource: 'PATH',
        executablePath: '/opt/tools/muse',
      ),
      contains(
        "MUSE_SYNC_UPDATE=1 MUSE_NO_AUTO_UPDATE=0 '/opt/tools/muse' --version",
      ),
    );
    expect(
      buildAgentInstallCommand(
        definition,
        windows: false,
        update: true,
        detectionSource: 'Homebrew',
        executablePath: '/opt/homebrew/bin/muse',
      ),
      contains("brew upgrade 'muse-code'"),
    );
  });

  test(
    'Muse index preserves arbitrary titles, microseconds and resume cwd',
    () {
      final sessions = parseMuseSessionIndex(
        jsonEncode([
          {
            'session_id': id,
            'title': 'Fix | tabs\nnext line',
            'workspace_root': '/work/project',
            'updated_at_us': 1789598859421796,
          },
          {'session_id': '--last', 'workspace_root': '/work/project'},
          {'session_id': id, 'workspace_root': ''},
        ]),
      );
      expect(sessions, hasLength(1));
      expect(sessions.single.summary, 'Fix | tabs\nnext line');
      expect(
        sessions.single.lastActive!.microsecondsSinceEpoch,
        1789598859421796,
      );
      expect(
        AgentSessionDiscoveryService().buildResumeCommand(sessions.single),
        "cd '/work/project' && muse resume '$id'",
      );
    },
  );

  test(
    'Muse log fallback ignores retained frames and truncated final records',
    () {
      final metadata = parseMuseSessionMetadata(
        [
          jsonEncode({'retained_frame': 'session_permission_transaction'}),
          jsonEncode({
            'payload_type': 'runtime.session.metadata',
            'stream': {'id': id},
            'payload': {
              'record': {'workspace_root': '/work/project'},
            },
          }),
          jsonEncode({
            'payload_type': 'runtime.user_intent.accepted',
            'payload': {
              'refill_blocks': [
                {'text': 'Fix the parser'},
              ],
            },
          }),
          '{"truncated":',
        ].join('\n'),
      );
      expect(metadata!.sessionId, id);
      expect(metadata.summary, 'Fix the parser');
      expect(parseMuseSessionMetadata('{broken'), isNull);
    },
  );
}

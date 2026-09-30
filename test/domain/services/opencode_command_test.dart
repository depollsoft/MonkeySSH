import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/services/agent_session_discovery_service.dart';
import 'package:monkeyssh/domain/services/tmux_service.dart';

void main() {
  test('launch and resume keep arguments when selecting an OpenCode alias', () {
    final launch = buildAgentLaunchCommand(
      const AgentLaunchPreset(
        tool: AgentLaunchTool.openCode,
        workingDirectory: '/project with spaces',
      ),
      executable: 'opencode2',
      startInYoloMode: true,
    );
    expect(agentLaunchToolForCommandText(launch), AgentLaunchTool.openCode);
    expect(launch, contains("'opencode2' --auto"));
    final resume = buildAgentResumeCommand(
      AgentLaunchTool.openCode,
      'ses_saved',
    );
    expect(
      replaceDefaultAgentExecutable(
        resume,
        AgentLaunchTool.openCode,
        'opencode2',
      ),
      "'opencode2' --session 'ses_saved'",
    );
    const explicit = "cd '/project' && /custom/opencode --session 'ses_saved'";
    expect(
      replaceDefaultAgentExecutable(
        explicit,
        AgentLaunchTool.openCode,
        'opencode2',
      ),
      explicit,
    );
    expect(
      replaceDefaultAgentExecutable(
        launch.replaceFirst("'opencode2'", 'opencode'),
        AgentLaunchTool.openCode,
        'opencode2',
      ),
      launch,
    );
  });

  test('remote detection prefers V2 with POSIX and Windows aliases', () {
    for (final output in [
      '/usr/local/bin/opencode\n/usr/local/bin/opencode2\n',
      'C:/tools/opencode.cmd\nC:/tools/opencode2.exe\n',
      '/usr/local/bin/opencode2\n',
    ]) {
      expect(
        preferredInstalledAgentExecutable(AgentLaunchTool.openCode, output),
        'opencode2',
      );
    }
    expect(
      preferredInstalledAgentExecutable(
        AgentLaunchTool.openCode,
        'opencode2\n',
      ),
      'opencode',
    );
  });

  for (final operation in ['v2.session.list', 'session.list', 'legacy']) {
    test('discovery executes an alias-only install with $operation', () async {
      final directory = await Directory.systemTemp.createTemp(
        'opencode-command-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final executable = File('${directory.path}/opencode2');
      await executable.writeAsString(
        r'''
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_CALLS"
if [ "$1" = api ] && [ "$2" != "$TEST_OPERATION" ]; then exit 1; fi
printf '[{"id":"ses_saved","directory":"/project"}]\n'
'''
            .trimLeft(),
      );
      await Process.run('/bin/chmod', ['+x', executable.path]);
      final log = File('${directory.path}/calls');
      final result = await Process.run(
        '/bin/sh',
        ['-c', buildOpenCodeSessionListCommand(12)],
        environment: {
          'PATH': directory.path,
          'TEST_CALLS': log.path,
          'TEST_OPERATION': operation,
        },
        includeParentEnvironment: false,
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, contains('ses_saved'));
      final calls = await log.readAsLines();
      expect(calls.first, startsWith('api v2.session.list '));
      expect(
        calls.length,
        operation == 'v2.session.list'
            ? 1
            : operation == 'session.list'
            ? 2
            : 3,
      );
      if (operation == 'legacy') {
        expect(calls.last, 'session list --format json -n 12');
      }
    }, skip: Platform.isWindows ? 'POSIX shell execution' : false);
  }
}

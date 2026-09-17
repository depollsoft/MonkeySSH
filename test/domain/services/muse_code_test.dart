import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/agent_management_service.dart';
import 'package:monkeyssh/domain/services/agent_session_discovery_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_acp_bridge_service.dart';
import 'package:monkeyssh/domain/services/windows_remote_powershell.dart';

import '../../helpers/powershell_test_helpers.dart';

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
        r'C:\Users\demo\AppData\Local\Programs\muse\muse.cmd',
        'muse-bin-1.3.0-R3233.1.exe',
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
      decodeEncodedPowerShell(
        buildAgentInstallCommand(definition, windows: true, update: false)!,
      ),
      contains('https://dev.meta.ai/install.ps1'),
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
    final windowsProbe = decodeEncodedPowerShell(
      buildAgentBatchProbeCommand([definition], windows: true),
    );
    expect(windowsProbe, contains(r"$env:MUSE_NO_AUTO_UPDATE=''''1'''';"));
    expect(windowsProbe, contains(r'Programs\muse'));
    final windowsUpdate = decodeEncodedPowerShell(
      buildAgentInstallCommand(
        definition,
        windows: true,
        update: true,
        detectionSource: 'PATH',
        executablePath:
            r"C:\Users\O'Brien\AppData\Local\Programs\muse\muse.cmd",
      )!,
    );
    expect(windowsUpdate, contains(r"$env:MUSE_SYNC_UPDATE='1'"));
    expect(windowsUpdate, contains(r"$env:MUSE_NO_AUTO_UPDATE='0'"));
    expect(
      windowsUpdate,
      contains(
        r"& 'C:\Users\O''Brien\AppData\Local\Programs\muse\muse.cmd' --version",
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
  for (final length in [0, 199, 200, 201, 500]) {
    test('Muse log summary truncates $length characters safely', () {
      final summary = 'x' * length;
      final metadata = parseMuseSessionMetadata(
        [
          jsonEncode({
            'payload_type': 'runtime.session.metadata',
            'stream': {'id': id},
            'payload': {
              'record': {'workspace_root': '/work'},
            },
          }),
          jsonEncode({
            'payload_type': 'runtime.user_intent.accepted',
            'payload': {
              'refill_blocks': [
                {'text': summary},
              ],
            },
          }),
        ].join('\n'),
      )!;
      if (length > 0) {
        expect(metadata.summary, 'x' * (length > 200 ? 200 : length));
      } else {
        expect(metadata.summary, isNotEmpty);
      }
    });
  }

  final powerShell = Platform.isWindows
      ? 'powershell.exe'
      : Platform.environment['MONKEYSSH_TEST_POWERSHELL'];

  test(
    'Muse prerequisite probe honors an executable override on POSIX',
    () async {
      final temp = await Directory.systemTemp.createTemp('muse probe ');
      addTearDown(() => temp.delete(recursive: true));
      final binary = File('${temp.path}/custom muse');
      await binary.writeAsString('#!/bin/sh\nexit 99\n');
      await Process.run('chmod', ['+x', binary.path]);
      final command = buildMonkeyMuxAcpExecutableProbeCommand(const ['muse']);
      for (final override in [
        binary.path,
        '${temp.path}/missing',
        'bash',
        temp.path,
        '   ',
      ]) {
        final valid = override == binary.path;
        final result = await Process.run(
          '/bin/bash',
          ['-c', command],
          environment: {
            'HOME': temp.path,
            'SHELL': '/bin/bash',
            'MUSE_CODE_EXECUTABLE': override,
          },
        );
        expect(result.exitCode, 0);
        final found = parseMonkeyMuxAcpExecutableProbeOutput(
          result.stdout as String,
          const ['muse'],
          dependencyNames: const {'muse'},
        );
        expect(found, valid ? {'muse': binary.path} : isEmpty);
      }
    },
    skip: Platform.isWindows ? 'Uses POSIX executable lookup' : false,
  );

  test(
    'PowerShell Muse prerequisite probe honors an executable override',
    () async {
      final script = buildMonkeyMuxAcpWindowsExecutableProbeScript(const [
        'muse',
      ]).replaceFirst(powerShellProfilePathPreamble, '');
      final temp = await Directory.systemTemp.createTemp('muse windows probe ');
      addTearDown(() => temp.delete(recursive: true));
      final binary = File('${temp.path}/custom muse.exe');
      await binary.writeAsString('fixture');
      for (final override in [
        binary.path,
        '${temp.path}/missing',
        'powershell.exe',
        temp.path,
        '   ',
      ]) {
        final valid = override == binary.path;
        final result = await Process.run(
          powerShell!,
          [
            '-NoProfile',
            '-NonInteractive',
            '-EncodedCommand',
            encodePowerShellCommand(script),
          ],
          environment: {'MUSE_CODE_EXECUTABLE': override},
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final found = parseMonkeyMuxAcpExecutableProbeOutput(
          result.stdout as String,
          const ['muse'],
          dependencyNames: const {'muse'},
        );
        expect(found.containsKey('muse'), valid);
      }
    },
    skip: powerShell == null ? 'Requires PowerShell' : false,
  );

  for (final scenario in ['shim', 'native', 'override', 'invalid version']) {
    test(
      'Windows Muse chat resolves $scenario executable',
      () async {
        final temp = await Directory.systemTemp.createTemp('muse chat ');
        addTearDown(() => temp.delete(recursive: true));
        final nativePath = '${temp.path}/muse-bin-1.3.0-R3233.1.exe';
        await File(nativePath).writeAsString('fixture');
        await File('${temp.path}/.muse-version').writeAsString(
          scenario == 'invalid version' ? '../invalid' : '1.3.0-R3233.1\n',
        );
        final provider = File('${temp.path}/adapter.ps1');
        await provider.writeAsString(
          r'[Console]::Write($env:MUSE_CODE_EXECUTABLE)',
        );
        final command = buildMonkeyMuxAcpProviderCommand(
          [provider.path],
          isWindows: true,
          providerId: AcpBuiltinProviderIds.museCode,
        );
        final script = decodeEncodedPowerShell(
          command,
        ).replaceFirst(powerShellProfilePathPreamble, '');
        final source = scenario == 'native'
            ? nativePath
            : '${temp.path}/muse.cmd';
        final fixture =
            'function Get-Command { [pscustomobject]@{Source=${powerShellSingleQuote(source)}} };'
            '${scenario == 'override' ? r"$env:MUSE_CODE_EXECUTABLE='custom.exe';" : r"$env:MUSE_CODE_EXECUTABLE='';"}'
            '$script';
        final result = await Process.run(powerShell!, [
          '-NoProfile',
          '-NonInteractive',
          '-EncodedCommand',
          encodePowerShellCommand(fixture),
        ]);
        if (scenario == 'invalid version') {
          expect(result.exitCode, isNot(0));
          expect(
            result.stderr,
            contains('Muse native executable was not found'),
          );
        } else {
          expect(result.exitCode, 0, reason: '${result.stderr}');
          expect(
            (result.stdout as String).replaceAll(r'\', '/'),
            scenario == 'override'
                ? 'custom.exe'
                : nativePath.replaceAll(r'\', '/'),
          );
        }
      },
      skip: powerShell == null ? 'Requires PowerShell' : false,
    );
  }

  test(
    'PowerShell bounds Muse traversal before filtering and limiting',
    () async {
      final temp = await Directory.systemTemp.createTemp('muse sessions ');
      addTearDown(() => temp.delete(recursive: true));
      final rootLog = File(
        '${temp.path}/muse/sessions/2026/09/16/$id/session.jsonl',
      );
      final nested = File(
        '${rootLog.parent.path}/subagent/worker/session.jsonl',
      );
      await rootLog.parent.create(recursive: true);
      await rootLog.writeAsString('{}');
      await rootLog.setLastModified(DateTime.utc(2026, 9, 15));
      await nested.parent.create(recursive: true);
      await nested.writeAsString('{}');
      final script = windowsListNewestFilesScript(
        relativeRoot: '.local/share/muse/sessions',
        maxDepth: 4,
        includeGlobs: const ['session.jsonl'],
        limit: 1,
        overrideRootEnvironmentVariable: 'XDG_DATA_HOME',
        overrideRelativeRoot: 'muse/sessions',
        // No path regex: the depth bound alone must exclude nested logs.
      );
      final result = await Process.run(
        powerShell!,
        [
          '-NoProfile',
          '-NonInteractive',
          '-EncodedCommand',
          encodePowerShellCommand(script),
        ],
        environment: {'XDG_DATA_HOME': temp.path},
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(
        (result.stdout as String).trim().replaceAll(r'\', '/'),
        rootLog.path.replaceAll(r'\', '/'),
      );
    },
    skip: powerShell == null ? 'Requires PowerShell' : false,
  );
}

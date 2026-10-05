// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';

void main() {
  group('AcpLaunchCommand', () {
    test('argv includes executable first', () {
      final command = AcpLaunchCommand(
        executable: 'copilot',
        arguments: const ['--acp', '--no-color'],
      );
      expect(command.argv, ['copilot', '--acp', '--no-color']);
    });

    test('equality and hashCode are value-based', () {
      final a = AcpLaunchCommand(
        executable: 'copilot',
        arguments: const ['--acp'],
      );
      final b = AcpLaunchCommand(
        executable: 'copilot',
        arguments: const ['--acp'],
      );
      final c = AcpLaunchCommand(
        executable: 'copilot',
        arguments: const ['--yolo'],
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse);
    });

    test('defensively copies arguments so later mutation of the source list '
        'does not change the command', () {
      final mutableArguments = ['--acp'];
      final command = AcpLaunchCommand(
        executable: 'copilot',
        arguments: mutableArguments,
      );

      mutableArguments.add('--malicious-flag');

      expect(command.arguments, ['--acp']);
    });

    test('toString does not leak the executable or argument values', () {
      final command = AcpLaunchCommand(
        executable: '/secret/path/to/agent',
        arguments: const ['--api-key', 'super-secret-value'],
      );
      final rendered = command.toString();
      expect(rendered, isNot(contains('/secret/path/to/agent')));
      expect(rendered, isNot(contains('super-secret-value')));
      expect(rendered, isNot(contains('--api-key')));
      expect(rendered, contains('argumentCount: 2'));
    });
  });

  group('built-in providers', () {
    test('acpBuiltinProviders contains every verified adapter', () {
      expect(acpBuiltinProviders, hasLength(11));
      expect(acpBuiltinProviders, contains(acpCopilotCliProvider));
      expect(acpBuiltinProviders, contains(acpClaudeAgentProvider));
      expect(acpBuiltinProviders, contains(acpCodexProvider));
      expect(acpBuiltinProviders, contains(acpOpenCodeProvider));
      expect(acpBuiltinProviders, contains(acpCursorAgentProvider));
      expect(acpBuiltinProviders, contains(acpAntigravityProvider));
      expect(acpBuiltinProviders, contains(acpPiProvider));
      expect(acpBuiltinProviders, contains(acpHermesProvider));
      expect(acpBuiltinProviders, contains(acpOpenClawProvider));
      expect(acpBuiltinProviders, contains(acpGrokBuildProvider));
    });

    test('built-in providers map one tool and one telemetry category each', () {
      final snakeCase = RegExp(r'^[a-z][a-z0-9_]*$');
      final categories = <String>{};
      final tools = <AgentLaunchTool>{};
      for (final provider in acpBuiltinProviders) {
        expect(provider.telemetryCategory, matches(snakeCase));
        expect(categories.add(provider.telemetryCategory), isTrue);
        expect(tools.add(provider.tool), isTrue);
        expect(
          agentLaunchToolForBuiltinAcpProviderId(provider.id),
          provider.tool,
        );
      }
      expect(agentLaunchToolForBuiltinAcpProviderId('custom-id'), isNull);
    });

    test('built-in provider IDs are stable and reserved', () {
      expect(acpCopilotCliProvider.id, 'builtin:copilot-cli');
      expect(acpClaudeAgentProvider.id, 'builtin:claude-agent-acp');
      expect(acpCodexProvider.id, 'builtin:codex-acp');
      expect(acpOpenCodeProvider.id, 'builtin:opencode');
      expect(acpCursorAgentProvider.id, 'builtin:cursor-agent-acp');
      expect(acpAntigravityProvider.id, 'builtin:antigravity-acp');
      expect(acpPiProvider.id, 'builtin:pi-acp');
      expect(acpHermesProvider.id, 'builtin:hermes-acp');
      expect(acpOpenClawProvider.id, 'builtin:openclaw-acp');
      expect(acpGrokBuildProvider.id, 'builtin:grok-build');
      for (final provider in acpBuiltinProviders) {
        expect(provider.id.startsWith(acpBuiltinProviderIdPrefix), isTrue);
      }
    });

    test('built-in providers expose executable probes', () {
      expect(
        acpCopilotCliProvider.executableProbe.candidateExecutableNames,
        contains('copilot'),
      );
      expect(
        acpClaudeAgentProvider.executableProbe.candidateExecutableNames,
        contains('claude-agent-acp'),
      );
      expect(acpCodexProvider.launchCommand.argv, ['codex-acp']);
      expect(
        acpOpenCodeProvider.executableProbe.candidateExecutableNames,
        contains('opencode'),
      );
      expect(acpCursorAgentProvider.launchCommand.argv, [
        'cursor-agent',
        'acp',
      ]);
      expect(
        acpAntigravityProvider.executableProbe.candidateExecutableNames,
        containsAll(['antigravity-acp', 'agy-acp', 'npx']),
      );
      expect(acpAntigravityProvider.launchCommand.argv, [
        'npx',
        '--yes',
        '--prefer-offline',
        'agy-acp@0.5.2',
      ]);
      expect(
        acpPiProvider.executableProbe.candidateExecutableNames,
        contains('pi-acp'),
      );
      expect(acpPiProvider.launchCommand.argv, ['pi-acp']);
      expect(acpHermesProvider.launchCommand.argv, ['hermes', 'acp']);
      expect(
        acpHermesProvider.launchProfileSupport?.discoveryKind,
        AcpLaunchProfileDiscoveryKind.nestedProfileDirectories,
      );
      expect(
        acpHermesProvider.launchProfileSupport?.profileHomeEnvironmentVariable,
        'HERMES_HOME',
      );
      expect(
        acpHermesProvider.launchProfileSupport?.nestedProfilesDirectory,
        'profiles',
      );
      expect(
        acpHermesProvider.launchProfileSupport?.activeProfileFile,
        'active_profile',
      );
      expect(
        acpHermesProvider.launchProfileSupport?.defaultProfileArgument,
        'default',
      );
      expect(acpOpenClawProvider.launchCommand.argv, ['openclaw', 'acp']);
      expect(
        acpOpenClawProvider.launchProfileSupport?.homeDirectoryPrefix,
        '.openclaw-',
      );
      expect(acpCursorAgentProvider.launchProfileSupport, isNull);
      expect(acpGrokBuildProvider.launchCommand.argv, [
        'grok',
        'agent',
        'stdio',
      ]);
    });

    test('resolved built-in executable overrides stay constrained', () {
      expect(
        isApprovedAcpBuiltinLaunchOverride(
          acpCursorAgentProvider,
          AcpLaunchCommand(
            executable: '/Users/demo/.local/bin/cursor-agent',
            arguments: acpCursorAgentProvider.launchCommand.arguments,
          ),
        ),
        isTrue,
      );
      expect(
        isApprovedAcpBuiltinLaunchOverride(
          acpCursorAgentProvider,
          AcpLaunchCommand(
            executable: r'C:\Tools\agent.cmd',
            arguments: const ['acp'],
          ),
        ),
        isTrue,
      );
      expect(
        isApprovedAcpBuiltinLaunchOverride(
          acpClaudeAgentProvider,
          AcpLaunchCommand(
            executable: '/opt/homebrew/bin/npx',
            arguments: const [
              '--yes',
              '@agentclientprotocol/claude-agent-acp@0.70.0',
            ],
          ),
        ),
        isTrue,
      );
      expect(
        isApprovedAcpBuiltinLaunchOverride(
          acpHermesProvider,
          AcpLaunchCommand(
            executable: '/Users/demo/.local/bin/hermes',
            arguments: const ['--profile', 'work', 'acp'],
          ),
        ),
        isTrue,
      );
      expect(
        isApprovedAcpBuiltinLaunchOverride(
          acpOpenClawProvider,
          AcpLaunchCommand(
            executable: '/Users/demo/.local/bin/openclaw',
            arguments: const ['--profile', 'ops', 'acp'],
          ),
        ),
        isTrue,
      );
      expect(
        isApprovedAcpBuiltinLaunchOverride(
          acpHermesProvider,
          AcpLaunchCommand(
            executable: '/Users/demo/.local/bin/hermes',
            arguments: const ['--profile', '../unsafe', 'acp'],
          ),
        ),
        isFalse,
      );
      expect(
        isApprovedAcpBuiltinLaunchOverride(
          acpHermesProvider,
          AcpLaunchCommand(
            executable: '/Users/demo/.local/bin/hermes',
            arguments: const ['acp', '--profile', 'work'],
          ),
        ),
        isFalse,
      );
      expect(
        isApprovedAcpBuiltinLaunchOverride(
          acpCursorAgentProvider,
          AcpLaunchCommand(
            executable: 'cursor-agent',
            arguments: const ['acp'],
          ),
        ),
        isFalse,
      );
      expect(
        isApprovedAcpBuiltinLaunchOverride(
          acpCursorAgentProvider,
          AcpLaunchCommand(
            executable: '/tmp/cursor-agent',
            arguments: const ['acp', '--unapproved'],
          ),
        ),
        isFalse,
      );
    });

    test('built-in providers expose terminal-auth command metadata', () {
      expect(acpCopilotCliProvider.terminalAuthCommand, isNotNull);
      expect(acpOpenCodeProvider.terminalAuthCommand, isNotNull);
      expect(acpClaudeAgentProvider.terminalAuthCommand?.argv, [
        'claude',
        '/login',
      ]);
      expect(acpCursorAgentProvider.terminalAuthCommand?.argv, [
        'monkeymux',
        'cursor-agent-auth',
      ]);
      expect(acpAntigravityProvider.terminalAuthCommand, isNotNull);
      expect(acpGrokBuildProvider.terminalAuthCommand, isNotNull);
      expect(acpPiProvider.terminalAuthCommand, isNull);
    });

    test('Copilot CLI terminal auth explicitly runs "copilot login"', () {
      final terminalAuthCommand = acpCopilotCliProvider.terminalAuthCommand!;
      expect(terminalAuthCommand.executable, 'copilot');
      expect(terminalAuthCommand.arguments, ['login']);
    });
  });

  group('AcpExecutableProbe', () {
    test('defensively copies its lists so later mutation of the source lists '
        'does not change the probe', () {
      final mutableCandidates = ['agent'];
      final mutableVersionArgs = ['--version'];
      final mutableRequirements = ['muse'];
      final probe = AcpExecutableProbe(
        candidateExecutableNames: mutableCandidates,
        versionArguments: mutableVersionArgs,
        requiredExecutableNames: mutableRequirements,
      );

      mutableCandidates.add('other-agent');
      mutableVersionArgs.add('--extra');
      mutableRequirements.add('other');

      expect(probe.candidateExecutableNames, ['agent']);
      expect(probe.versionArguments, ['--version']);
      expect(probe.requiredExecutableNames, ['muse']);
    });
  });
}

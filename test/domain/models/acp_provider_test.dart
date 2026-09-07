// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';

void main() {
  group('AcpLaunchCommand', () {
    test('argv includes executable first', () {
      final command = AcpLaunchCommand(
        executable: 'copilot',
        arguments: const ['--acp', '--no-color'],
      );
      expect(command.argv, ['copilot', '--acp', '--no-color']);
    });

    test('round-trips through JSON', () {
      final command = AcpLaunchCommand(
        executable: 'opencode',
        arguments: const ['acp', '--log-level', 'ERROR'],
      );
      final decoded = AcpLaunchCommand.fromJson(command.toJson());
      expect(decoded, command);
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
      final fingerprintBefore = computeAcpLaunchCommandFingerprint(command);

      mutableArguments.add('--malicious-flag');

      expect(command.arguments, ['--acp']);
      expect(computeAcpLaunchCommandFingerprint(command), fingerprintBefore);
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

    group('tryFromJson', () {
      test('returns null for non-map input', () {
        expect(AcpLaunchCommand.tryFromJson('not a map'), isNull);
        expect(AcpLaunchCommand.tryFromJson([1, 2, 3]), isNull);
        expect(AcpLaunchCommand.tryFromJson(null), isNull);
      });

      test('returns null when a map key is not a string', () {
        expect(AcpLaunchCommand.tryFromJson({1: 'copilot'}), isNull);
      });

      test('returns null when executable is missing or blank', () {
        expect(AcpLaunchCommand.tryFromJson({'arguments': []}), isNull);
        expect(
          AcpLaunchCommand.tryFromJson({'executable': '   ', 'arguments': []}),
          isNull,
        );
      });

      test('returns null when arguments is not a list', () {
        expect(
          AcpLaunchCommand.tryFromJson({
            'executable': 'copilot',
            'arguments': 'oops',
          }),
          isNull,
        );
      });

      test('returns null when an argument is not a string', () {
        expect(
          AcpLaunchCommand.tryFromJson({
            'executable': 'copilot',
            'arguments': ['--acp', 5],
          }),
          isNull,
        );
      });

      test('returns null when the executable contains a NUL byte', () {
        expect(
          AcpLaunchCommand.tryFromJson({
            'executable': 'copi\u0000lot',
            'arguments': [],
          }),
          isNull,
        );
      });

      test('returns null when an argument exceeds the length limit', () {
        expect(
          AcpLaunchCommand.tryFromJson({
            'executable': 'copilot',
            'arguments': ['a' * (acpLaunchCommandArgumentMaxLength + 1)],
          }),
          isNull,
        );
      });

      test('returns a valid command for well-formed input', () {
        final command = AcpLaunchCommand.tryFromJson({
          'executable': 'copilot',
          'arguments': ['--acp'],
        });
        expect(
          command,
          AcpLaunchCommand(executable: 'copilot', arguments: const ['--acp']),
        );
      });

      test('accepts input without an arguments key', () {
        final command = AcpLaunchCommand.tryFromJson({'executable': 'copilot'});
        expect(command, AcpLaunchCommand(executable: 'copilot'));
      });
    });
  });

  group('validateAcpLaunchCommand', () {
    test('throws for a blank executable', () {
      expect(
        () => validateAcpLaunchCommand(AcpLaunchCommand(executable: '  ')),
        throwsFormatException,
      );
    });

    test('throws for a NUL byte in an argument', () {
      expect(
        () => validateAcpLaunchCommand(
          AcpLaunchCommand(
            executable: 'copilot',
            arguments: const ['--acp\u0000'],
          ),
        ),
        throwsFormatException,
      );
    });

    test('throws when too many arguments are supplied', () {
      final tooMany = List.generate(
        acpLaunchCommandMaxArgumentCount + 1,
        (i) => 'arg$i',
      );
      expect(
        () => validateAcpLaunchCommand(
          AcpLaunchCommand(executable: 'copilot', arguments: tooMany),
        ),
        throwsFormatException,
      );
    });

    test('accepts a well-formed command', () {
      expect(
        () => validateAcpLaunchCommand(
          AcpLaunchCommand(executable: 'copilot', arguments: const ['--acp']),
        ),
        returnsNormally,
      );
    });
  });

  group('validateAcpCustomProviderId', () {
    test('throws for blank IDs', () {
      expect(() => validateAcpCustomProviderId(''), throwsFormatException);
      expect(() => validateAcpCustomProviderId('   '), throwsFormatException);
    });

    test('throws for IDs with control characters', () {
      expect(
        () => validateAcpCustomProviderId('my\u0000id'),
        throwsFormatException,
      );
    });

    test('throws for IDs longer than the max length', () {
      expect(
        () => validateAcpCustomProviderId('a' * (acpProviderIdMaxLength + 1)),
        throwsFormatException,
      );
    });

    test('throws for IDs using the reserved built-in prefix', () {
      expect(
        () => validateAcpCustomProviderId('builtin:my-provider'),
        throwsFormatException,
      );
    });

    test('trims and returns a valid ID', () {
      expect(validateAcpCustomProviderId('  my-id  '), 'my-id');
    });
  });

  group('validateAcpProviderLabel', () {
    test('throws for blank labels', () {
      expect(() => validateAcpProviderLabel(''), throwsFormatException);
    });

    test('throws for labels longer than the max length', () {
      expect(
        () => validateAcpProviderLabel('a' * (acpProviderLabelMaxLength + 1)),
        throwsFormatException,
      );
    });

    test('throws for labels with control characters', () {
      expect(
        () => validateAcpProviderLabel('My\u0000Label'),
        throwsFormatException,
      );
    });

    test('trims and returns a valid label', () {
      expect(validateAcpProviderLabel('  My Label  '), 'My Label');
    });
  });

  group('computeAcpLaunchCommandFingerprint', () {
    test('is deterministic for identical commands', () {
      final a = AcpLaunchCommand(
        executable: 'copilot',
        arguments: const ['--acp'],
      );
      final b = AcpLaunchCommand(
        executable: 'copilot',
        arguments: const ['--acp'],
      );
      expect(
        computeAcpLaunchCommandFingerprint(a),
        computeAcpLaunchCommandFingerprint(b),
      );
    });

    test('changes when the executable changes', () {
      final a = AcpLaunchCommand(
        executable: 'copilot',
        arguments: const ['--acp'],
      );
      final b = AcpLaunchCommand(
        executable: 'opencode',
        arguments: const ['--acp'],
      );
      expect(
        computeAcpLaunchCommandFingerprint(a),
        isNot(computeAcpLaunchCommandFingerprint(b)),
      );
    });

    test('changes when an argument changes', () {
      final a = AcpLaunchCommand(
        executable: 'copilot',
        arguments: const ['--acp'],
      );
      final b = AcpLaunchCommand(
        executable: 'copilot',
        arguments: const ['--yolo'],
      );
      expect(
        computeAcpLaunchCommandFingerprint(a),
        isNot(computeAcpLaunchCommandFingerprint(b)),
      );
    });

    test('changes when argument order changes', () {
      final a = AcpLaunchCommand(
        executable: 'copilot',
        arguments: const ['--a', '--b'],
      );
      final b = AcpLaunchCommand(
        executable: 'copilot',
        arguments: const ['--b', '--a'],
      );
      expect(
        computeAcpLaunchCommandFingerprint(a),
        isNot(computeAcpLaunchCommandFingerprint(b)),
      );
    });

    test('is a lowercase hex SHA-256 digest', () {
      final command = AcpLaunchCommand(executable: 'copilot');
      final fingerprint = computeAcpLaunchCommandFingerprint(command);
      expect(fingerprint, matches(RegExp(r'^[0-9a-f]{64}$')));
    });
  });

  group('built-in providers', () {
    test('acpBuiltinProviders contains every verified adapter', () {
      expect(acpBuiltinProviders, hasLength(10));
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
        expect(
          provider.id.startsWith(acpCustomProviderReservedIdPrefix),
          isTrue,
        );
      }
    });

    test('built-in launch commands are valid and exclude a cwd concept', () {
      for (final provider in acpBuiltinProviders) {
        expect(
          () => validateAcpLaunchCommand(provider.launchCommand),
          returnsNormally,
        );
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
      expect(acpPiProvider.executableProbe.candidateExecutableNames, ['npx']);
      expect(acpPiProvider.launchCommand.argv, [
        'npx',
        '--yes',
        '--prefer-offline',
        '--allow-remote=all',
        'https://github.com/depollsoft/pi-acp/archive/8e7889c39ac550d36c72e15e17f7bf7338bbfaac.tar.gz',
      ]);
      expect(acpPiProvider.adapterFallbackCommand, acpPiProvider.launchCommand);
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
          acpPiProvider,
          AcpLaunchCommand(
            executable: '/opt/homebrew/bin/npx',
            arguments: acpPiProvider.launchCommand.arguments,
          ),
        ),
        isTrue,
      );
      expect(
        isApprovedAcpBuiltinLaunchOverride(
          acpPiProvider,
          AcpLaunchCommand(executable: '/opt/homebrew/bin/pi-acp'),
        ),
        isFalse,
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

    test('AcpBuiltinProviderView exposes the wrapped provider', () {
      final view = AcpBuiltinProviderView(acpCopilotCliProvider);
      expect(view.id, acpCopilotCliProvider.id);
      expect(view.label, acpCopilotCliProvider.label);
      expect(view.launchCommand, acpCopilotCliProvider.launchCommand);
      expect(view.isCustom, isFalse);
    });
  });

  group('AcpExecutableProbe', () {
    test('defensively copies its lists so later mutation of the source lists '
        'does not change the probe', () {
      final mutableCandidates = ['agent'];
      final mutableVersionArgs = ['--version'];
      final probe = AcpExecutableProbe(
        candidateExecutableNames: mutableCandidates,
        versionArguments: mutableVersionArgs,
      );

      mutableCandidates.add('other-agent');
      mutableVersionArgs.add('--extra');

      expect(probe.candidateExecutableNames, ['agent']);
      expect(probe.versionArguments, ['--version']);
    });
  });

  group('AcpCommandApproval', () {
    test('approve computes a matching fingerprint', () {
      final command = AcpLaunchCommand(executable: 'copilot');
      final approval = AcpCommandApproval.approve(
        command,
        now: DateTime.utc(2026),
      );
      expect(
        approval.commandFingerprint,
        computeAcpLaunchCommandFingerprint(command),
      );
      expect(approval.approvedAt, DateTime.utc(2026));
    });

    test('round-trips through JSON', () {
      final command = AcpLaunchCommand(executable: 'copilot');
      final approval = AcpCommandApproval.approve(
        command,
        now: DateTime.utc(2026),
      );
      final decoded = AcpCommandApproval.tryFromJson(approval.toJson());
      expect(decoded, approval);
    });

    group('tryFromJson', () {
      test('returns null for non-map input', () {
        expect(AcpCommandApproval.tryFromJson('nope'), isNull);
      });

      test('returns null when commandFingerprint is missing or blank', () {
        expect(
          AcpCommandApproval.tryFromJson({
            'approvedAt': '2026-01-01T00:00:00Z',
          }),
          isNull,
        );
        expect(
          AcpCommandApproval.tryFromJson({
            'commandFingerprint': '',
            'approvedAt': '2026-01-01T00:00:00Z',
          }),
          isNull,
        );
      });

      test('returns null when approvedAt is missing or unparseable', () {
        expect(
          AcpCommandApproval.tryFromJson({'commandFingerprint': 'abc'}),
          isNull,
        );
        expect(
          AcpCommandApproval.tryFromJson({
            'commandFingerprint': 'abc',
            'approvedAt': 'not-a-date',
          }),
          isNull,
        );
      });
    });
  });

  group('AcpCustomProviderDefinition', () {
    final command = AcpLaunchCommand(
      executable: 'my-agent',
      arguments: const ['--acp'],
    );

    test('create validates id, label, and command', () {
      expect(
        () => AcpCustomProviderDefinition.create(
          id: '',
          label: 'My Agent',
          launchCommand: command,
        ),
        throwsFormatException,
      );
      expect(
        () => AcpCustomProviderDefinition.create(
          id: 'my-agent',
          label: '',
          launchCommand: command,
        ),
        throwsFormatException,
      );
      expect(
        () => AcpCustomProviderDefinition.create(
          id: 'my-agent',
          label: 'My Agent',
          launchCommand: AcpLaunchCommand(executable: ''),
        ),
        throwsFormatException,
      );
    });

    test('create rejects the reserved built-in ID prefix', () {
      expect(
        () => AcpCustomProviderDefinition.create(
          id: 'builtin:my-agent',
          label: 'My Agent',
          launchCommand: command,
        ),
        throwsFormatException,
      );
    });

    test('create trims id and label and approves the command', () {
      final definition = AcpCustomProviderDefinition.create(
        id: '  my-agent  ',
        label: '  My Agent  ',
        launchCommand: command,
        now: DateTime.utc(2026),
      );
      expect(definition.id, 'my-agent');
      expect(definition.label, 'My Agent');
      expect(definition.createdAt, DateTime.utc(2026));
      expect(definition.updatedAt, DateTime.utc(2026));
      expect(definition.isCommandApproved, isTrue);
    });

    test('isCommandApproved is false after the command changes', () {
      final definition = AcpCustomProviderDefinition.create(
        id: 'my-agent',
        label: 'My Agent',
        launchCommand: command,
        now: DateTime.utc(2026),
      );
      final changedCommand = AcpLaunchCommand(
        executable: 'my-agent',
        arguments: const ['--acp', '--extra'],
      );
      // Simulate storage drift by round-tripping with a mismatched command,
      // as would happen if the approval were stale relative to the command.
      final stale = AcpCustomProviderDefinition.tryFromJson({
        ...definition.toJson(),
        'launchCommand': changedCommand.toJson(),
      });
      expect(stale, isNotNull);
      expect(stale!.isCommandApproved, isFalse);
    });

    group('update', () {
      test(
        'does NOT silently approve a changed command '
        '(preserves the prior approval so isCommandApproved becomes false)',
        () {
          final definition = AcpCustomProviderDefinition.create(
            id: 'my-agent',
            label: 'My Agent',
            launchCommand: command,
            now: DateTime.utc(2026),
          );
          final newCommand = AcpLaunchCommand(
            executable: 'my-agent',
            arguments: const ['--acp', '--extra'],
          );
          final updated = definition.update(
            launchCommand: newCommand,
            now: DateTime.utc(2026, 2),
          );
          expect(updated.launchCommand, newCommand);
          expect(updated.isCommandApproved, isFalse);
          expect(updated.approval, definition.approval);
          expect(updated.createdAt, definition.createdAt);
          expect(updated.updatedAt, DateTime.utc(2026, 2));
        },
      );

      test('keeps the existing approval when the command is unchanged', () {
        final definition = AcpCustomProviderDefinition.create(
          id: 'my-agent',
          label: 'My Agent',
          launchCommand: command,
          now: DateTime.utc(2026),
        );
        final updated = definition.update(
          label: 'Renamed Agent',
          now: DateTime.utc(2026, 2),
        );
        expect(updated.label, 'Renamed Agent');
        expect(updated.approval, definition.approval);
        expect(updated.isCommandApproved, isTrue);
        expect(updated.updatedAt, DateTime.utc(2026, 2));
      });

      test(
        'keeps the existing approval when the command is set to the same value',
        () {
          final definition = AcpCustomProviderDefinition.create(
            id: 'my-agent',
            label: 'My Agent',
            launchCommand: command,
            now: DateTime.utc(2026),
          );
          final updated = definition.update(
            launchCommand: AcpLaunchCommand(
              executable: 'my-agent',
              arguments: const ['--acp'],
            ),
            now: DateTime.utc(2026, 2),
          );
          expect(updated.approval, definition.approval);
          expect(updated.isCommandApproved, isTrue);
        },
      );

      test('throws for an invalid new label without mutating the original', () {
        final definition = AcpCustomProviderDefinition.create(
          id: 'my-agent',
          label: 'My Agent',
          launchCommand: command,
        );
        expect(() => definition.update(label: ''), throwsFormatException);
        expect(definition.label, 'My Agent');
      });
    });

    group('approveCurrentCommand', () {
      test('approves the current command, making isCommandApproved true', () {
        final definition = AcpCustomProviderDefinition.create(
          id: 'my-agent',
          label: 'My Agent',
          launchCommand: command,
          now: DateTime.utc(2026),
        );
        final newCommand = AcpLaunchCommand(
          executable: 'my-agent',
          arguments: const ['--acp', '--extra'],
        );
        final changed = definition.update(
          launchCommand: newCommand,
          now: DateTime.utc(2026, 2),
        );
        expect(changed.isCommandApproved, isFalse);

        final approved = changed.approveCurrentCommand(
          now: DateTime.utc(2026, 3),
        );
        expect(approved.isCommandApproved, isTrue);
        expect(
          approved.approval.commandFingerprint,
          computeAcpLaunchCommandFingerprint(newCommand),
        );
        expect(approved.approval.approvedAt, DateTime.utc(2026, 3));
        expect(approved.updatedAt, DateTime.utc(2026, 3));
        expect(approved.launchCommand, newCommand);
      });

      test('is a no-op for isCommandApproved when already approved', () {
        final definition = AcpCustomProviderDefinition.create(
          id: 'my-agent',
          label: 'My Agent',
          launchCommand: command,
          now: DateTime.utc(2026),
        );
        final reApproved = definition.approveCurrentCommand(
          now: DateTime.utc(2026, 2),
        );
        expect(reApproved.isCommandApproved, isTrue);
        expect(
          reApproved.approval.commandFingerprint,
          definition.approval.commandFingerprint,
        );
        expect(reApproved.approval.approvedAt, DateTime.utc(2026, 2));
      });
    });

    test('round-trips through JSON', () {
      final definition = AcpCustomProviderDefinition.create(
        id: 'my-agent',
        label: 'My Agent',
        launchCommand: command,
        now: DateTime.utc(2026),
      );
      final decoded = AcpCustomProviderDefinition.tryFromJson(
        definition.toJson(),
      );
      expect(decoded, definition);
    });

    test('toJson includes a schemaVersion for forward compatibility', () {
      final definition = AcpCustomProviderDefinition.create(
        id: 'my-agent',
        label: 'My Agent',
        launchCommand: command,
      );
      expect(definition.toJson()['schemaVersion'], 1);
    });

    group('tryFromJson defensive parsing', () {
      test('returns null for non-map input', () {
        expect(AcpCustomProviderDefinition.tryFromJson('nope'), isNull);
        expect(AcpCustomProviderDefinition.tryFromJson(42), isNull);
      });

      test('returns null when required fields are missing', () {
        expect(AcpCustomProviderDefinition.tryFromJson({}), isNull);
      });

      test('returns null when the launch command is malformed', () {
        expect(
          AcpCustomProviderDefinition.tryFromJson({
            'id': 'my-agent',
            'label': 'My Agent',
            'launchCommand': {'executable': ''},
            'approval': {
              'commandFingerprint': 'abc',
              'approvedAt': '2026-01-01T00:00:00Z',
            },
            'createdAt': '2026-01-01T00:00:00Z',
            'updatedAt': '2026-01-01T00:00:00Z',
          }),
          isNull,
        );
      });

      test('returns null when the id uses the reserved built-in prefix', () {
        expect(
          AcpCustomProviderDefinition.tryFromJson({
            'id': 'builtin:something',
            'label': 'My Agent',
            'launchCommand': command.toJson(),
            'approval': AcpCommandApproval.approve(command).toJson(),
            'createdAt': '2026-01-01T00:00:00Z',
            'updatedAt': '2026-01-01T00:00:00Z',
          }),
          isNull,
        );
      });

      test('ignores unknown fields for forward compatibility', () {
        final definition = AcpCustomProviderDefinition.create(
          id: 'my-agent',
          label: 'My Agent',
          launchCommand: command,
        );
        final withExtra = {...definition.toJson(), 'futureField': 'value'};
        final decoded = AcpCustomProviderDefinition.tryFromJson(withExtra);
        expect(decoded, definition);
      });

      test('returns null when createdAt or updatedAt is unparseable', () {
        expect(
          AcpCustomProviderDefinition.tryFromJson({
            'id': 'my-agent',
            'label': 'My Agent',
            'launchCommand': command.toJson(),
            'approval': AcpCommandApproval.approve(command).toJson(),
            'createdAt': 'not-a-date',
            'updatedAt': '2026-01-01T00:00:00Z',
          }),
          isNull,
        );
      });

      test('returns null instead of throwing when createdAt/updatedAt are '
          'non-string malformed values (e.g. numbers)', () {
        expect(
          AcpCustomProviderDefinition.tryFromJson({
            'id': 'my-agent',
            'label': 'My Agent',
            'launchCommand': command.toJson(),
            'approval': AcpCommandApproval.approve(command).toJson(),
            'createdAt': 1234567890,
            'updatedAt': '2026-01-01T00:00:00Z',
          }),
          isNull,
        );
        expect(
          AcpCustomProviderDefinition.tryFromJson({
            'id': 'my-agent',
            'label': 'My Agent',
            'launchCommand': command.toJson(),
            'approval': AcpCommandApproval.approve(command).toJson(),
            'createdAt': '2026-01-01T00:00:00Z',
            'updatedAt': 1234567890,
          }),
          isNull,
        );
        expect(
          AcpCustomProviderDefinition.tryFromJson({
            'id': 'my-agent',
            'label': 'My Agent',
            'launchCommand': command.toJson(),
            'approval': AcpCommandApproval.approve(command).toJson(),
            'createdAt': null,
            'updatedAt': '2026-01-01T00:00:00Z',
          }),
          isNull,
        );
        expect(
          AcpCustomProviderDefinition.tryFromJson({
            'id': 'my-agent',
            'label': 'My Agent',
            'launchCommand': command.toJson(),
            'approval': AcpCommandApproval.approve(command).toJson(),
            'createdAt': ['2026-01-01T00:00:00Z'],
            'updatedAt': '2026-01-01T00:00:00Z',
          }),
          isNull,
        );
      });
    });

    test('equality and hashCode are value-based', () {
      final a = AcpCustomProviderDefinition.create(
        id: 'my-agent',
        label: 'My Agent',
        launchCommand: command,
        now: DateTime.utc(2026),
      );
      final b = AcpCustomProviderDefinition.create(
        id: 'my-agent',
        label: 'My Agent',
        launchCommand: command,
        now: DateTime.utc(2026),
      );
      final c = a.update(label: 'Different', now: DateTime.utc(2026, 1, 2));
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse);
    });
  });

  group('AcpProvider views', () {
    test('AcpCustomProviderView exposes the wrapped definition', () {
      final definition = AcpCustomProviderDefinition.create(
        id: 'my-agent',
        label: 'My Agent',
        launchCommand: AcpLaunchCommand(executable: 'my-agent'),
      );
      final view = AcpCustomProviderView(definition);
      expect(view.id, definition.id);
      expect(view.label, definition.label);
      expect(view.launchCommand, definition.launchCommand);
      expect(view.isCustom, isTrue);
    });
  });
}

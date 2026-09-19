import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/services/acp_launch_profile_service.dart';

import 'acp_connection_support_cases.dart';
import 'acp_launch_profile_picker_cases.dart';

void main() {
  group('acp_launch_profile_service', () {
    group('ACP launch profile discovery', () {
      test('parses nested profiles and preserves the active marker', () {
        final profiles = parseAcpLaunchProfiles(
          '__MONKEYSSH_ACP_PROFILE__\u001fdefault\u001f0\n'
          '__MONKEYSSH_ACP_PROFILE__\u001fwork\u001f1\r\n'
          '__MONKEYSSH_ACP_PROFILE__\u001fpersonal\u001f0\n'
          'shell chatter\n'
          '__MONKEYSSH_ACP_PROFILE__\u001f../unsafe\u001f1\n',
          acpHermesProvider.launchProfileSupport!,
        );

        expect(profiles, const [
          AcpLaunchProfile(argument: 'default', label: 'Default'),
          AcpLaunchProfile(argument: 'personal', label: 'personal'),
          AcpLaunchProfile(argument: 'work', label: 'work', isActive: true),
        ]);
      });

      test('adds a missing default and rejects control characters', () {
        final profiles = parseAcpLaunchProfiles(
          '__MONKEYSSH_ACP_PROFILE__\u001fwork\u001f1\n'
          '__MONKEYSSH_ACP_PROFILE__\u001fbad\u0000name\u001f0\n',
          acpHermesProvider.launchProfileSupport!,
        );

        expect(profiles.first.label, 'Default');
        expect(profiles.map((profile) => profile.argument), [
          'default',
          'work',
        ]);
      });

      test('returns only Default when no named profiles are discovered', () {
        expect(
          parseAcpLaunchProfiles('', acpHermesProvider.launchProfileSupport!),
          const [AcpLaunchProfile(argument: 'default', label: 'Default')],
        );
        expect(
          parseAcpLaunchProfiles('', acpOpenClawProvider.launchProfileSupport!),
          const [AcpLaunchProfile(argument: null, label: 'Default')],
        );
      });

      test(
        'parses, validates, deduplicates, and sorts OpenClaw directories',
        () {
          final profiles = parseAcpLaunchProfiles(
            '__MONKEYSSH_ACP_PROFILE__\u001fzeta\u001f0\n'
            'shell chatter\n'
            '__MONKEYSSH_ACP_PROFILE__\u001falpha\u001f0\n'
            '__MONKEYSSH_ACP_PROFILE__\u001fzeta\u001f1\n'
            '__MONKEYSSH_ACP_PROFILE__\u001f../unsafe\u001f0\n',
            acpOpenClawProvider.launchProfileSupport!,
          );

          expect(profiles, const [
            AcpLaunchProfile(argument: null, label: 'Default'),
            AcpLaunchProfile(argument: 'alpha', label: 'alpha'),
            AcpLaunchProfile(argument: 'zeta', label: 'zeta', isActive: true),
          ]);
        },
      );

      test('builds bounded POSIX Hermes and OpenClaw probes', () {
        final hermes = buildAcpLaunchProfileDiscoveryCommand(
          support: acpHermesProvider.launchProfileSupport!,
          isWindows: false,
        );
        expect(hermes, contains("printenv 'HERMES_HOME'"));
        expect(hermes, contains("'.hermes'"));
        expect(hermes, contains("'profiles'"));
        expect(hermes, contains("'active_profile'"));
        expect(hermes, isNot(contains('hermes profile list')));

        final openClaw = buildAcpLaunchProfileDiscoveryCommand(
          support: acpOpenClawProvider.launchProfileSupport!,
          isWindows: false,
        );
        expect(openClaw, contains(r'"$HOME"'));
        expect(openClaw, contains("'.openclaw-'*"));
        expect(openClaw, contains('__MONKEYSSH_ACP_PROFILE__'));
      });

      test(
        'POSIX Hermes probe honors active profile and HERMES_HOME',
        () async {
          if (Platform.isWindows) return;
          final home = await Directory.systemTemp.createTemp(
            'hermes-profiles-',
          );
          addTearDown(() => home.delete(recursive: true));
          final root = Directory('${home.path}/.hermes');
          await Directory('${root.path}/profiles/work').create(recursive: true);
          await Directory('${root.path}/profiles/personal').create();
          await File('${root.path}/active_profile').writeAsString('work\n');
          final command = buildAcpLaunchProfileDiscoveryCommand(
            support: acpHermesProvider.launchProfileSupport!,
            isWindows: false,
          );

          for (final hermesHome in ['', '${root.path}/profiles/work']) {
            final result = await Process.run(
              '/bin/sh',
              ['-c', command],
              environment: {'HOME': home.path, 'HERMES_HOME': hermesHome},
            );
            expect(result.exitCode, 0);
            expect(
              parseAcpLaunchProfiles(
                result.stdout as String,
                acpHermesProvider.launchProfileSupport!,
              ),
              const [
                AcpLaunchProfile(argument: 'default', label: 'Default'),
                AcpLaunchProfile(argument: 'personal', label: 'personal'),
                AcpLaunchProfile(
                  argument: 'work',
                  label: 'work',
                  isActive: true,
                ),
              ],
            );
          }
        },
      );

      test(
        'POSIX OpenClaw probe enumerates real profile directories',
        () async {
          if (Platform.isWindows) return;
          final home = await Directory.systemTemp.createTemp('acp-profiles-');
          addTearDown(() => home.delete(recursive: true));
          await Directory('${home.path}/.openclaw-work').create();
          await Directory('${home.path}/.openclaw-personal').create();
          await File('${home.path}/.openclaw-not-a-directory')
              .writeAsString('');
          final command = buildAcpLaunchProfileDiscoveryCommand(
            support: acpOpenClawProvider.launchProfileSupport!,
            isWindows: false,
          );

          final result = await Process.run(
            '/bin/sh',
            ['-c', command],
            environment: {'HOME': home.path},
          );
          expect(result.exitCode, 0);
          expect(
            parseAcpLaunchProfiles(
              result.stdout as String,
              acpOpenClawProvider.launchProfileSupport!,
            ),
            const [
              AcpLaunchProfile(argument: null, label: 'Default'),
              AcpLaunchProfile(argument: 'personal', label: 'personal'),
              AcpLaunchProfile(argument: 'work', label: 'work'),
            ],
          );
        },
      );

      test('builds encoded PowerShell directory probes', () {
        for (final provider in [acpHermesProvider, acpOpenClawProvider]) {
          final command = buildAcpLaunchProfileDiscoveryCommand(
            support: provider.launchProfileSupport!,
            isWindows: true,
          );
          expect(command, startsWith('powershell -NoProfile'));
          final encoded = command.split(' ').last;
          final bytes = base64.decode(encoded);
          final units = <int>[];
          for (var index = 0; index < bytes.length; index += 2) {
            units.add(bytes[index] | (bytes[index + 1] << 8));
          }
          final script = String.fromCharCodes(units);
          expect(script, contains('Get-ChildItem -LiteralPath'));
          if (provider == acpHermesProvider) {
            expect(script, contains('HERMES_HOME'));
            expect(script, contains('active_profile'));
            expect(script, contains(r'$__flProfiles'));
          } else {
            expect(script, contains('.openclaw-'));
            expect(script, contains(r'Get-ChildItem -LiteralPath $HOME'));
          }
        }
      });
    });

    group('ACP launch profile arguments', () {
      test('inserts global profile selection before the ACP subcommand', () {
        final command = acpHermesProvider.launchProfileSupport!.apply(
          AcpLaunchCommand(
            executable: '/Users/demo/bin/hermes',
            arguments: const ['acp'],
          ),
          'work',
        );
        expect(command.argv, [
          '/Users/demo/bin/hermes',
          '--profile',
          'work',
          'acp',
        ]);
      });

      test('keeps OpenClaw base invocation when Default is selected', () {
        final command = acpOpenClawProvider.launchProfileSupport!.apply(
          AcpLaunchCommand(
            executable: '/Users/demo/bin/openclaw',
            arguments: const ['acp'],
          ),
          null,
        );
        expect(command.argv, ['/Users/demo/bin/openclaw', 'acp']);
      });
    });
  });
  registerAcpConnectionSupportTests();
  registerAcpLaunchProfilePickerTests();
}

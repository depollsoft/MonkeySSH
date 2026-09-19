import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/services/acp_launch_profile_service.dart';
import 'package:monkeyssh/presentation/widgets/acp_connection_support.dart';

void registerAcpLaunchProfilePickerTests() {
  group('acp_launch_profile_picker', () {
    test('native ACP uses the shared profile and YOLO argument plan', () {
      final hermes = applyAcpAgentLaunchSettings(
        provider: acpHermesProvider,
        command: AcpLaunchCommand(
          executable: '/Users/demo/bin/hermes',
          arguments: const ['--profile', 'work', 'acp'],
        ),
        startInYoloMode: true,
      );
      expect(hermes.arguments, ['--profile', 'work', '--yolo', 'acp']);
      expect(
        isApprovedAcpBuiltinLaunchOverride(acpHermesProvider, hermes),
        isTrue,
      );

      final cursor = applyAcpAgentLaunchSettings(
        provider: acpCursorAgentProvider,
        command: AcpLaunchCommand(
          executable: '/Users/demo/bin/cursor-agent',
          arguments: const ['acp'],
        ),
        startInYoloMode: true,
      );
      expect(cursor.arguments, ['--force', 'acp']);
      expect(
        isApprovedAcpBuiltinLaunchOverride(acpCursorAgentProvider, cursor),
        isTrue,
      );

      final copilot = applyAcpAgentLaunchSettings(
        provider: acpCopilotCliProvider,
        command: AcpLaunchCommand(
          executable: '/Users/demo/bin/copilot',
          arguments: acpCopilotCliProvider.launchCommand.arguments,
        ),
        startInYoloMode: true,
      );
      expect(copilot.arguments.first, '--yolo');
      expect(
        isApprovedAcpBuiltinLaunchOverride(acpCopilotCliProvider, copilot),
        isTrue,
      );

      final grok = applyAcpAgentLaunchSettings(
        provider: acpGrokBuildProvider,
        command: AcpLaunchCommand(
          executable: '/Users/demo/bin/grok',
          arguments: acpGrokBuildProvider.launchCommand.arguments,
        ),
        startInYoloMode: true,
      );
      expect(grok.arguments, ['--yolo', 'agent', 'stdio']);
      expect(
        isApprovedAcpBuiltinLaunchOverride(acpGrokBuildProvider, grok),
        isTrue,
      );

      for (final provider in [
        acpClaudeAgentProvider,
        acpCodexProvider,
        acpAntigravityProvider,
        acpPiProvider,
      ]) {
        final adapter = AcpLaunchCommand(
          executable: '/Users/demo/bin/${provider.launchCommand.executable}',
          arguments: provider.launchCommand.arguments,
        );
        expect(
          applyAcpAgentLaunchSettings(
            provider: provider,
            command: adapter,
            startInYoloMode: true,
          ),
          adapter,
        );
      }
    });

    testWidgets('profile picker returns the selected isolated profile', (
      tester,
    ) async {
      final selected = ValueNotifier<String>('none');
      addTearDown(selected.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  FilledButton(
                    onPressed: () async {
                      final profile = await showAcpLaunchProfilePicker(
                        context: context,
                        providerLabel: 'Hermes',
                        profiles: const [
                          AcpLaunchProfile(
                            argument: 'default',
                            label: 'Default',
                          ),
                          AcpLaunchProfile(
                            argument: 'work',
                            label: 'work',
                            isActive: true,
                          ),
                          AcpLaunchProfile(
                            argument: 'personal',
                            label: 'personal',
                          ),
                        ],
                      );
                      selected.value = profile?.argument ?? 'none';
                    },
                    child: const Text('Launch'),
                  ),
                  ValueListenableBuilder(
                    valueListenable: selected,
                    builder: (context, value, child) => Text(value),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Launch'));
      await tester.pumpAndSettle();

      expect(find.text('Choose Hermes profile'), findsOneWidget);
      expect(
        find.text('Select the isolated profile for this native session.'),
        findsOneWidget,
      );
      expect(find.text('Default'), findsOneWidget);
      expect(find.text('work'), findsOneWidget);
      expect(find.text('Current'), findsOneWidget);

      await tester.tap(find.text('personal'));
      await tester.pumpAndSettle();

      expect(find.text('Choose Hermes profile'), findsNothing);
      expect(find.text('personal'), findsOneWidget);
    });

    testWidgets('profile picker scrolls long names on a compact phone', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final profiles = List.generate(
        30,
        (index) => AcpLaunchProfile(
          argument: 'profile-$index',
          label: index == 29
              ? 'profile-29-with-a-very-long-machine-readable-identifier'
              : 'profile-$index',
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () => showAcpLaunchProfilePicker(
                  context: context,
                  providerLabel: 'OpenClaw',
                  profiles: profiles,
                ),
                child: const Text('Launch'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Launch'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('profile-29-with-a-very-long-machine-readable-identifier'),
        250,
        scrollable: find.byType(Scrollable).last,
      );

      expect(tester.takeException(), isNull);
      expect(
        find.text('profile-29-with-a-very-long-machine-readable-identifier'),
        findsOneWidget,
      );
    });
  });
}

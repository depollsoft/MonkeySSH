import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/presentation/controllers/system_keyboard_visibility_controller.dart';
import 'package:monkeyssh/presentation/widgets/agent_tool_icon.dart';
import 'package:monkeyssh/presentation/widgets/system_bottom_inset.dart';
import 'package:monkeyssh/presentation/widgets/tmux_window_navigator.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('AgentToolIcon', () {
    test('window identity color depends only on selection', () {
      const scheme = ColorScheme.light(
        primary: Color(0xFF123456),
        onSurfaceVariant: Color(0xFF654321),
      );

      expect(agentWindowIdentityColor(scheme, isActive: true), scheme.primary);
      expect(
        agentWindowIdentityColor(scheme, isActive: false),
        scheme.onSurfaceVariant,
      );
    });

    testWidgets('renders a branded svg for a known tool name', (tester) async {
      await tester.pumpWidget(_wrap(const AgentToolIcon(toolName: 'Codex')));

      expect(find.byType(SvgPicture), findsOneWidget);
      expect(find.byIcon(Icons.smart_toy_outlined), findsNothing);
    });

    testWidgets('renders a branded svg for a known tool enum', (tester) async {
      await tester.pumpWidget(
        _wrap(const AgentToolIcon(tool: AgentLaunchTool.copilotCli)),
      );

      expect(find.byType(SvgPicture), findsOneWidget);
      expect(find.byIcon(Icons.smart_toy_outlined), findsNothing);
    });

    testWidgets('renders a branded svg for every supported tool', (
      tester,
    ) async {
      for (final tool in AgentLaunchTool.values) {
        await tester.pumpWidget(_wrap(AgentToolIcon(tool: tool)));
        await tester.pump();

        expect(
          find.byType(SvgPicture),
          findsOneWidget,
          reason: '${tool.name} should render a branded svg',
        );
        expect(
          find.byIcon(Icons.smart_toy_outlined),
          findsNothing,
          reason: '${tool.name} should not fall back to a Material icon',
        );
      }
    });

    testWidgets('falls back to a Material icon for unknown tools', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const AgentToolIcon(
            toolName: 'Unknown CLI',
            fallbackIcon: Icons.terminal,
          ),
        ),
      );

      expect(find.byType(SvgPicture), findsNothing);
      expect(find.byIcon(Icons.terminal), findsOneWidget);
    });
  });

  group('TmuxToolPickerSheet', () {
    test('uses native visibility before inset geometry', () {
      expect(
        resolvePlatformKeyboardInset(
          bottomInset: 300,
          platformKeyboardVisible: null,
        ),
        300,
      );
      expect(
        resolvePlatformKeyboardInset(
          bottomInset: 300,
          platformKeyboardVisible: true,
        ),
        300,
      );
      expect(
        resolvePlatformKeyboardInset(
          bottomInset: 300,
          platformKeyboardVisible: false,
        ),
        0,
      );
      expect(
        resolvePlatformKeyboardInset(
          bottomInset: 0,
          platformKeyboardVisible: true,
        ),
        0,
      );
    });

    testWidgets(
      'new-window route tracks native visibility with stale geometry',
      (tester) async {
        tester.view
          ..physicalSize = const Size(390, 844)
          ..devicePixelRatio = 1
          ..viewInsets = const FakeViewPadding(bottom: 300);
        final keyboard = SystemKeyboardVisibilityController.instance
          ..debugSetVisible(visible: false);
        addTearDown(() {
          keyboard.debugSetVisible(visible: null);
          tester.view
            ..resetPhysicalSize()
            ..resetDevicePixelRatio()
            ..resetViewInsets();
        });

        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                resizeToAvoidBottomInset: false,
                body: TextButton(
                  onPressed: () => unawaited(
                    showTmuxNewWindowPicker(
                      context: context,
                      isProUser: true,
                      startClisInYoloMode: false,
                    ),
                  ),
                  child: const Text('Open picker'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open picker'));
        await tester.pumpAndSettle();

        final pickerPadding = find.descendant(
          of: find.byType(TmuxToolPickerSheet),
          matching: find.byType(AnimatedPadding),
        );

        expect(
          tester.widget<AnimatedPadding>(pickerPadding).padding,
          EdgeInsets.zero,
        );

        keyboard.debugSetVisible(visible: true);
        await tester.pumpAndSettle();

        expect(keyboard.visible, isTrue);
        expect(
          MediaQuery.of(
            tester.element(find.byType(TmuxToolPickerSheet)),
          ).viewInsets.bottom,
          300,
        );
        expect(
          tester.widget<AnimatedPadding>(pickerPadding).padding,
          const EdgeInsets.only(bottom: 300),
        );
      },
    );
    testWidgets('shows loading indicator while detection is pending', (
      tester,
    ) async {
      final completer = Completer<Set<AgentLaunchTool>>();
      await tester.pumpWidget(
        _wrap(
          TmuxToolPickerSheet(
            installedToolsFuture: completer.future,
            onToolSelected: (_) {},
            onEmptyWindow: () {},
          ),
        ),
      );

      expect(find.text('Detecting installed CLIs…'), findsOneWidget);
      // No CLI tiles before detection completes.
      expect(find.text('Claude Code'), findsNothing);
      expect(find.text('Codex'), findsNothing);
      // Empty terminal remains available even while loading.
      expect(find.text('Empty terminal'), findsOneWidget);

      completer.complete({AgentLaunchTool.claudeCode});
      await tester.pump();
      expect(find.text('Detecting installed CLIs…'), findsNothing);
    });

    testWidgets('omits Gemini while keeping Antigravity selectable', (
      tester,
    ) async {
      AgentLaunchTool? selected;
      await tester.pumpWidget(
        _wrap(
          TmuxToolPickerSheet(
            installedToolsFuture: Future.value(AgentLaunchTool.values.toSet()),
            onToolSelected: (tool) => selected = tool,
            onEmptyWindow: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Gemini CLI'), findsNothing);
      await tester.ensureVisible(find.text('Antigravity'));
      await tester.tap(find.text('Antigravity'));
      expect(selected, AgentLaunchTool.antigravity);
    });

    testWidgets('renders only detected tools', (tester) async {
      await tester.pumpWidget(
        _wrap(
          TmuxToolPickerSheet(
            installedToolsFuture: Future.value({
              AgentLaunchTool.claudeCode,
              AgentLaunchTool.codex,
            }),
            onToolSelected: (_) {},
            onEmptyWindow: () {},
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Claude Code'), findsOneWidget);
      expect(find.text('Codex'), findsOneWidget);
      // Tools that aren't installed must not appear.
      expect(find.text('Copilot CLI'), findsNothing);
      expect(find.text('Gemini CLI'), findsNothing);
      expect(find.text('OpenCode'), findsNothing);
      expect(find.text('Empty terminal'), findsOneWidget);
    });

    testWidgets('shows fallback message when no CLIs are detected', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          TmuxToolPickerSheet(
            installedToolsFuture: Future.value(const <AgentLaunchTool>{}),
            onToolSelected: (_) {},
            onEmptyWindow: () {},
          ),
        ),
      );
      await tester.pump();

      expect(find.text('No supported CLIs found on PATH.'), findsOneWidget);
      expect(find.text('Empty terminal'), findsOneWidget);
      for (final tool in AgentLaunchTool.values) {
        expect(find.text(tool.label), findsNothing);
      }
    });

    testWidgets(
      'falls back to all tools when no detection future is provided',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            TmuxToolPickerSheet(onToolSelected: (_) {}, onEmptyWindow: () {}),
          ),
        );
        await tester.pump();

        for (final tool in AgentLaunchTool.values) {
          expect(find.text(tool.label), findsOneWidget);
        }
      },
    );

    testWidgets('shows fallback message when detection fails', (tester) async {
      final completer = Completer<Set<AgentLaunchTool>>();
      await tester.pumpWidget(
        _wrap(
          TmuxToolPickerSheet(
            installedToolsFuture: completer.future,
            onToolSelected: (_) {},
            onEmptyWindow: () {},
          ),
        ),
      );
      completer.completeError(StateError('detection failed'));
      await tester.pump();

      expect(find.text('No supported CLIs found on PATH.'), findsOneWidget);
      expect(find.text('Empty terminal'), findsOneWidget);
      for (final tool in AgentLaunchTool.values) {
        expect(find.text(tool.label), findsNothing);
      }
    });

    testWidgets('invokes callback when a detected tool is tapped', (
      tester,
    ) async {
      AgentLaunchTool? chosen;
      await tester.pumpWidget(
        _wrap(
          TmuxToolPickerSheet(
            installedToolsFuture: Future.value({AgentLaunchTool.claudeCode}),
            onToolSelected: (t) => chosen = t,
            onEmptyWindow: () {},
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Claude Code'));
      expect(chosen, AgentLaunchTool.claudeCode);
    });

    testWidgets('moves the preferred tool to the top of the list', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          TmuxToolPickerSheet(
            installedToolsFuture: Future.value({
              AgentLaunchTool.claudeCode,
              AgentLaunchTool.codex,
            }),
            preferredTool: AgentLaunchTool.codex,
            onToolSelected: (_) {},
            onEmptyWindow: () {},
          ),
        ),
      );
      await tester.pump();

      expect(
        tester.getTopLeft(find.text('Codex')).dy,
        lessThan(tester.getTopLeft(find.text('Claude Code')).dy),
      );
    });
  });
}

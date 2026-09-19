// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/presentation/widgets/acp_native_starting_view.dart';
import 'package:monkeyssh/presentation/widgets/agent_tool_icon.dart';
import 'package:monkeyssh/presentation/widgets/cursor_block.dart';

void registerAcpNativeStartingViewTests() {
  group('acp_native_starting_view', () {
    testWidgets('shows branded live startup state and phase', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AcpNativeStartingView(
              providerLabel: 'Cursor Agent',
              detail: 'checking native adapter…',
              resuming: false,
              tool: AgentLaunchTool.cursorAgent,
            ),
          ),
        ),
      );

      expect(find.text('starting Cursor Agent'), findsOneWidget);
      expect(find.text('checking native adapter…'), findsOneWidget);
      expect(find.byType(CursorBlock), findsOneWidget);
      expect(
        tester.widget<AgentToolIcon>(find.byType(AgentToolIcon)).tool,
        AgentLaunchTool.cursorAgent,
      );
      expect(
        tester
            .getSemantics(
              find.byKey(const ValueKey<String>('native-agent-starting')),
            )
            .label,
        startsWith('starting Cursor Agent. checking native adapter…'),
      );
    });

    testWidgets('updates to resume phase without overflowing a narrow phone', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(240, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AcpNativeStartingView(
              providerLabel: 'Claude Agent',
              detail: 'opening persistent agent session…',
              resuming: true,
              tool: AgentLaunchTool.claudeCode,
            ),
          ),
        ),
      );

      expect(find.text('resuming Claude Agent'), findsOneWidget);
      expect(find.text('opening persistent agent session…'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

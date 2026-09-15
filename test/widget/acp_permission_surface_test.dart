// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart' as session;
import 'package:monkeyssh/domain/models/acp_updates.dart';
import 'package:monkeyssh/presentation/widgets/acp_permission_surface.dart';

Future<void> _pump(
  WidgetTester tester,
  List<AcpPermissionPrompt> prompts,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: AcpPermissionSurface(prompts: prompts)),
    ),
  );
}

void main() {
  testWidgets('renders exact option ids and resolves once', (tester) async {
    final selected = <String>[];
    final gate = Completer<void>();
    final prompt = AcpToolPermissionPrompt(
      stableKey: 'k1',
      title: 'Allow this action?',
      options: const [
        AcpPermissionOption(
          id: 'opt-allow',
          name: 'Allow',
          kind: AcpPermissionOptionKind.allowOnce,
        ),
        AcpPermissionOption(
          id: 'opt-always',
          name: 'Always allow',
          kind: AcpPermissionOptionKind.allowAlways,
        ),
        AcpPermissionOption(
          id: 'opt-reject',
          name: 'Reject',
          kind: AcpPermissionOptionKind.rejectOnce,
        ),
      ],
      onSelect: (id) async {
        selected.add(id);
        await gate.future;
      },
      onCancel: () async {},
    );
    await _pump(tester, [prompt]);

    expect(find.text('Allow'), findsOneWidget);
    expect(find.text('Always allow'), findsOneWidget);
    expect(find.text('Reject'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('Allow'),
        matching: find.byType(FilledButton),
      ),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: find.text('Always allow'),
        matching: find.byType(OutlinedButton),
      ),
      findsOneWidget,
    );
    expect(
      find.ancestor(of: find.text('Reject'), matching: find.byType(TextButton)),
      findsOneWidget,
    );

    await tester.tap(find.text('Allow'));
    await tester.pump();
    // Buttons are disabled while resolving, preventing duplicate resolution.
    await tester.tap(find.text('Allow'), warnIfMissed: false);
    await tester.pump();
    expect(selected, ['opt-allow']);

    gate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('write prompt shows metadata but hides content by default', (
    tester,
  ) async {
    var approved = false;
    final prompt = AcpWritePermissionPrompt(
      stableKey: 'w1',
      fileName: 'main.dart',
      contentBytes: 42,
      onApprove: () async => approved = true,
      onReject: () async {},
      revealContent: () => 'secret body',
    );
    await _pump(tester, [prompt]);

    expect(find.text('Write to main.dart'), findsOneWidget);
    expect(find.text('42 bytes'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('Approve write'),
        matching: find.byType(FilledButton),
      ),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: find.text('Reject write'),
        matching: find.byType(TextButton),
      ),
      findsOneWidget,
    );
    // Content is not displayed until explicitly revealed.
    expect(find.text('secret body'), findsNothing);

    await tester.tap(find.text('Review changes'));
    await tester.pump();
    expect(find.text('secret body'), findsOneWidget);

    await tester.tap(find.text('Approve write'));
    await tester.pump();
    expect(approved, isTrue);
  });

  testWidgets('renders Pi extension UI as a direct choice', (tester) async {
    final selected = <String>[];
    final pending = session.AcpPendingPermission(
      requestKey: 'req-wt',
      sessionId: 'sess',
      toolCallId: 'pi-ui-worktrees',
      toolTitle: 'Managed worktrees',
      options: const [
        AcpPermissionOption(
          id: 'choice-0',
          name: 'wt/feature /worktrees/feature',
          kind: AcpPermissionOptionKind.allowOnce,
        ),
      ],
      requestedAt: DateTime(2026),
    );
    final prompt = acpToolPromptFromSession(
      pending,
      onSelect: (id) async => selected.add(id),
      onCancel: () async {},
    );

    await _pump(tester, [prompt]);

    expect(find.text('Managed worktrees'), findsOneWidget);
    expect(find.text('Allow Managed worktrees?'), findsNothing);
    expect(find.byIcon(Icons.tune), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Cancel request'), findsNothing);
    await tester.tap(find.text('wt/feature /worktrees/feature'));
    await tester.pump();
    expect(selected, ['choice-0']);
  });

  testWidgets('maps a session-manager pending permission to a tool prompt', (
    tester,
  ) async {
    final selected = <String>[];
    final pending = session.AcpPendingPermission(
      requestKey: 'req-1',
      sessionId: 'sess',
      toolCallId: 'tool-1',
      options: const [
        AcpPermissionOption(
          id: 'allow-once',
          name: 'Allow once',
          kind: AcpPermissionOptionKind.allowOnce,
        ),
      ],
      requestedAt: DateTime(2026),
    );
    final prompt = acpToolPromptFromSession(
      pending,
      toolTitle: 'Write settings',
      onSelect: (id) async => selected.add(id),
      onCancel: () async {},
    );
    expect(prompt.stableKey, 'session:sess:req-1');
    await _pump(tester, [prompt]);

    expect(find.text('Allow Write settings?'), findsOneWidget);
    expect(find.text('Write settings'), findsOneWidget);
    expect(find.text('Allow once'), findsOneWidget);
    await tester.tap(find.text('Allow once'));
    await tester.pump();
    expect(selected, ['allow-once']);
  });
}

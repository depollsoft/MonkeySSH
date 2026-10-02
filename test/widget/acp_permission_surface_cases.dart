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

void registerAcpPermissionSurfaceTests() {
  group('acp_permission_surface', () {
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
        find.ancestor(
          of: find.text('Reject'),
          matching: find.byType(TextButton),
        ),
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
      // The title is not repeated as the context line.
      expect(find.text('Write settings'), findsNothing);
      expect(find.text('Allow once'), findsOneWidget);
      await tester.tap(find.text('Allow once'));
      await tester.pump();
      expect(selected, ['allow-once']);
    });

    testWidgets('prefers the title and subject carried by the request', (
      tester,
    ) async {
      final pending = session.AcpPendingPermission(
        requestKey: 'req-2',
        sessionId: 'sess',
        toolCallId: 'tool-2',
        options: const [
          AcpPermissionOption(
            id: 'allow-once',
            name: 'Allow once',
            kind: AcpPermissionOptionKind.allowOnce,
          ),
        ],
        requestedAt: DateTime(2026),
        title: 'Run shell command',
        toolKind: AcpToolKind.execute,
        subject: 'rm -rf build',
      );
      final prompt = acpToolPromptFromSession(
        pending,
        toolTitle: 'Stale timeline title',
        onSelect: (_) async {},
        onCancel: () async {},
      );
      await _pump(tester, [prompt]);

      expect(find.text('Allow Run shell command?'), findsOneWidget);
      expect(find.text('rm -rf build'), findsOneWidget);
      expect(find.textContaining('Stale timeline title'), findsNothing);
      expect(find.textContaining('tool-2'), findsNothing);
    });

    test('agent titles are put on one bounded line', () {
      expect(
        acpPermissionTitleText('  Run\n\n  the   tests  '),
        'Run the tests',
      );
      expect(acpPermissionTitleText(' \n '), isNull);
      expect(acpPermissionTitleText(null), isNull);
      final long = acpPermissionTitleText('x' * 5000)!;
      expect(long.runes.length, kAcpPermissionTitleMaxCharacters);
      expect(long, endsWith('…'));
      // Emoji are counted and cut by code point, never split.
      final emoji = acpPermissionTitleText('😀' * 200)!;
      expect(emoji.runes.length, kAcpPermissionTitleMaxCharacters);
      expect(
        emoji.runes.every((rune) => rune == 0x1F600 || rune == 0x2026),
        isTrue,
      );
    });
  });
}

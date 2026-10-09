// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/connection_attention.dart';
import 'package:monkeyssh/presentation/providers/connection_attention_provider.dart';
import 'package:monkeyssh/presentation/widgets/connections_waiting_section.dart';

WaitingOnYouItem _item({
  AttentionReason reason = AttentionReason.permission,
  String bridgeId = 'bridge-1',
  String title = 'Fix the flaky test',
  bool tracked = true,
}) => WaitingOnYouItem(
  reason: reason,
  key: AcpSessionKey.of(
    hostId: 2,
    providerId: 'builtin:claude-code',
    bridgeId: bridgeId,
    acpSessionId: 'session-$bridgeId',
  ),
  hostLabel: 'Beta',
  title: title,
  providerLabel: 'Claude Code',
  cwdSummary: '…/api',
  since: DateTime(2026, 1, 1, 11, 55),
  tracked: tracked,
);

Widget _harness({
  required List<WaitingOnYouItem> items,
  required List<String> opened,
  ThemeData? theme,
}) => ProviderScope(
  overrides: [
    waitingOnYouProvider.overrideWithValue(WaitingOnYouSnapshot(items)),
  ],
  child: MaterialApp(
    theme: theme ?? FluttyTheme.dark,
    home: Scaffold(
      body: ListView(
        children: [
          ConnectionsWaitingSection(
            now: () => DateTime(2026, 1, 1, 12),
            onOpen: (context, location) => opened.add(location),
          ),
        ],
      ),
    ),
  ),
);

void main() {
  testWidgets('renders nothing when no session is waiting', (tester) async {
    await tester.pumpWidget(_harness(items: const [], opened: []));
    expect(find.text('waiting on you'), findsNothing);
    expect(
      find.byKey(const ValueKey('connections-waiting-section')),
      findsNothing,
    );
  });

  testWidgets('lists waiting sessions with a labelled reason and Open', (
    tester,
  ) async {
    final opened = <String>[];
    final permission = _item();
    final signIn = _item(
      reason: AttentionReason.signIn,
      bridgeId: 'bridge-2',
      title: 'Claude Code',
    );
    await tester.pumpWidget(
      _harness(items: [permission, signIn], opened: opened),
    );

    expect(find.text('waiting on you'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('Fix the flaky test'), findsOneWidget);
    // Reasons carry an icon and a word, never color alone.
    expect(find.text('permission'), findsOneWidget);
    expect(find.byIcon(Icons.gpp_maybe_outlined), findsOneWidget);
    expect(find.text('sign-in'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    expect(find.text('Beta · 5m ago · Claude Code · …/api'), findsOneWidget);
    // The provider is not repeated when it is already the title.
    expect(find.text('Beta · 5m ago · …/api'), findsOneWidget);
    expect(find.text('Open'), findsNWidgets(2));

    await tester.tap(find.text('Fix the flaky test'));
    expect(opened, [permission.chatLocation]);
    await tester.tap(find.text('Open').last);
    expect(opened, [permission.chatLocation, signIn.chatLocation]);
  });

  testWidgets('each row is one accessible Open button at least 44pt tall', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_harness(items: [_item()], opened: []));

    final row = find.byKey(ValueKey('waiting-on-you-${_item().key.value}'));
    expect(tester.getSize(row).height, greaterThanOrEqualTo(44));
    expect(
      tester.getSemantics(row),
      matchesSemantics(
        label:
            'Open Fix the flaky test. Claude Code on Beta needs permission, '
            '5m ago.',
        isButton: true,
        hasTapAction: true,
      ),
    );
    semantics.dispose();
  });

  testWidgets('meets text contrast guidelines in light and dark themes', (
    tester,
  ) async {
    for (final theme in [FluttyTheme.light, FluttyTheme.dark]) {
      await tester.pumpWidget(
        _harness(
          items: [
            _item(),
            _item(reason: AttentionReason.hostRequest, bridgeId: 'b2'),
          ],
          opened: [],
          theme: theme,
        ),
      );
      await expectLater(tester, meetsGuideline(textContrastGuideline));
    }
  });
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/agent_session_discovery_service.dart';
import 'package:monkeyssh/presentation/widgets/ai_session_picker.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  test('Pi subtitle identifies the session directory or named subtree', () {
    const session = ToolSessionInfo(
      toolName: 'Pi',
      sessionId: 'pi-session',
      summary: 'Fix discovery',
      workingDirectory: '/Users/demo/.local/share/pi-worktrees/named-subtree',
    );

    expect(aiSessionSubtitle(session), '…/named-subtree');
    expect(
      aiSessionSubtitle(
        const ToolSessionInfo(toolName: 'Codex', sessionId: 'codex'),
      ),
      'Codex',
    );
  });

  group('AiSessionProviderEntry', () {
    test('keeps provider availability visible while refreshing', () {
      const entry = AiSessionProviderEntry(
        toolName: 'Codex',
        hasSessions: true,
        wasAttempted: true,
        hasFailure: false,
        isLoading: true,
      );

      expect(entry.statusLabel, 'Recent sessions available');
      expect(entry.compactStatusLabel, 'ready');
    });
  });

  group('AiSessionProviderList', () {
    testWidgets('live updates provider rows in place', (tester) async {
      final controller = StreamController<DiscoveredSessionsResult>();
      var loadCount = 0;
      addTearDown(() async {
        if (!controller.isClosed) {
          await controller.close();
        }
      });

      await tester.pumpWidget(
        _wrap(
          AiSessionProviderList(
            orderedTools: const ['Claude Code', 'Codex'],
            loadSessions: (_) {
              loadCount += 1;
              return controller.stream;
            },
            itemBuilder: (context, provider) => Text(
              '${provider.toolName}|${provider.compactStatusLabel}|'
              '${provider.isLoading ? 'loading' : 'idle'}|'
              '${provider.hasFailure ? 'error' : 'ok'}',
            ),
          ),
        ),
      );

      expect(find.text('Claude Code|loading|loading|ok'), findsOneWidget);
      expect(find.text('Codex|loading|loading|ok'), findsOneWidget);
      expect(loadCount, 1);

      controller.add(
        DiscoveredSessionsResult(
          sessions: const <ToolSessionInfo>[
            ToolSessionInfo(
              toolName: 'Codex',
              sessionId: 'session-1',
              summary: 'Fix the tmux menu refresh',
            ),
          ],
          attemptedTools: const <String>{'Codex'},
        ),
      );
      await tester.pump();

      expect(find.text('Codex|ready|idle|ok'), findsOneWidget);
      expect(find.text('Claude Code|loading|loading|ok'), findsOneWidget);

      controller.add(
        DiscoveredSessionsResult(
          sessions: const <ToolSessionInfo>[],
          attemptedTools: const <String>{'Claude Code'},
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('Claude Code|no recent|idle|ok'), findsOneWidget);
    });

    testWidgets('keeps the visible provider order stable', (tester) async {
      final controller = StreamController<DiscoveredSessionsResult>();
      addTearDown(() async {
        if (!controller.isClosed) {
          await controller.close();
        }
      });

      var orderedTools = const ['Claude Code', 'Codex'];

      await tester.pumpWidget(
        _wrap(
          StatefulBuilder(
            builder: (context, setState) => Column(
              children: [
                TextButton(
                  onPressed: () {
                    setState(() {
                      orderedTools = const ['Codex', 'Claude Code'];
                    });
                  },
                  child: const Text('Reorder'),
                ),
                AiSessionProviderList(
                  orderedTools: orderedTools,
                  loadSessions: (_) => controller.stream,
                  itemBuilder: (context, provider) => Text(
                    provider.toolName,
                    key: ValueKey<String>(provider.toolName),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      final claudeBefore = tester.getTopLeft(
        find.byKey(const ValueKey<String>('Claude Code')),
      );
      final codexBefore = tester.getTopLeft(
        find.byKey(const ValueKey<String>('Codex')),
      );
      expect(claudeBefore.dy, lessThan(codexBefore.dy));

      await tester.tap(find.text('Reorder'));
      await tester.pump();

      final claudeAfter = tester.getTopLeft(
        find.byKey(const ValueKey<String>('Claude Code')),
      );
      final codexAfter = tester.getTopLeft(
        find.byKey(const ValueKey<String>('Codex')),
      );
      expect(claudeAfter.dy, lessThan(codexAfter.dy));
    });

    testWidgets('only rebuilds the provider row that changed', (tester) async {
      final controller = StreamController<DiscoveredSessionsResult>();
      final buildCounts = <String, int>{};
      addTearDown(() async {
        if (!controller.isClosed) {
          await controller.close();
        }
      });

      await tester.pumpWidget(
        _wrap(
          AiSessionProviderList(
            orderedTools: const ['Claude Code', 'Codex'],
            loadSessions: (_) => controller.stream,
            itemBuilder: (context, provider) {
              buildCounts.update(
                provider.toolName,
                (count) => count + 1,
                ifAbsent: () => 1,
              );
              return Text(
                '${provider.toolName}|${provider.compactStatusLabel}',
                key: ValueKey<String>(provider.toolName),
              );
            },
          ),
        ),
      );

      expect(buildCounts, {'Claude Code': 1, 'Codex': 1});

      controller.add(
        DiscoveredSessionsResult(
          sessions: const <ToolSessionInfo>[
            ToolSessionInfo(
              toolName: 'Codex',
              sessionId: 'session-1',
              summary: 'Only Codex should rebuild',
            ),
          ],
          attemptedTools: const <String>{'Codex'},
        ),
      );
      await tester.pump();

      expect(buildCounts, {'Claude Code': 1, 'Codex': 2});

      controller.add(
        DiscoveredSessionsResult(
          sessions: const <ToolSessionInfo>[
            ToolSessionInfo(
              toolName: 'Codex',
              sessionId: 'session-1',
              summary: 'Only Codex should rebuild',
            ),
            ToolSessionInfo(
              toolName: 'Codex',
              sessionId: 'session-2',
              summary: 'Extra streamed session should not churn the row',
            ),
          ],
          attemptedTools: const <String>{'Codex'},
        ),
      );
      await tester.pump();

      expect(buildCounts, {'Claude Code': 1, 'Codex': 2});
    });
  });

  group('AiSessionPickerDialog', () {
    testWidgets('loads more sessions while scrolling', (tester) async {
      final requests = <int>[];
      final allSessions = List.generate(
        24,
        (index) => ToolSessionInfo(
          toolName: 'Codex',
          sessionId: 'session-$index',
          summary: 'Session $index',
        ),
      );

      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) => TextButton(
              onPressed: () {
                unawaited(
                  showAiSessionPickerDialog(
                    context: context,
                    toolName: 'Codex',
                    loadSessions: (maxSessions) {
                      requests.add(maxSessions);
                      return Stream<DiscoveredSessionsResult>.value(
                        DiscoveredSessionsResult(
                          sessions: allSessions.take(maxSessions).toList(),
                          attemptedTools: const <String>{'Codex'},
                        ),
                      );
                    },
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(requests, [12]);

      await tester.drag(find.byType(ListView), const Offset(0, -1200));
      await tester.pumpAndSettle();

      expect(requests, [12, 24]);
    });

    testWidgets('returns the tapped session', (tester) async {
      const selectedSession = ToolSessionInfo(
        toolName: 'Codex',
        sessionId: 'session-1',
        summary: 'Fix the tmux menu refresh',
      );
      ToolSessionInfo? picked;

      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                picked = await showAiSessionPickerDialog(
                  context: context,
                  toolName: 'Codex',
                  loadSessions: (_) => Stream<DiscoveredSessionsResult>.value(
                    DiscoveredSessionsResult(
                      sessions: const <ToolSessionInfo>[selectedSession],
                      attemptedTools: const <String>{'Codex'},
                    ),
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Fix the tmux menu refresh'), findsOneWidget);

      await tester.tap(find.text('Fix the tmux menu refresh'));
      await tester.pumpAndSettle();

      expect(picked, selectedSession);
    });

    testWidgets('reports a held session as a mode override', (tester) async {
      const selectedSession = ToolSessionInfo(
        toolName: 'Codex',
        sessionId: 'session-held',
        summary: 'Choose a native window',
      );
      ToolSessionInfo? tapped;
      ToolSessionInfo? held;

      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                tapped = await showAiSessionPickerDialog(
                  context: context,
                  toolName: 'Codex',
                  loadSessions: (_) => Stream<DiscoveredSessionsResult>.value(
                    DiscoveredSessionsResult(
                      sessions: const <ToolSessionInfo>[selectedSession],
                      attemptedTools: const <String>{'Codex'},
                    ),
                  ),
                  onSessionLongPress: (session) => held = session,
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Choose a native window'));
      await tester.pumpAndSettle();

      expect(held, selectedSession);
      expect(tapped, isNull);
      expect(find.byType(AlertDialog), findsNothing);
    });
  });
}

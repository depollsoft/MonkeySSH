// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_content.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/acp_timeline.dart' as d;
import 'package:monkeyssh/domain/models/acp_updates.dart' as d;
import 'package:monkeyssh/presentation/controllers/acp_unread_tracker.dart';
import 'package:monkeyssh/presentation/models/acp_timeline.dart';
import 'package:monkeyssh/presentation/models/acp_timeline_mapper.dart';
import 'package:monkeyssh/presentation/models/acp_unread.dart';

import '../../support/fake_acp_session_manager.dart';

d.AcpMessageEntry _user(int order, String text) => d.AcpMessageEntry(
  role: d.AcpMessageRole.user,
  order: order,
  content: [AcpTextContent(text)],
);

d.AcpMessageEntry _agent(int order, String text, {String? parent}) =>
    d.AcpMessageEntry(
      role: d.AcpMessageRole.agent,
      order: order,
      parentToolCallId: parent,
      content: [AcpTextContent(text)],
    );

d.AcpToolCallEntry _tool(
  int order,
  String id, {
  d.AcpToolKind kind = d.AcpToolKind.read,
  d.AcpToolStatus status = d.AcpToolStatus.completed,
  List<String> diffPaths = const [],
  String? parent,
  bool subagent = false,
}) => d.AcpToolCallEntry(
  toolCallId: id,
  order: order,
  title: 'Tool $id',
  toolKind: kind,
  status: status,
  parentToolCallId: parent,
  isSubagent: subagent,
  content: [
    for (final path in diffPaths) d.AcpToolDiff(path: path, newText: 'new'),
  ],
);

d.AcpTimeline _timeline(
  List<d.AcpTimelineEntry> entries, {
  Object? source,
  bool overflowed = false,
}) => d.AcpTimeline(entries: entries, source: source, overflowed: overflowed);

AcpUnreadState? _unread(
  AcpLastSeenMarker? marker,
  d.AcpTimeline timeline, {
  int pending = 0,
  bool error = false,
}) => computeAcpUnreadState(
  marker: marker,
  timeline: timeline,
  entries: mapAcpSessionTimeline(fakeAcpSession(timeline: timeline)),
  pendingRequests: pending,
  hasSessionError: error,
);

void registerAcpUnreadTests() {
  group('computeAcpUnreadState', () {
    final source = Object();
    final seen = [_user(0, 'Fix the build'), _agent(1, 'Looking.')];

    test('without a marker there is no divider', () {
      expect(_unread(null, _timeline(seen, source: source)), isNull);
    });

    test('nothing new since the marker means no divider', () {
      final timeline = _timeline(seen, source: source);
      expect(_unread(AcpLastSeenMarker.of(timeline), timeline), isNull);
    });

    test('marks the first new entry and digests what arrived', () {
      final marker = AcpLastSeenMarker.of(_timeline(seen, source: source));
      final timeline = _timeline([
        ...seen,
        _tool(2, 'a', kind: d.AcpToolKind.edit, diffPaths: ['lib/a.dart']),
        _tool(
          3,
          'b',
          kind: d.AcpToolKind.edit,
          diffPaths: ['lib/a.dart', 'lib/b.dart'],
        ),
        _tool(
          4,
          'c',
          kind: d.AcpToolKind.execute,
          status: d.AcpToolStatus.failed,
        ),
        _agent(5, 'Done, but tests fail.'),
      ], source: source);
      final state = _unread(marker, timeline, pending: 1, error: true)!;
      expect(state.dividerEntryIndex, 2);
      expect(state.earlierHistoryUnavailable, isFalse);
      final digest = state.digest!;
      expect(digest.replies, 1);
      expect(digest.toolCalls, {AcpToolKind.edit: 2, AcpToolKind.execute: 1});
      expect(digest.reportedFileChanges, 2);
      expect(digest.pendingRequests, 1);
      expect(digest.errors, 2);
      expect(
        digest.summary,
        '1 request waiting · 2 errors · 1 reply · 3 tool calls (2 edit, 1 run) '
        '· 2 reported file changes',
      );
    });

    test('a prompt sent since returning means the user is caught up', () {
      final builder = d.AcpTimelineBuilder()
        ..appendLocalUserPrompt(const [AcpTextContent('first')]);
      final marker = AcpLastSeenMarker.of(builder.snapshot());
      builder.appendLocalUserPrompt(const [AcpTextContent('and now this')]);
      final timeline = builder.snapshot();
      expect(timeline.entries.last, isA<d.AcpMessageEntry>());
      expect((timeline.entries.last as d.AcpMessageEntry).isLocalPrompt, true);
      expect(_unread(marker, timeline), isNull);
    });

    test(
      'a trimmed marker puts the divider at the top with minimum counts',
      () {
        final marker = AcpLastSeenMarker.of(_timeline(seen, source: source));
        final timeline = _timeline(
          [_agent(7, 'Later reply'), _tool(8, 'z')],
          source: source,
          overflowed: true,
        );
        final state = _unread(marker, timeline)!;
        expect(state.dividerEntryIndex, 0);
        expect(state.earlierHistoryUnavailable, isTrue);
        expect(state.digest!.partial, isTrue);
        expect(
          state.digest!.summary,
          'at least 1 reply · 1 tool call (1 read)',
        );
      },
    );

    test('a rebuilt timeline finds the last seen tool call by identifier', () {
      final marker = AcpLastSeenMarker.of(
        _timeline([...seen, _tool(2, 'tool-x')], source: source),
      );
      // A reload numbers entries afresh and may drop local prompts.
      final rebuilt = _timeline([
        _agent(0, 'Looking.'),
        _tool(1, 'tool-x'),
        _agent(2, 'New since then'),
      ], source: Object());
      final state = _unread(marker, rebuilt)!;
      expect(state.dividerEntryIndex, 2);
      expect(state.digest!.replies, 1);
    });

    test('a rebuilt timeline finds a grown message by its start', () {
      final marker = AcpLastSeenMarker.of(
        _timeline([_user(0, 'Go'), _agent(1, 'Partial answ')], source: source),
      );
      final rebuilt = _timeline([
        _user(0, 'Go'),
        _agent(1, 'Partial answer that kept streaming'),
        _tool(2, 'later'),
      ], source: Object());
      final state = _unread(marker, rebuilt)!;
      expect(state.dividerEntryIndex, 2);
      expect(state.earlierHistoryUnavailable, isFalse);
    });

    test('falls back when a rebuilt timeline lacks the last seen entry', () {
      final marker = AcpLastSeenMarker.of(
        _timeline([...seen, _tool(2, 'gone')], source: source),
      );
      final rebuilt = _timeline([
        _agent(0, 'Only the tail was replayed'),
      ], source: Object());
      final state = _unread(marker, rebuilt)!;
      expect(state.dividerEntryIndex, 0);
      expect(state.earlierHistoryUnavailable, isTrue);
      expect(state.digest, isNull);
    });

    test('counts nested subagent work and marks its block', () {
      final marker = AcpLastSeenMarker.of(
        _timeline([
          ...seen,
          _tool(2, 'launch', kind: d.AcpToolKind.other, subagent: true),
        ], source: source),
      );
      final timeline = _timeline([
        ...seen,
        _tool(2, 'launch', kind: d.AcpToolKind.other, subagent: true),
        _agent(3, 'nested reply', parent: 'launch'),
        _tool(4, 'nested-tool', parent: 'launch'),
      ], source: source);
      final entries = mapAcpSessionTimeline(fakeAcpSession(timeline: timeline));
      final state = _unread(marker, timeline)!;
      expect(
        entries[state.dividerEntryIndex],
        isA<AcpSubagentTranscriptEntry>(),
      );
      expect(state.digest!.replies, 1);
      expect(state.digest!.toolCallCount, 1);
    });

    test('says new activity when nothing countable arrived', () {
      final marker = AcpLastSeenMarker.of(_timeline(seen, source: source));
      final timeline = _timeline([
        ...seen,
        d.AcpMessageEntry(
          role: d.AcpMessageRole.thought,
          order: 2,
          content: const [AcpTextContent('thinking')],
        ),
      ], source: source);
      expect(_unread(marker, timeline)!.digest!.summary, 'new activity');
    });
  });

  group('AcpLastSeenRegistry', () {
    test('keeps an earlier marker when the timeline is empty', () {
      final registry = AcpLastSeenRegistry();
      final key = fakeAcpKey();
      registry.record(key, _timeline([_agent(0, 'hi')], source: Object()));
      final marker = registry.markerFor(key);
      expect(marker, isNotNull);
      registry.record(key, const d.AcpTimeline.empty());
      expect(registry.markerFor(key), same(marker));
    });

    test('keys sessions without their bridge', () {
      final registry = AcpLastSeenRegistry()
        ..record(
          fakeAcpKey(bridgeId: 'old-bridge'),
          _timeline([_agent(0, 'hi')], source: Object()),
        );
      expect(registry.markerFor(fakeAcpKey(bridgeId: 'new-bridge')), isNotNull);
      expect(registry.markerFor(fakeAcpKey(acpSessionId: 'other')), isNull);
    });

    test('forgets the oldest sessions beyond its bound', () {
      final registry = AcpLastSeenRegistry();
      for (var i = 0; i <= AcpLastSeenRegistry.maxSessions; i++) {
        registry.record(
          fakeAcpKey(acpSessionId: 'session-$i'),
          _timeline([_agent(0, 'hi')], source: Object()),
        );
      }
      expect(registry.markerFor(fakeAcpKey(acpSessionId: 'session-0')), isNull);
      expect(
        registry.markerFor(
          fakeAcpKey(
            acpSessionId: 'session-${AcpLastSeenRegistry.maxSessions}',
          ),
        ),
        isNotNull,
      );
    });
  });

  group('AcpUnreadVisit', () {
    test('compares with where the user left and memoises per snapshot', () {
      final registry = AcpLastSeenRegistry();
      final key = fakeAcpKey();
      final source = Object();
      final before = fakeAcpSession(
        timeline: _timeline([_user(0, 'Go')], source: source),
      );
      AcpUnreadVisit(registry)
        ..begin(key)
        ..end(key, before);

      final after = before.copyWith(
        timeline: _timeline([
          _user(0, 'Go'),
          _agent(1, 'Back with results'),
        ], source: source),
      );
      final entries = mapAcpSessionTimeline(after);
      final visit = AcpUnreadVisit(registry)..begin(key);
      final state = visit.evaluate(after, entries);
      expect(state?.dividerEntryIndex, 1);
      expect(identical(visit.evaluate(after, entries), state), isTrue);

      visit.jumpToDivider();
      expect(visit.jumpSerial, 1);
      expect(visit.digestDismissed, isTrue);

      final pending = after.copyWith(
        error: const AcpSessionError(
          kind: AcpSessionErrorKind.unknown,
          message: 'boom',
        ),
      );
      expect(visit.evaluate(pending, entries)?.digest?.errors, 1);
    });
  });
}

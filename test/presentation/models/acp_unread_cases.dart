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
  Set<String> pending = const <String>{},
  bool error = false,
}) => computeAcpUnreadState(
  marker: marker,
  timeline: timeline,
  entries: mapAcpSessionTimeline(fakeAcpSession(timeline: timeline)),
  pendingRequestIds: pending,
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
      final state = _unread(marker, timeline, pending: {'r1'}, error: true)!;
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

    test('tells when a prompt was sent from this device since the marker', () {
      final builder = d.AcpTimelineBuilder()
        ..appendLocalUserPrompt(const [AcpTextContent('first')]);
      final marker = AcpLastSeenMarker.of(builder.snapshot())!;
      expect(acpPromptSentSince(marker, builder.snapshot()), isFalse);
      builder.appendLocalUserPrompt(const [AcpTextContent('and now this')]);
      expect(acpPromptSentSince(marker, builder.snapshot()), isTrue);
      // In a rebuilt timeline every local prompt is newer than the marker.
      final rebuilt = d.AcpTimelineBuilder()
        ..appendLocalUserPrompt(const [AcpTextContent('after reload')]);
      expect(acpPromptSentSince(marker, rebuilt.snapshot()), isTrue);
    });

    test('losing only the last seen entry to trimming loses nothing', () {
      final marker = AcpLastSeenMarker.of(_timeline(seen, source: source));
      final timeline = _timeline([_agent(2, 'Next')], source: source);
      final state = _unread(marker, timeline)!;
      expect(state.earlierHistoryUnavailable, isFalse);
      expect(state.digest!.partial, isFalse);
    });

    test('a short or empty remembered prefix never guesses', () {
      final rebuilt = _timeline([
        _user(0, 'Run the tests'),
        _agent(1, 'Let me check.'),
        _tool(2, 'a'),
        _agent(3, 'Let me fix that.'),
        _tool(4, 'b'),
        _agent(5, 'Let me run them again.'),
      ], source: Object());
      final short = AcpLastSeenMarker.of(
        _timeline([_user(0, 'Run'), _agent(1, 'Let me')], source: source),
      );
      final state = _unread(short, rebuilt)!;
      expect(state.earlierHistoryUnavailable, isTrue);
      expect(state.digest, isNull);

      final empty = AcpLastSeenMarker.of(
        _timeline([
          _user(0, 'Run'),
          d.AcpMessageEntry(role: d.AcpMessageRole.user, order: 1),
        ], source: source),
      );
      expect(_unread(empty, rebuilt)!.digest, isNull);
    });

    test('of several long matches the nearest to the old position wins', () {
      const repeated = 'Running the full test suite again now.';
      final marker = AcpLastSeenMarker.of(
        _timeline([
          _agent(0, repeated),
          _tool(1, 'x'),
          _agent(2, repeated),
        ], source: source),
      );
      final rebuilt = _timeline([
        _agent(0, repeated),
        _tool(1, 'x'),
        _agent(2, repeated),
        _tool(3, 'y'),
        _agent(4, repeated),
      ], source: Object());
      final state = _unread(marker, rebuilt)!;
      // Remembered as the second such reply, so entries after it are new.
      expect(state.dividerEntryIndex, 3);
    });

    test('reports tools that finished or failed while the user was away', () {
      final marker = AcpLastSeenMarker.of(
        _timeline([
          ...seen,
          _tool(
            2,
            'build',
            kind: d.AcpToolKind.execute,
            status: d.AcpToolStatus.inProgress,
          ),
          _tool(
            3,
            'edit',
            kind: d.AcpToolKind.edit,
            status: d.AcpToolStatus.pending,
          ),
        ], source: source),
      );
      final timeline = _timeline([
        ...seen,
        _tool(
          2,
          'build',
          kind: d.AcpToolKind.execute,
          status: d.AcpToolStatus.failed,
        ),
        _tool(3, 'edit', kind: d.AcpToolKind.edit, diffPaths: ['lib/a.dart']),
      ], source: source);
      final state = _unread(marker, timeline)!;
      expect(state.dividerEntryIndex, 2);
      expect(state.digest!.errors, 1);
      expect(state.digest!.reportedFileChanges, 1);
      expect(state.digest!.toolCallCount, 2);
    });

    test('counts reply turns, not message pieces or subagent chatter', () {
      final marker = AcpLastSeenMarker.of(_timeline(seen, source: source));
      final timeline = _timeline([
        ...seen,
        _agent(2, 'Starting.'),
        _tool(3, 'read'),
        _agent(4, 'Found it.'),
        _tool(5, 'helper', kind: d.AcpToolKind.other, subagent: true),
        _agent(6, 'sub one', parent: 'helper'),
        _agent(7, 'sub two', parent: 'helper'),
        _agent(8, 'Done.'),
        _user(9, 'Thanks, one more'),
        _agent(10, 'Sure.'),
      ], source: source);
      expect(_unread(marker, timeline)!.digest!.replies, 2);
    });

    test('says "at least" only for counts taken from the timeline', () {
      final marker = AcpLastSeenMarker.of(_timeline(seen, source: source));
      final timeline = _timeline(
        [_agent(7, 'Later reply')],
        source: source,
        overflowed: true,
      );
      expect(
        _unread(marker, timeline, pending: {'r1'})!.digest!.summary,
        '1 request waiting · at least 1 reply',
      );
    });

    test('an error already showing when the user left is not news', () {
      final marker = AcpLastSeenMarker.of(
        _timeline(seen, source: source),
        hadSessionError: true,
      );
      final timeline = _timeline([...seen, _agent(2, 'More')], source: source);
      expect(_unread(marker, timeline, error: true)!.digest!.errors, 0);
    });

    test('a failed edit is not a reported file change', () {
      final marker = AcpLastSeenMarker.of(_timeline(seen, source: source));
      final timeline = _timeline([
        ...seen,
        _tool(
          2,
          'edit',
          kind: d.AcpToolKind.edit,
          status: d.AcpToolStatus.failed,
          diffPaths: ['lib/a.dart'],
        ),
      ], source: source);
      expect(_unread(marker, timeline)!.digest!.reportedFileChanges, 0);
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
      // The message kept streaming after the user left, so it is unread too.
      expect(state.dividerEntryIndex, 1);
      expect(state.earlierHistoryUnavailable, isFalse);
      expect(state.digest!.replies, 1);
      expect(state.digest!.toolCallCount, 1);
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
      // A request or error known from the session state still shows.
      final waiting = _unread(marker, rebuilt, pending: {'r1'}, error: true)!;
      expect(waiting.dividerEntryIndex, 0);
      expect(waiting.earlierHistoryUnavailable, isTrue);
      expect(waiting.digest!.summary, '1 request waiting · 1 error');
    });

    test('a reply that kept streaming while away is unread', () {
      final marker = AcpLastSeenMarker.of(
        _timeline([...seen, _agent(2, 'Still')], source: source),
      )!;
      final grown = _timeline([
        ...seen,
        _agent(2, 'Still writing, and now done.'),
      ], source: source);
      expect(acpChangedSince(marker, grown), isTrue);
      final state = _unread(marker, grown)!;
      expect(state.dividerEntryIndex, 2);
      expect(state.digest!.replies, 1);
      // The same text is not news.
      final same = _timeline([...seen, _agent(2, 'Still')], source: source);
      expect(acpChangedSince(marker, same), isFalse);
      expect(_unread(marker, same), isNull);
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
        entries[state.dividerEntryIndex!],
        isA<AcpSubagentTranscriptEntry>(),
      );
      // Subagent messages are not reply turns; its tool call still counts.
      expect(state.digest!.replies, 0);
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
        ..end(key, acpSeenSnapshot(before, null, followingTail: true));

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
      // A new visit never resets the serial, so it is never replayed.
      visit.begin(key);
      expect(visit.jumpSerial, 1);
      expect(visit.digestDismissed, isFalse);

      final pending = after.copyWith(
        error: const AcpSessionError(
          kind: AcpSessionErrorKind.unknown,
          message: 'boom',
        ),
      );
      expect(visit.evaluate(pending, entries)?.digest?.errors, 1);
    });

    test(
      'stays caught up after a prompt even once it is trimmed or replayed',
      () {
        final registry = AcpLastSeenRegistry();
        final key = fakeAcpKey();
        final builder = d.AcpTimelineBuilder()
          ..appendLocalUserPrompt(const [AcpTextContent('first')]);
        final leaving = fakeAcpSession(timeline: builder.snapshot());
        registry.record(key, leaving.timeline);
        final visit = AcpUnreadVisit(registry)..begin(key);

        builder.appendLocalUserPrompt(const [AcpTextContent('my follow-up')]);
        final sent = leaving.copyWith(timeline: builder.snapshot());
        expect(visit.evaluate(sent, mapAcpSessionTimeline(sent)), isNull);

        // The follow-up is gone (trimmed, or replayed without its local id),
        // and replies to it arrive: they are not news.
        final rebuilt = leaving.copyWith(
          timeline: _timeline([
            _user(0, 'first'),
            _user(1, 'my follow-up'),
            _agent(2, 'Reply to the follow-up'),
          ], source: Object()),
        );
        expect(visit.evaluate(rebuilt, mapAcpSessionTimeline(rebuilt)), isNull);
      },
    );

    test('a short absence keeps the visit; a long one starts a new one', () {
      final registry = AcpLastSeenRegistry();
      final key = fakeAcpKey();
      final source = Object();
      AcpSessionState session(int replies) => fakeAcpSession(
        timeline: _timeline([
          _user(0, 'Go'),
          for (var i = 1; i <= replies; i++) _agent(i, 'Reply $i'),
        ], source: source),
      );
      registry.record(key, session(0).timeline);
      final visit = AcpUnreadVisit(registry)..begin(key);
      final one = session(1);
      expect(visit.evaluate(one, mapAcpSessionTimeline(one)), isNotNull);

      final two = session(2);
      AcpSeenSnapshot? seen(AcpSessionState s) =>
          acpSeenSnapshot(s, null, followingTail: true);
      visit
        ..depart(seen(one))
        ..arrive(key, left: false, current: seen(two));
      expect(visit.evaluate(one, mapAcpSessionTimeline(one)), isNotNull);

      // Long enough, but nothing arrived (an elicitation sheet, a picker):
      // the visit and its divider carry on.
      visit
        ..depart(seen(one))
        ..arrive(key, left: true, current: seen(one));
      expect(
        visit.evaluate(one, mapAcpSessionTimeline(one))?.dividerEntryIndex,
        1,
      );

      // Long enough, and a reply arrived meanwhile: a new visit starts.
      visit
        ..depart(seen(one))
        ..arrive(key, left: true, current: seen(two));
      expect(visit.evaluate(one, mapAcpSessionTimeline(one)), isNull);
      expect(
        visit.evaluate(two, mapAcpSessionTimeline(two))?.dividerEntryIndex,
        2,
      );
    });

    test('a request swapped for another while away starts a new visit', () {
      final registry = AcpLastSeenRegistry();
      final key = fakeAcpKey();
      final timeline = _timeline([_user(0, 'Go')], source: Object());
      AcpSessionState waitingOn(String requestKey) =>
          fakeAcpSession(timeline: timeline).copyWith(
            pendingPermissions: [
              AcpPendingPermission(
                requestKey: requestKey,
                sessionId: 's',
                toolCallId: 't-$requestKey',
                options: const [],
                requestedAt: DateTime.utc(2026),
              ),
            ],
          );
      final before = waitingOn('1');
      final after = waitingOn('2');
      registry.record(
        key,
        timeline,
        pendingRequestIds: acpPendingRequestIds(before),
      );
      final visit = AcpUnreadVisit(registry)..begin(key);
      expect(visit.evaluate(before, mapAcpSessionTimeline(before)), isNull);

      // The first request was answered elsewhere and a second one arrived:
      // the count is unchanged, but it is news.
      visit
        ..depart(acpSeenSnapshot(before, null, followingTail: true))
        ..arrive(
          key,
          left: true,
          current: acpSeenSnapshot(after, null, followingTail: true),
        );
      expect(
        visit.evaluate(after, mapAcpSessionTimeline(after))?.digest?.summary,
        '1 request waiting',
      );
    });

    test('ending while away keeps what was seen at departure', () {
      final registry = AcpLastSeenRegistry();
      final key = fakeAcpKey();
      final source = Object();
      final seenSession = fakeAcpSession(
        timeline: _timeline([_user(0, 'Go')], source: source),
      );
      final later = fakeAcpSession(
        timeline: _timeline([
          _user(0, 'Go'),
          _agent(1, 'Arrived while covered'),
        ], source: source),
      );
      AcpUnreadVisit(registry)
        ..begin(key)
        ..depart(acpSeenSnapshot(seenSession, null, followingTail: true))
        ..end(key, acpSeenSnapshot(later, null, followingTail: true));
      expect(registry.markerFor(key)!.order, 0);
    });

    test('a chat scrolled up has seen only what was on screen', () {
      final source = Object();
      final session = fakeAcpSession(
        timeline: _timeline([
          _user(0, 'Go'),
          _agent(1, 'One'),
          _agent(2, 'Two'),
          _agent(3, 'Three'),
        ], source: source),
      );
      final entries = mapAcpSessionTimeline(session);
      final following = acpSeenSnapshot(session, entries, followingTail: true);
      expect(following!.upToOrder, isNull);
      final scrolledUp = acpSeenSnapshot(
        session,
        entries,
        followingTail: false,
        lastVisibleEntryIndex: 1,
      );
      expect(scrolledUp!.upToOrder, 1);
    });

    test(
      'a prompt sent before scrolling up and leaving is not "sent since"',
      () {
        final registry = AcpLastSeenRegistry();
        final key = fakeAcpKey();
        final builder = d.AcpTimelineBuilder()
          ..appendLocalUserPrompt(const [AcpTextContent('Look at the logs')])
          ..apply(
            const d.AcpContentChunkUpdate(
              kind: 'agent_message_chunk',
              content: AcpTextContent('They show a timeout.'),
            ),
          )
          ..appendLocalUserPrompt(const [AcpTextContent('Now fix the tests')]);
        final leaving = fakeAcpSession(timeline: builder.snapshot());
        // Scrolled up to the agent's first reply, above the user's own prompt.
        final entries = mapAcpSessionTimeline(leaving);
        registry.record(
          key,
          leaving.timeline,
          upToOrder: acpSeenSnapshot(
            leaving,
            entries,
            followingTail: false,
            lastVisibleEntryIndex: 1,
          )!.upToOrder,
        );
        builder.apply(
          const d.AcpContentChunkUpdate(
            kind: 'agent_message_chunk',
            messageId: 'reply-2',
            content: AcpTextContent('Fixed them.'),
          ),
        );
        final back = leaving.copyWith(timeline: builder.snapshot());
        final state = AcpUnreadVisit(registry)..begin(key);
        expect(
          state.evaluate(back, mapAcpSessionTimeline(back))?.digest?.replies,
          1,
        );
      },
    );

    test('nested subagent output already on screen stays read', () {
      final registry = AcpLastSeenRegistry();
      final key = fakeAcpKey();
      final source = Object();
      final session = fakeAcpSession(
        plan: const [
          d.AcpPlanEntry(
            content: 'Ship it',
            priority: d.AcpPlanPriority.high,
            status: d.AcpPlanStatus.pending,
          ),
        ],
        timeline: _timeline([
          _user(0, 'Go'),
          _tool(1, 'helper', kind: d.AcpToolKind.other, subagent: true),
          _agent(2, 'Parent reply'),
          _agent(3, 'Nested reply', parent: 'helper'),
        ], source: source),
      );
      final entries = mapAcpSessionTimeline(session);
      // Rendered: prompt, helper, its nested transcript, the parent reply,
      // then the plan, which is below the screen.
      final replyIndex = entries.indexWhere(
        (entry) =>
            entry is AcpAssistantMessageEntry &&
            entry.markdown == 'Parent reply',
      );
      expect(entries.last, isA<AcpPlanEntry>());
      final seen = acpSeenSnapshot(
        session,
        entries,
        followingTail: false,
        lastVisibleEntryIndex: replyIndex,
      )!;
      registry.record(key, seen.timeline, upToOrder: seen.upToOrder);
      final visit = AcpUnreadVisit(registry)..begin(key);
      expect(visit.evaluate(session, entries), isNull);
    });

    test('a request or error with no timeline row still gets a digest', () {
      final source = Object();
      final timeline = _timeline([
        _user(0, 'Go'),
        _agent(1, 'Ok'),
      ], source: source);
      final marker = AcpLastSeenMarker.of(timeline);
      final state = _unread(marker, timeline, pending: {'r1'})!;
      expect(state.dividerEntryIndex, isNull);
      expect(state.digest!.summary, '1 request waiting');
      expect(_unread(marker, timeline, error: true)!.digest!.errors, 1);
      // Requests already waiting when the user left are not news.
      final waiting = AcpLastSeenMarker.of(timeline, pendingRequestIds: {'r1'});
      expect(_unread(waiting, timeline, pending: {'r1'}), isNull);
    });

    test('a request answered while away and a new one in its place is '
        'news', () {
      final source = Object();
      final timeline = _timeline([
        _user(0, 'Go'),
        _agent(1, 'Ok'),
      ], source: source);
      final marker = AcpLastSeenMarker.of(timeline, pendingRequestIds: {'r1'})!;
      expect(
        acpChangedSince(marker, timeline, pendingRequestIds: {'r2'}),
        isTrue,
      );
      expect(
        _unread(marker, timeline, pending: {'r2'})?.digest?.summary,
        '1 request waiting',
      );
      // Answering a request without a new one is not news.
      expect(acpChangedSince(marker, timeline), isFalse);
      expect(_unread(marker, timeline), isNull);
    });

    test('a request or error still gets a digest while the timeline is '
        'empty', () {
      final marker = AcpLastSeenMarker.of(
        _timeline([_user(0, 'Go'), _agent(1, 'Ok')], source: Object()),
      );
      // A reload that has not replayed anything yet.
      final empty = _timeline(const [], source: Object());
      final state = _unread(marker, empty, pending: {'r1'}, error: true)!;
      expect(state.dividerEntryIndex, isNull);
      expect(state.digest!.summary, '1 request waiting · 1 error');
      expect(_unread(marker, empty), isNull);
    });

    test('a tool cancelled while away counts as finished', () {
      final source = Object();
      final marker = AcpLastSeenMarker.of(
        _timeline([
          _user(0, 'Go'),
          _tool(1, 'run', status: d.AcpToolStatus.inProgress),
        ], source: source),
      );
      final timeline = _timeline([
        _user(0, 'Go'),
        _tool(1, 'run', status: d.AcpToolStatus.cancelled),
      ], source: source);
      expect(_unread(marker, timeline)?.digest?.toolCallCount, 1);
    });

    test('a short whole prompt like "continue" is found by position', () {
      final marker = AcpLastSeenMarker.of(
        _timeline([
          _user(0, 'continue'),
          _agent(1, 'Working.'),
          _user(2, 'continue'),
        ], source: Object()),
      );
      final rebuilt = _timeline([
        _user(0, 'continue'),
        _agent(1, 'Working.'),
        _user(2, 'continue'),
        _agent(3, 'Done.'),
        _user(4, 'continue'),
      ], source: Object());
      final state = _unread(marker, rebuilt)!;
      expect(state.earlierHistoryUnavailable, isFalse);
      expect(state.dividerEntryIndex, 3);
    });
  });
}

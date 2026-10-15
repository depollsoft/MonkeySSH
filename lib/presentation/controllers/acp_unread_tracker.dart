/// Last-seen tracking behind the native chat's unread divider and digest.
library;

import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/acp_session_keys.dart';
import '../../domain/models/acp_session_state.dart';
import '../../domain/models/acp_timeline.dart' as d;
import '../models/acp_timeline.dart';
import '../models/acp_timeline_mapper.dart';
import '../models/acp_unread.dart';

/// Shortest time away that counts as leaving a chat. Briefer absences, such
/// as a system file picker, a menu or a quick look at another app, keep the
/// current visit.
const Duration kAcpChatMinimumAbsence = Duration(seconds: 20);

/// How long after the app comes back from the background a change still
/// counts as having arrived while it was away. A hidden app can be
/// suspended (iOS does so about 30 s after it is hidden), and then what the
/// agent did meanwhile reaches the chat only after it is shown again, as
/// buffered output or a reconnect's replay.
const Duration kAcpChatCatchUpWindow = Duration(minutes: 2);

/// The clock [AcpChatPresence] and [AcpUnreadVisit] measure absences with.
@visibleForTesting
DateTime Function() acpChatPresenceClock = DateTime.now;

/// What the user had seen of a session when they went away.
typedef AcpSeenSnapshot = ({
  d.AcpTimeline timeline,
  int? upToOrder,
  int? sessionErrorFingerprint,
  Set<String> pendingRequestIds,
});

/// A content-free fingerprint of [session]'s error, or `null` when there is
/// none. Session errors hash by kind, message and retryable, so the same
/// error matches and a replacement does not; only the hash is kept.
int? acpSessionErrorFingerprint(AcpSessionState session) =>
    session.error?.hashCode;

/// Identifies each request waiting for an answer in [session], so a request
/// answered while the user was away and a new one in its place still count
/// as new. The request time guards against an agent reusing a request id
/// after it restarts.
Set<String> acpPendingRequestIds(AcpSessionState session) => {
  for (final request in session.pendingPermissions)
    'permission:${request.requestKey}@${request.requestedAt.microsecondsSinceEpoch}',
  for (final request in session.pendingWrites)
    'write:${request.requestKey}@${request.requestedAt.microsecondsSinceEpoch}',
  for (final request in session.pendingElicitations)
    'input:${request.requestKey}@${request.requestedAt.microsecondsSinceEpoch}',
};

/// What the user has seen of [session], mapped as [entries].
///
/// When the chat was following the newest output, that is everything.
/// Otherwise it is what was rendered down to the last row on screen: the
/// row of [lastVisibleRowId] in the top-level entry at
/// [lastVisibleEntryIndex], so a subagent block only partly on screen counts
/// only the rows reached. Subagent output is nested next to its launching
/// tool, so rendered order is not timeline order: the boundary is the newest
/// order below which every entry with a row was rendered, which never marks
/// an entry the user did not reach as seen.
AcpSeenSnapshot? acpSeenSnapshot(
  AcpSessionState? session,
  List<AcpTimelineEntry>? entries, {
  required bool followingTail,
  int? lastVisibleEntryIndex,
  String? lastVisibleRowId,
}) {
  if (session == null) return null;
  int? upToOrder;
  if (!followingTail &&
      entries != null &&
      lastVisibleEntryIndex != null &&
      lastVisibleEntryIndex >= 0 &&
      lastVisibleEntryIndex < entries.length) {
    final rendered = <String>{};
    for (var index = 0; index < lastVisibleEntryIndex; index++) {
      _collectIds(entries[index], rendered);
    }
    final last = entries[lastVisibleEntryIndex];
    if (lastVisibleRowId == null) {
      _collectIds(last, rendered);
    } else {
      final reached = <String>{};
      if (_collectIdsUpTo(last, reached, lastVisibleRowId)) {
        rendered.addAll(reached);
      }
    }
    final mapped = <String>{};
    for (final entry in entries) {
      _collectIds(entry, mapped);
    }
    upToOrder = -1;
    for (final entry in session.timeline.entries) {
      final id = acpPresentationEntryId(entry);
      // An entry with no row, such as a prompt with nothing addressed to
      // the user, has nothing to see.
      if (!mapped.contains(id)) continue;
      if (!rendered.contains(id)) break;
      upToOrder = entry.order;
    }
  }
  return (
    timeline: session.timeline,
    upToOrder: upToOrder,
    sessionErrorFingerprint: acpSessionErrorFingerprint(session),
    pendingRequestIds: acpPendingRequestIds(session),
  );
}

void _collectIds(AcpTimelineEntry entry, Set<String> ids) {
  if (entry case AcpSubagentTranscriptEntry(:final entries)) {
    for (final child in entries) {
      _collectIds(child, ids);
    }
    return;
  }
  ids.add(entry.id);
}

/// Adds the ids of [entry]'s rows, in the order the thread shows them, up to
/// and including the row of [lastRowId]. Returns whether that row was
/// reached; a subagent block's header row adds nothing of its own.
bool _collectIdsUpTo(
  AcpTimelineEntry entry,
  Set<String> ids,
  String lastRowId,
) {
  if (entry case AcpSubagentTranscriptEntry(:final entries)) {
    if (entry.id == lastRowId) return true;
    for (final child in entries) {
      if (_collectIdsUpTo(child, ids, lastRowId)) return true;
    }
    return false;
  }
  ids.add(entry.id);
  return entry.id == lastRowId;
}

/// Where the user left each native chat during this app run.
///
/// Markers stay in memory: after a restart a chat has no last-seen position
/// and shows no divider. Sessions are keyed without their bridge, so a chat
/// resumed on a recreated bridge keeps its marker. The oldest markers are
/// forgotten beyond [maxSessions].
class AcpLastSeenRegistry {
  /// Most sessions remembered at once.
  static const maxSessions = 64;

  final LinkedHashMap<String, AcpLastSeenMarker> _markers =
      LinkedHashMap<String, AcpLastSeenMarker>();

  /// Where the user left [key], if they have left it this app run.
  AcpLastSeenMarker? markerFor(AcpSessionKey key) => _markers[_id(key)];

  /// Records that the user has seen [timeline], up to [upToOrder] when
  /// given.
  ///
  /// An empty timeline, such as one still reconnecting, keeps the earlier
  /// marker rather than claiming nothing was seen.
  void record(
    AcpSessionKey key,
    d.AcpTimeline timeline, {
    int? upToOrder,
    int? sessionErrorFingerprint,
    Set<String> pendingRequestIds = const <String>{},
  }) {
    final marker = AcpLastSeenMarker.of(
      timeline,
      upToOrder: upToOrder,
      sessionErrorFingerprint: sessionErrorFingerprint,
      pendingRequestIds: pendingRequestIds,
    );
    if (marker == null) return;
    final id = _id(key);
    _markers
      ..remove(id)
      ..[id] = marker;
    while (_markers.length > maxSessions) {
      _markers.remove(_markers.keys.first);
    }
  }

  static String _id(AcpSessionKey key) =>
      jsonEncode(<Object?>[key.hostId, key.providerId, key.acpSessionId]);
}

/// The app run's last-seen registry.
final acpLastSeenRegistryProvider = Provider<AcpLastSeenRegistry>(
  (ref) => AcpLastSeenRegistry(),
);

/// One stay in a chat view: the marker it returned to, plus whether the
/// digest was dismissed, whether the user has caught up, and Jump requests.
class AcpUnreadVisit {
  /// Creates a visit tracker over [registry].
  AcpUnreadVisit(this._registry);

  final AcpLastSeenRegistry _registry;
  AcpLastSeenMarker? _marker;
  var _digestDismissed = false;
  var _caughtUp = false;
  var _jumpSerial = 0;
  AcpSeenSnapshot? _departure;
  _CatchUp? _catchUp;

  AcpUnreadState? _memo;
  Object? _memoTimeline;
  Object? _memoEntries;
  Set<String>? _memoPending;
  int? _memoError;

  /// Whether the user hid the digest for this visit.
  bool get digestDismissed => _digestDismissed;

  /// Grows each time the user asks to jump to the divider. It never resets,
  /// so a request the transcript already handled is never replayed.
  int get jumpSerial => _jumpSerial;

  /// Starts a visit to [key], comparing against where the user last left it.
  void begin(AcpSessionKey key) {
    _marker = _registry.markerFor(key);
    _digestDismissed = false;
    _caughtUp = false;
    _departure = null;
    _catchUp = null;
    _memo = null;
    _memoTimeline = null;
  }

  /// Notes what the user had seen when the chat went out of view. It only
  /// counts as leaving if [arrive] later says the absence was long enough.
  // ignore: use_setters_to_change_properties
  void depart(AcpSeenSnapshot? seen) => _departure = seen;

  /// The chat is in view again, now showing [current]. When [left] and
  /// something changed while it was out of view, what was seen at departure
  /// is recorded and a new visit compares against it. Otherwise the visit,
  /// and any divider it shows, carries on.
  ///
  /// When the app was [hidden], it may have been suspended, so what changed
  /// can still be on its way. Then the first change within
  /// [kAcpChatCatchUpWindow] starts the new visit, as [evaluate] notices it.
  void arrive(
    AcpSessionKey key, {
    required bool left,
    required AcpSeenSnapshot? current,
    bool hidden = false,
  }) {
    final departure = _departure;
    _departure = null;
    if (!left || departure == null || current == null) return;
    final atDeparture = AcpLastSeenMarker.of(
      departure.timeline,
      sessionErrorFingerprint: departure.sessionErrorFingerprint,
      pendingRequestIds: departure.pendingRequestIds,
    );
    if (atDeparture == null) return;
    if (acpChangedSince(
      atDeparture,
      current.timeline,
      pendingRequestIds: current.pendingRequestIds,
      sessionErrorFingerprint: current.sessionErrorFingerprint,
    )) {
      _startAfter(key, departure);
    } else if (hidden) {
      _catchUp = (
        key: key,
        departure: departure,
        marker: atDeparture,
        until: acpChatPresenceClock().add(kAcpChatCatchUpWindow),
      );
    }
  }

  /// Records [departure] as seen and starts a new visit that compares
  /// against it.
  void _startAfter(AcpSessionKey key, AcpSeenSnapshot departure) {
    _record(key, departure);
    begin(key);
  }

  /// Ends the visit. What the user had seen when they went out of view, or
  /// [seen] if they were looking, counts as seen.
  void end(AcpSessionKey key, AcpSeenSnapshot? seen) {
    final last = _departure ?? seen;
    if (last != null) _record(key, last);
  }

  void _record(AcpSessionKey key, AcpSeenSnapshot seen) => _registry.record(
    key,
    seen.timeline,
    upToOrder: seen.upToOrder,
    sessionErrorFingerprint: seen.sessionErrorFingerprint,
    pendingRequestIds: seen.pendingRequestIds,
  );

  /// Asks the transcript to scroll to the divider and hides the digest.
  void jumpToDivider() {
    _jumpSerial++;
    _digestDismissed = true;
  }

  /// Hides the digest for the rest of this visit; the divider stays.
  void dismissDigest() => _digestDismissed = true;

  /// The unread divider and digest for [session], mapped as [entries].
  ///
  /// Once the user sends a prompt during the visit they are caught up: the
  /// divider and digest stay away until they leave and come back, even if
  /// that prompt is later trimmed or replayed under another identifier.
  AcpUnreadState? evaluate(
    AcpSessionState session,
    List<AcpTimelineEntry> entries,
  ) {
    _catchUpWith(session);
    final marker = _marker;
    if (marker == null || _caughtUp) return null;
    if (acpPromptSentSince(marker, session.timeline)) {
      _caughtUp = true;
      return _memo = null;
    }
    final pending = acpPendingRequestIds(session);
    final error = acpSessionErrorFingerprint(session);
    if (identical(_memoTimeline, session.timeline) &&
        identical(_memoEntries, entries) &&
        setEquals(_memoPending, pending) &&
        _memoError == error) {
      return _memo;
    }
    _memoTimeline = session.timeline;
    _memoEntries = entries;
    _memoPending = pending;
    _memoError = error;
    return _memo = computeAcpUnreadState(
      marker: marker,
      timeline: session.timeline,
      entries: entries,
      pendingRequestIds: pending,
      sessionErrorFingerprint: error,
    );
  }

  /// Starts the new visit a return from the background was waiting for, once
  /// [session] shows a change since departure.
  void _catchUpWith(AcpSessionState session) {
    final catchUp = _catchUp;
    if (catchUp == null) return;
    if (acpChatPresenceClock().isAfter(catchUp.until)) {
      _catchUp = null;
    } else if (acpChangedSince(
      catchUp.marker,
      session.timeline,
      pendingRequestIds: acpPendingRequestIds(session),
      sessionErrorFingerprint: acpSessionErrorFingerprint(session),
    )) {
      _startAfter(catchUp.key, catchUp.departure);
    }
  }
}

/// A return from the background that found nothing new yet, waiting for
/// what the app may have missed while suspended.
typedef _CatchUp = ({
  AcpSessionKey key,
  AcpSeenSnapshot departure,
  AcpLastSeenMarker marker,
  DateTime until,
});

/// Reports when a chat goes out of view and comes back.
///
/// Out of view means another route covers the chat, or the app is hidden.
/// [onBack] says whether the absence lasted [kAcpChatMinimumAbsence] or
/// more; shorter ones (a system file picker, a menu, a quick app switch) do
/// not count as leaving.
class AcpChatPresence extends StatefulWidget {
  /// Creates a presence observer around [child].
  const AcpChatPresence({
    required this.onAway,
    required this.onBack,
    required this.child,
    super.key,
  });

  /// The chat went out of view.
  final VoidCallback onAway;

  /// The chat is in view again; [left] when the absence was long enough,
  /// and [hidden] when the app was hidden at some point during it.
  final void Function({required bool left, required bool hidden}) onBack;

  /// The chat.
  final Widget child;

  @override
  State<AcpChatPresence> createState() => _AcpChatPresenceState();
}

class _AcpChatPresenceState extends State<AcpChatPresence> {
  late final AppLifecycleListener _lifecycle;
  var _hidden = false;
  var _covered = false;
  var _hiddenWhileAway = false;
  DateTime? _awaySince;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onHide: () => _setHidden(hidden: true),
      onShow: () => _setHidden(hidden: false),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final covered = !(ModalRoute.isCurrentOf(context) ?? true);
    if (covered == _covered) return;
    _covered = covered;
    // Route changes arrive during build; report them once it is done.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _update();
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  void _setHidden({required bool hidden}) {
    if (hidden == _hidden) return;
    _hidden = hidden;
    _update();
  }

  void _update() {
    final away = _hidden || _covered;
    final since = _awaySince;
    if (away && since == null) {
      _awaySince = acpChatPresenceClock();
      _hiddenWhileAway = _hidden;
      widget.onAway();
    } else if (away) {
      _hiddenWhileAway = _hiddenWhileAway || _hidden;
    } else if (since != null) {
      _awaySince = null;
      widget.onBack(
        left:
            acpChatPresenceClock().difference(since) >= kAcpChatMinimumAbsence,
        hidden: _hiddenWhileAway,
      );
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

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

/// The clock [AcpChatPresence] measures absences with.
@visibleForTesting
DateTime Function() acpChatPresenceClock = DateTime.now;

/// What the user had seen of a session when they went away.
typedef AcpSeenSnapshot = ({
  d.AcpTimeline timeline,
  int? upToOrder,
  bool hadSessionError,
  Set<String> pendingRequestIds,
});

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
/// Otherwise it is what was rendered down to [lastVisibleEntryIndex], the
/// last top-level entry on screen. Subagent output is nested next to its
/// launching tool, so rendered order is not timeline order: the boundary is
/// the newest order below which every entry was rendered, which never marks
/// an entry the user did not reach as seen.
AcpSeenSnapshot? acpSeenSnapshot(
  AcpSessionState? session,
  List<AcpTimelineEntry>? entries, {
  required bool followingTail,
  int? lastVisibleEntryIndex,
}) {
  if (session == null) return null;
  int? upToOrder;
  if (!followingTail &&
      entries != null &&
      lastVisibleEntryIndex != null &&
      lastVisibleEntryIndex < entries.length - 1) {
    final rendered = <String>{};
    for (var index = 0; index <= lastVisibleEntryIndex; index++) {
      _collectIds(entries[index], rendered);
    }
    upToOrder = -1;
    for (final entry in session.timeline.entries) {
      if (!rendered.contains(acpPresentationEntryId(entry))) break;
      upToOrder = entry.order;
    }
  }
  return (
    timeline: session.timeline,
    upToOrder: upToOrder,
    hadSessionError: session.error != null,
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
    bool hadSessionError = false,
    Set<String> pendingRequestIds = const <String>{},
  }) {
    final marker = AcpLastSeenMarker.of(
      timeline,
      upToOrder: upToOrder,
      hadSessionError: hadSessionError,
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

  AcpUnreadState? _memo;
  Object? _memoTimeline;
  Object? _memoEntries;
  Set<String>? _memoPending;
  bool? _memoError;

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
  void arrive(
    AcpSessionKey key, {
    required bool left,
    required AcpSeenSnapshot? current,
  }) {
    final departure = _departure;
    _departure = null;
    if (!left || departure == null || current == null) return;
    final atDeparture = AcpLastSeenMarker.of(
      departure.timeline,
      hadSessionError: departure.hadSessionError,
      pendingRequestIds: departure.pendingRequestIds,
    );
    if (atDeparture == null ||
        !acpChangedSince(
          atDeparture,
          current.timeline,
          pendingRequestIds: current.pendingRequestIds,
          hasSessionError: current.hadSessionError,
        )) {
      return;
    }
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
    hadSessionError: seen.hadSessionError,
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
    final marker = _marker;
    if (marker == null || _caughtUp) return null;
    if (acpPromptSentSince(marker, session.timeline)) {
      _caughtUp = true;
      return _memo = null;
    }
    final pending = acpPendingRequestIds(session);
    final hasError = session.error != null;
    if (identical(_memoTimeline, session.timeline) &&
        identical(_memoEntries, entries) &&
        setEquals(_memoPending, pending) &&
        _memoError == hasError) {
      return _memo;
    }
    _memoTimeline = session.timeline;
    _memoEntries = entries;
    _memoPending = pending;
    _memoError = hasError;
    return _memo = computeAcpUnreadState(
      marker: marker,
      timeline: session.timeline,
      entries: entries,
      pendingRequestIds: pending,
      hasSessionError: hasError,
    );
  }
}

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

  /// The chat is in view again; [left] when the absence was long enough.
  final void Function({required bool left}) onBack;

  /// The chat.
  final Widget child;

  @override
  State<AcpChatPresence> createState() => _AcpChatPresenceState();
}

class _AcpChatPresenceState extends State<AcpChatPresence> {
  late final AppLifecycleListener _lifecycle;
  var _hidden = false;
  var _covered = false;
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
      widget.onAway();
    } else if (!away && since != null) {
      _awaySince = null;
      widget.onBack(
        left:
            acpChatPresenceClock().difference(since) >= kAcpChatMinimumAbsence,
      );
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

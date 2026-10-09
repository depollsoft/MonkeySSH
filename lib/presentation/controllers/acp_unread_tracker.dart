/// Last-seen tracking behind the native chat's unread divider and digest.
library;

import 'dart:collection';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/acp_session_keys.dart';
import '../../domain/models/acp_session_state.dart';
import '../../domain/models/acp_timeline.dart' as d;
import '../models/acp_timeline.dart';
import '../models/acp_unread.dart';

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

  /// Records that the user has seen everything in [timeline].
  ///
  /// An empty timeline, such as one still reconnecting, keeps the earlier
  /// marker rather than claiming nothing was seen.
  void record(AcpSessionKey key, d.AcpTimeline timeline) {
    final marker = AcpLastSeenMarker.of(timeline);
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
/// digest was dismissed and how often the user jumped to the divider.
class AcpUnreadVisit {
  /// Creates a visit tracker over [registry].
  AcpUnreadVisit(this._registry);

  final AcpLastSeenRegistry _registry;
  AcpLastSeenMarker? _marker;
  var _digestDismissed = false;
  var _jumpSerial = 0;

  AcpUnreadState? _memo;
  Object? _memoTimeline;
  Object? _memoEntries;
  int? _memoPending;
  bool? _memoError;

  /// Whether the user hid the digest for this visit.
  bool get digestDismissed => _digestDismissed;

  /// Grows each time the user asks to jump to the divider.
  int get jumpSerial => _jumpSerial;

  /// Starts a visit to [key], comparing against where the user last left it.
  void begin(AcpSessionKey key) {
    _marker = _registry.markerFor(key);
    _digestDismissed = false;
    _memo = null;
    _memoTimeline = null;
  }

  /// Ends the visit: everything in [session]'s timeline now counts as seen.
  void end(AcpSessionKey key, AcpSessionState? session) {
    if (session != null) _registry.record(key, session.timeline);
  }

  /// Asks the transcript to scroll to the divider and hides the digest.
  void jumpToDivider() {
    _jumpSerial++;
    _digestDismissed = true;
  }

  /// Hides the digest for the rest of this visit; the divider stays.
  void dismissDigest() => _digestDismissed = true;

  /// The unread divider and digest for [session], mapped as [entries].
  AcpUnreadState? evaluate(
    AcpSessionState session,
    List<AcpTimelineEntry> entries,
  ) {
    final pending =
        session.pendingPermissions.length +
        session.pendingWrites.length +
        session.pendingElicitations.length;
    final hasError = session.error != null;
    if (identical(_memoTimeline, session.timeline) &&
        identical(_memoEntries, entries) &&
        _memoPending == pending &&
        _memoError == hasError) {
      return _memo;
    }
    _memoTimeline = session.timeline;
    _memoEntries = entries;
    _memoPending = pending;
    _memoError = hasError;
    return _memo = computeAcpUnreadState(
      marker: _marker,
      timeline: session.timeline,
      entries: entries,
      pendingRequests: pending,
      hasSessionError: hasError,
    );
  }
}

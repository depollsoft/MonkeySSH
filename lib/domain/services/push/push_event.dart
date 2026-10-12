import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../models/tmux_state.dart';

/// Coarse event kinds a host can push (docs/push-notifications.md).
enum PushEventKind {
  /// A native agent is waiting for a permission decision.
  permission,

  /// A native agent is waiting for an answer.
  input,

  /// A native agent finished its turn.
  finished,

  /// A terminal window rang the bell or posted a desktop notification.
  alert,

  /// The user asked for a test notification.
  test;

  /// Parses a wire name, returning null for unknown kinds.
  static PushEventKind? tryParse(Object? value) {
    for (final kind in values) {
      if (kind.name == value) return kind;
    }
    return null;
  }
}

/// A decrypted push payload. Holds opaque identifiers only.
@immutable
class PushEvent {
  /// Creates an event.
  const PushEvent({
    required this.hostRef,
    required this.kind,
    required this.timestamp,
    this.windowId,
    this.sessionName,
  });

  /// The host reference this device registered on the host.
  final String hostRef;

  /// What happened.
  final PushEventKind kind;

  /// When the host saw it.
  final DateTime timestamp;

  /// MonkeyMux window id such as `@3`, when the event names one.
  final String? windowId;

  /// MonkeyMux session owning [windowId], when the event names one.
  final String? sessionName;

  /// Parses decrypted payload bytes, returning null for anything malformed.
  static PushEvent? tryParse(List<int> plaintext) {
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(plaintext));
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?> || decoded['v'] != 1) {
      return null;
    }
    final hostRef = decoded['hostRef'];
    final kind = PushEventKind.tryParse(decoded['kind']);
    final ts = decoded['ts'];
    // Bounded so DateTime cannot overflow on a hostile value.
    if (hostRef is! String ||
        hostRef.isEmpty ||
        kind == null ||
        ts is! int ||
        ts < 0 ||
        ts > 1 << 40) {
      return null;
    }
    final window = decoded['window'];
    final session = decoded['sessionId'];
    final windowId = window is String && isValidTmuxWindowId(window)
        ? window
        : null;
    final sessionName = session is String && session.trim().isNotEmpty
        ? session
        : null;
    return PushEvent(
      hostRef: hostRef,
      kind: kind,
      timestamp: DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true),
      windowId: windowId,
      sessionName: sessionName,
    );
  }
}

/// Where a push notification tap should land.
@immutable
class PushNavigationTarget {
  /// Creates a target.
  const PushNavigationTarget({
    required this.hostId,
    required this.kind,
    this.sessionName,
    this.windowId,
    this.connectionId,
  });

  /// The saved host.
  final int hostId;

  /// What happened, for snackbar wording.
  final PushEventKind kind;

  /// MonkeyMux session to attach, when known.
  final String? sessionName;

  /// MonkeyMux window to select, when known.
  final String? windowId;

  /// An existing connection to reuse, when one is attached to that session.
  final int? connectionId;

  /// Whether the target names a specific window.
  bool get hasWindow => sessionName != null && windowId != null;

  @override
  bool operator ==(Object other) =>
      other is PushNavigationTarget &&
      other.hostId == hostId &&
      other.kind == kind &&
      other.sessionName == sessionName &&
      other.windowId == windowId &&
      other.connectionId == connectionId;

  @override
  int get hashCode =>
      Object.hash(hostId, kind, sessionName, windowId, connectionId);
}

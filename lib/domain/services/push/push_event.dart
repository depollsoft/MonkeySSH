import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../models/tmux_state.dart';

/// Coarse event kinds a host can push (docs/push-notifications.md).
enum PushEventKind {
  /// A coding agent is waiting for a permission decision.
  permission,

  /// A coding agent is waiting for an answer.
  input,

  /// A coding agent finished its turn.
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
    this.alertCategories,
    this.agent,
    this.windowTitle,
    this.request = false,
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

  /// For an `alert`, whether it was a `bell`, a program's `notice`, or both.
  /// Null from helpers before 0.1.233, which do not say.
  final Set<String>? alertCategories;

  /// The agent the window runs, as MonkeyMux names it (such as `claude`),
  /// from 0.1.236 on when it knows.
  final String? agent;

  /// The window's title as the window bar shows it, from 0.1.237 on when it
  /// has one worth showing.
  final String? windowTitle;

  /// For an `alert`, whether the window's program was waiting on the user,
  /// so it belongs in the window's request slot (from 0.1.243 on).
  final bool request;

  /// Parses decrypted payload bytes, returning null for anything malformed.
  static PushEvent? tryParse(List<int> plaintext) {
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(plaintext));
    } on FormatException {
      return null;
    }
    // `1.0` is not an integer here or in the iOS extension.
    if (decoded is! Map<String, Object?> ||
        decoded['v'] is! int ||
        decoded['v'] != 1) {
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
    final alert = decoded['alert'];
    final agent = decoded['agent'];
    final title = decoded['title'];
    return PushEvent(
      hostRef: hostRef,
      kind: kind,
      timestamp: DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true),
      windowId: windowId,
      sessionName: sessionName,
      alertCategories: alert is List
          ? {
              for (final category in alert.whereType<String>())
                if (category == 'bell' || category == 'notice') category,
            }
          : null,
      agent: agent is String && _agentPattern.hasMatch(agent) ? agent : null,
      windowTitle: title is String ? _cleanWindowTitle(title) : null,
      request: decoded['request'] == true,
    );
  }
}

final _agentPattern = RegExp(r'^[a-z0-9-]{1,32}$');

/// Runs of whitespace and control characters, which a notification shows as
/// one space.
final _titleSpacePattern = RegExp(r'[\s\x00-\x1f\x7f-\x9f]+');

/// MonkeyMux cuts titles to 64 characters; anything longer is not from it.
String? _cleanWindowTitle(String title) {
  final cleaned = title.replaceAll(_titleSpacePattern, ' ').trim();
  if (cleaned.isEmpty || cleaned.runes.length > 64) return null;
  return cleaned;
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
    this.alertCategories,
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

  /// For an `alert`, its categories when the host said; see
  /// [PushEvent.alertCategories].
  final Set<String>? alertCategories;

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

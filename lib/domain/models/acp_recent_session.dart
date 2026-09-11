import 'package:flutter/foundation.dart';

import 'acp_json.dart';
import 'acp_session_keys.dart';

/// Maximum persisted provider-title characters for one recent session.
const kAcpRecentTitleMaxCharacters = 256;

/// Maximum persisted working-directory characters for one recent session.
const kAcpRecentCwdMaxCharacters = 1024;

/// A persistable navigation reference to a recently used ACP session.
///
/// This stores identifiers, bounded display metadata (provider title and
/// working directory), and timestamps. It never stores transcript messages,
/// attachments, tool payloads, or reasoning.
@immutable
final class AcpRecentSessionRef {
  /// Creates a recent-session reference.
  const AcpRecentSessionRef({
    required this.hostId,
    required this.providerId,
    required this.bridgeId,
    required this.acpSessionId,
    required this.createdAt,
    required this.lastActivityAt,
    this.title,
    this.cwd,
  });

  /// Attempts to parse a stored reference, returning `null` when the shape or
  /// any required field is invalid.
  ///
  /// Parsing is fully defensive: a single malformed entry must never throw or
  /// prevent sibling entries from loading.
  static AcpRecentSessionRef? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final hostId = _readInt(json['hostId']);
    final providerId = _readNonEmptyString(json['providerId']);
    final bridgeId = _readNonEmptyString(json['bridgeId']);
    final acpSessionId = _readNonEmptyString(json['acpSessionId']);
    if (hostId == null ||
        providerId == null ||
        bridgeId == null ||
        acpSessionId == null) {
      return null;
    }
    final createdAt = _readTimestamp(json['createdAt']);
    final lastActivityAt = _readTimestamp(json['lastActivityAt']) ?? createdAt;
    if (createdAt == null || lastActivityAt == null) return null;
    return AcpRecentSessionRef(
      hostId: hostId,
      providerId: providerId,
      bridgeId: bridgeId,
      acpSessionId: acpSessionId,
      createdAt: createdAt,
      lastActivityAt: lastActivityAt,
      title: _readOptionalString(json['title'], kAcpRecentTitleMaxCharacters),
      cwd: _readOptionalString(json['cwd'], kAcpRecentCwdMaxCharacters),
    );
  }

  /// Saved host identifier.
  final int hostId;

  /// Provider identifier.
  final String providerId;

  /// Opaque remote bridge identifier.
  final String bridgeId;

  /// Remote ACP session identifier.
  final String acpSessionId;

  /// Optional non-content session title.
  final String? title;

  /// Optional working directory.
  final String? cwd;

  /// When the session was first created.
  final DateTime createdAt;

  /// When the session was last active.
  final DateTime lastActivityAt;

  /// Stable composite key for this reference.
  AcpSessionKey get key => AcpSessionKey.of(
    hostId: hostId,
    providerId: providerId,
    bridgeId: bridgeId,
    acpSessionId: acpSessionId,
  );

  /// Encodes this reference for storage.
  Map<String, Object?> toJson() => <String, Object?>{
    'hostId': hostId,
    'providerId': providerId,
    'bridgeId': bridgeId,
    'acpSessionId': acpSessionId,
    if (title != null) 'title': title,
    if (cwd != null) 'cwd': cwd,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'lastActivityAt': lastActivityAt.toUtc().toIso8601String(),
  };

  /// Returns a copy with selected fields replaced.
  AcpRecentSessionRef copyWith({String? title, String? cwd}) =>
      AcpRecentSessionRef(
        hostId: hostId,
        providerId: providerId,
        bridgeId: bridgeId,
        acpSessionId: acpSessionId,
        title: title ?? this.title,
        cwd: cwd ?? this.cwd,
        createdAt: createdAt,
        lastActivityAt: lastActivityAt,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpRecentSessionRef &&
          hostId == other.hostId &&
          providerId == other.providerId &&
          bridgeId == other.bridgeId &&
          acpSessionId == other.acpSessionId &&
          title == other.title &&
          cwd == other.cwd &&
          createdAt == other.createdAt &&
          lastActivityAt == other.lastActivityAt;

  @override
  int get hashCode => Object.hash(
    hostId,
    providerId,
    bridgeId,
    acpSessionId,
    title,
    cwd,
    createdAt,
    lastActivityAt,
  );

  @override
  String toString() =>
      'AcpRecentSessionRef(hostId: $hostId, providerId: $providerId)';

  static int? _readInt(Object? value) =>
      value is int ? value : (value is String ? int.tryParse(value) : null);

  static String? _readNonEmptyString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty || trimmed.length > acpMaxIdentifierCharacters
        ? null
        : trimmed;
  }

  static String? _readOptionalString(Object? value, int maxCharacters) {
    if (value is! String) return null;
    return value.length <= maxCharacters
        ? value
        : value.substring(0, maxCharacters);
  }

  static DateTime? _readTimestamp(Object? value) {
    if (value is String) {
      return DateTime.tryParse(value)?.toUtc();
    }
    if (value is int) {
      // Interpret bare integers as epoch milliseconds, but never let one
      // corrupted setting prevent every sibling recent from loading.
      const maxEpochMilliseconds = 8640000000000000;
      if (value < -maxEpochMilliseconds || value > maxEpochMilliseconds) {
        return null;
      }
      return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
    }
    return null;
  }
}

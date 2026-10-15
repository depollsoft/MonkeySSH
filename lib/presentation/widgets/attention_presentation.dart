/// Labels, icons and tones for [AttentionReason], shared by the Connections
/// tab and the native session switcher so every surface says the same thing.
library;

import 'package:flutter/material.dart';

import '../../domain/models/connection_attention.dart';
import 'acp_session_presentation.dart';
import 'mux_window_status_badge.dart';

/// Display vocabulary for an attention reason. Every reason pairs an icon with
/// a text label, so color is never the only signal.
extension AttentionReasonPresentation on AttentionReason {
  /// Short, lowercase chip label.
  String get label => switch (this) {
    AttentionReason.permission => 'permission',
    AttentionReason.input => 'input',
    AttentionReason.signIn => 'sign-in',
    AttentionReason.hostRequest => 'request',
    AttentionReason.blocked => 'blocked',
    AttentionReason.alert => 'alert',
    AttentionReason.notification => 'notification',
    AttentionReason.progressError => 'error',
    AttentionReason.progressPaused => 'paused',
    AttentionReason.lowQuota => 'low quota',
  };

  /// Plain description, used in rows and screen-reader labels.
  String get description => switch (this) {
    AttentionReason.permission => 'needs permission',
    AttentionReason.input => 'asked a question',
    AttentionReason.signIn => 'needs sign-in',
    AttentionReason.hostRequest => 'has a request pending',
    AttentionReason.blocked => 'is waiting for you',
    AttentionReason.alert => 'rang the bell',
    AttentionReason.notification => 'sent a notification',
    AttentionReason.progressError => 'reported an error',
    AttentionReason.progressPaused => 'reported paused progress',
    AttentionReason.lowQuota => 'is low on account allowance',
  };

  /// Icon shown beside [label]; a blocked program's icon matches the one the
  /// terminal window navigator shows for it.
  IconData get icon => switch (this) {
    AttentionReason.permission => Icons.pending_actions,
    AttentionReason.input => Icons.help_outline,
    AttentionReason.signIn => Icons.key,
    AttentionReason.hostRequest => Icons.pending_outlined,
    AttentionReason.blocked => Icons.front_hand_outlined,
    AttentionReason.alert => Icons.notifications_active,
    AttentionReason.notification => Icons.mark_chat_unread_outlined,
    AttentionReason.progressError => Icons.error_outline,
    AttentionReason.progressPaused => Icons.pause_circle_outline,
    AttentionReason.lowQuota => Icons.data_usage,
  };

  /// Semantic tone used to resolve theme colors.
  ///
  /// The terminal window navigator uses the same rule (see DESIGN.md, Status
  /// & Badges): red when the user must act (an agent blocked on them, a bell
  /// or notification, an error), amber for a warning or a finished turn, teal
  /// while it works. Red never sits on a row that sorts below an amber one.
  AcpStatusTone get tone => switch (this) {
    AttentionReason.permission ||
    AttentionReason.input ||
    AttentionReason.signIn ||
    AttentionReason.hostRequest ||
    AttentionReason.blocked ||
    AttentionReason.alert ||
    AttentionReason.notification ||
    AttentionReason.progressError => AcpStatusTone.error,
    AttentionReason.progressPaused ||
    AttentionReason.lowQuota => AcpStatusTone.warning,
  };
}

/// Foreground and background colors for a filled status pill, with the
/// background adjusted where needed so the small label stays legible (see
/// [legiblePillColors]).
(Color, Color) attentionToneColors(ColorScheme scheme, AcpStatusTone tone) {
  final (foreground, background) = switch (tone) {
    AcpStatusTone.active => (
      scheme.onPrimaryContainer,
      scheme.primaryContainer,
    ),
    AcpStatusTone.warning => (
      scheme.onTertiaryContainer,
      scheme.tertiaryContainer,
    ),
    AcpStatusTone.error => (scheme.onErrorContainer, scheme.errorContainer),
    AcpStatusTone.neutral => (
      scheme.onSurfaceVariant,
      scheme.surfaceContainerHighest,
    ),
  };
  return legiblePillColors(foreground, background);
}

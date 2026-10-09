/// Labels, icons and tones for [AttentionReason], shared by the Connections
/// tab and the native session switcher so every surface says the same thing.
library;

import 'package:flutter/material.dart';

import '../../domain/models/connection_attention.dart';
import 'acp_session_presentation.dart';

/// Display vocabulary for an attention reason. Every reason pairs an icon with
/// a text label, so color is never the only signal.
extension AttentionReasonPresentation on AttentionReason {
  /// Short, lowercase chip label.
  String get label => switch (this) {
    AttentionReason.permission => 'permission',
    AttentionReason.input => 'input',
    AttentionReason.signIn => 'sign-in',
    AttentionReason.hostRequest => 'request',
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
    AttentionReason.alert => 'rang the bell',
    AttentionReason.notification => 'sent a notification',
    AttentionReason.progressError => 'reported an error',
    AttentionReason.progressPaused => 'reported paused progress',
    AttentionReason.lowQuota => 'is low on account allowance',
  };

  /// Icon shown beside [label].
  IconData get icon => switch (this) {
    AttentionReason.permission => Icons.gpp_maybe_outlined,
    AttentionReason.input => Icons.help_outline,
    AttentionReason.signIn => Icons.lock_outline,
    AttentionReason.hostRequest => Icons.pending_actions,
    AttentionReason.alert => Icons.notifications_active,
    AttentionReason.notification => Icons.mark_chat_unread_outlined,
    AttentionReason.progressError => Icons.error_outline,
    AttentionReason.progressPaused => Icons.pause_circle_outline,
    AttentionReason.lowQuota => Icons.data_usage,
  };

  /// Semantic tone used to resolve theme colors.
  AcpStatusTone get tone => switch (this) {
    AttentionReason.alert ||
    AttentionReason.notification ||
    AttentionReason.progressError => AcpStatusTone.error,
    AttentionReason.permission ||
    AttentionReason.input ||
    AttentionReason.signIn ||
    AttentionReason.hostRequest ||
    AttentionReason.progressPaused ||
    AttentionReason.lowQuota => AcpStatusTone.warning,
  };
}

/// Foreground and background container colors for a filled status pill.
(Color, Color) attentionToneColors(ColorScheme scheme, AcpStatusTone tone) =>
    switch (tone) {
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

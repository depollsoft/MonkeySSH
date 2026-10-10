import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/models/terminal_program_status.dart';
import '../../domain/models/tmux_state.dart';
import 'mux_window_status_badge.dart';

/// Compact status badge for a tmux window.
class TmuxWindowStatusBadge extends StatefulWidget {
  /// Creates a new [TmuxWindowStatusBadge].
  const TmuxWindowStatusBadge({required this.window, super.key});

  /// The tmux window whose status is being displayed.
  final TmuxWindow window;

  @override
  State<TmuxWindowStatusBadge> createState() => _TmuxWindowStatusBadgeState();

  static _TmuxWindowStatusVisual _statusVisual(
    ThemeData theme,
    TmuxWindow window,
  ) {
    if (window.reportedStatus case final status?) {
      return _programStatusVisual(theme.colorScheme, status);
    }
    if (window.hasAlert) {
      return _TmuxWindowStatusVisual(
        icon: Icons.notifications_active,
        foregroundColor: theme.colorScheme.onErrorContainer,
        backgroundColor: theme.colorScheme.errorContainer,
      );
    }
    if (window.isIdle) {
      return _TmuxWindowStatusVisual(
        icon: Icons.hourglass_bottom,
        foregroundColor: theme.colorScheme.onTertiaryContainer,
        backgroundColor: theme.colorScheme.tertiaryContainer,
      );
    }
    return _TmuxWindowStatusVisual(
      icon: Icons.play_arrow,
      foregroundColor: theme.colorScheme.onPrimaryContainer,
      backgroundColor: theme.colorScheme.primaryContainer,
    );
  }

  /// Matches the rest of the mux list: red when the user must act now, yellow
  /// when the program waits for its next instruction, teal while it works.
  static _TmuxWindowStatusVisual _programStatusVisual(
    ColorScheme scheme,
    TerminalProgramStatus status,
  ) => switch (status.state) {
    TerminalProgramState.working => _TmuxWindowStatusVisual(
      icon: Icons.play_arrow,
      foregroundColor: scheme.onPrimaryContainer,
      backgroundColor: scheme.primaryContainer,
    ),
    TerminalProgramState.blocked => _TmuxWindowStatusVisual(
      icon: switch (status.kind) {
        TerminalProgramBlockedKind.permission => Icons.pending_actions,
        TerminalProgramBlockedKind.question => Icons.help_outline,
        TerminalProgramBlockedKind.auth => Icons.key,
        null => Icons.front_hand_outlined,
      },
      foregroundColor: scheme.onErrorContainer,
      backgroundColor: scheme.errorContainer,
    ),
    TerminalProgramState.done => _TmuxWindowStatusVisual(
      icon: Icons.check_circle_outline,
      foregroundColor: scheme.onTertiaryContainer,
      backgroundColor: scheme.tertiaryContainer,
    ),
    TerminalProgramState.error => _TmuxWindowStatusVisual(
      icon: Icons.error_outline,
      foregroundColor: scheme.onErrorContainer,
      backgroundColor: scheme.errorContainer,
    ),
    TerminalProgramState.idle => _TmuxWindowStatusVisual(
      icon: Icons.hourglass_bottom,
      foregroundColor: scheme.onTertiaryContainer,
      backgroundColor: scheme.tertiaryContainer,
    ),
  };
}

class _TmuxWindowStatusBadgeState extends State<TmuxWindowStatusBadge> {
  Timer? _idleRefreshTimer;

  @override
  void initState() {
    super.initState();
    _updateIdleRefreshTimer();
  }

  @override
  void didUpdateWidget(covariant TmuxWindowStatusBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.window == widget.window) return;
    _updateIdleRefreshTimer();
  }

  @override
  void dispose() {
    _idleRefreshTimer?.cancel();
    super.dispose();
  }

  void _updateIdleRefreshTimer() {
    _idleRefreshTimer?.cancel();
    if (!widget.window.needsLocalIdleRefresh) {
      _idleRefreshTimer = null;
      return;
    }
    _idleRefreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (!widget.window.needsLocalIdleRefresh) {
        _idleRefreshTimer?.cancel();
        _idleRefreshTimer = null;
      }
      setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visual = TmuxWindowStatusBadge._statusVisual(theme, widget.window);

    final reportedStatus = widget.window.reportedStatus;
    return MuxWindowStatusBadge(
      semanticsLabel: reportedStatus == null
          ? 'terminal window ${widget.window.statusLabel}'
          : 'terminal window ${reportedStatus.semanticsLabel}',
      label: widget.window.statusLabel,
      icon: visual.icon,
      foregroundColor: visual.foregroundColor,
      backgroundColor: visual.backgroundColor,
    );
  }
}

class _TmuxWindowStatusVisual {
  const _TmuxWindowStatusVisual({
    required this.icon,
    required this.foregroundColor,
    required this.backgroundColor,
  });

  final IconData icon;
  final Color foregroundColor;
  final Color backgroundColor;
}

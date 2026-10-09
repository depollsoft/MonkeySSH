/// Worktree handling for host auto-connect agent launches.
///
/// The terminal calls [prepareTerminalAgentWorktreeLaunch] before it builds
/// the launch command, then settles the result with
/// [TerminalAgentWorktreeLaunch.abandon] or
/// [TerminalAgentWorktreeLaunch.launched] once it knows whether the command
/// reached the host.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/models/agent_launch_preset.dart';
import '../../../domain/services/agent_worktree_launcher.dart';
import '../../../domain/services/agent_worktree_service.dart';
import '../../../domain/services/diagnostics_log_service.dart';
import '../../../domain/services/ssh_service.dart';

/// A preset launch, with the worktree created for it when it needed one.
final class TerminalAgentWorktreeLaunch {
  /// Creates a launch.
  const TerminalAgentWorktreeLaunch({required this.preset, this.worktree});

  /// Preset to build the launch command from; its working directory is the
  /// new worktree when one was created.
  final AgentLaunchPreset preset;

  /// Worktree created for this launch, if any.
  final AgentWorktreeLaunch? worktree;

  /// Rolls the worktree back because the launch command never reached the
  /// host. Safe to call after the terminal has gone away.
  void abandon() => worktree?.abandon();

  /// Records that the launch command reached the host; see
  /// [AgentWorktreeLaunch.launched].
  void launched({Future<Iterable<String?>> Function()? windowDirectories}) =>
      worktree?.launched(windowDirectories: windowDirectories);
}

/// Creates the worktree [preset] asks for before its agent starts.
///
/// [sessionExists] reports whether the remote window session the preset
/// attaches to is already running. Attaching to a running session does not
/// start the agent again, so no worktree is created then; the session keeps
/// the windows (and worktrees) it already has, which is also how a MonkeyMux
/// update restore returns to a recorded worktree without recreating it.
///
/// Returns null when the launch must not go ahead because the worktree could
/// not be created; the user has been told why. Starting the agent in the
/// shared checkout instead would silently drop the isolation the preset asks
/// for.
Future<TerminalAgentWorktreeLaunch?> prepareTerminalAgentWorktreeLaunch({
  required BuildContext context,
  required WidgetRef ref,
  required SshSession session,
  required AgentLaunchPreset preset,
  Future<bool> Function()? sessionExists,
}) async {
  if (!preset.launchesInNewWorktree) {
    return TerminalAgentWorktreeLaunch(preset: preset);
  }
  if (sessionExists != null) {
    var exists = false;
    try {
      exists = await sessionExists();
    } on Object catch (error) {
      // An unknown answer creates the worktree; if the attach then joins a
      // running session, the launch check rolls the unused worktree back.
      DiagnosticsLogService.instance.debug(
        'agent.worktree',
        'session_probe_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
    }
    if (exists) {
      DiagnosticsLogService.instance.info(
        'agent.worktree',
        'skipped_running_session',
        fields: {'connectionId': session.connectionId},
      );
      return TerminalAgentWorktreeLaunch(preset: preset);
    }
  }
  try {
    final launch = await ref
        .read(agentWorktreeLauncherProvider)
        .begin(
          SshAgentWorktreeShell(session),
          hostId: session.hostId,
          preset: preset,
          windowsHost: session.remoteIsWindows,
        );
    return TerminalAgentWorktreeLaunch(
      preset: preset.launchingIn(launch.record.startDirectory),
      worktree: launch,
    );
  } on AgentWorktreeException catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Agent not started: ${error.message}'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    return null;
  }
}

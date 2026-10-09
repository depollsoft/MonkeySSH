/// New-session sheet pieces for custom agents: the pre-launch environment
/// check and the agent's own session list (ACP `session/list`).
///
/// Session titles and directories reported by the agent are user content;
/// they are shown but never logged.
library;

import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../domain/models/acp_protocol.dart';
import '../../domain/models/acp_provider.dart';
import '../../domain/services/acp_custom_provider_host_service.dart';
import '../../domain/services/ssh_service.dart';
import 'acp_session_presentation.dart';

/// Checks that the environment variables [definition] needs are set on the
/// host behind [session].
///
/// Returns a user-facing message naming the unset variables, or `null` when
/// the launch can go ahead. A check that cannot run does not block the
/// launch: the agent then reports its own error.
Future<String?> checkAcpCustomAgentEnvironment(
  WidgetRef ref,
  SshSession session,
  AcpCustomProviderDefinition definition,
) async {
  if (definition.environmentVariableNames.isEmpty) return null;
  final unset = await ref
      .read(acpCustomProviderHostServiceProvider)
      .findUnsetEnvironmentVariables(session, definition);
  if (unset == null || unset.isEmpty) return null;
  final names = unset.join(', ');
  return unset.length == 1
      ? '$names is not set on this host. Export it from your shell profile, '
            'then start the session again.'
      : '$names are not set on this host. Export them from your shell '
            'profile, then start the session again.';
}

/// Lets the user resume one of a custom agent's own sessions, listed on
/// demand through ACP `session/list`.
class AcpCustomAgentSessions extends StatefulWidget {
  /// Creates the section.
  const AcpCustomAgentSessions({
    required this.definition,
    required this.hostId,
    required this.enabled,
    required this.selected,
    required this.onSelected,
    required this.loadSessions,
    super.key,
  });

  /// The selected custom agent.
  final AcpCustomProviderDefinition definition;

  /// The selected host.
  final int hostId;

  /// Whether the controls accept input.
  final bool enabled;

  /// The session chosen for resume, if any.
  final AcpSessionInfo? selected;

  /// Called when the user picks a session, or clears the choice with `null`.
  final ValueChanged<AcpSessionInfo?> onSelected;

  /// Connects when needed and lists the agent's sessions, or returns `null`
  /// when the host could not be reached.
  final Future<AcpCustomAgentSessionListing?> Function() loadSessions;

  @override
  State<AcpCustomAgentSessions> createState() => _AcpCustomAgentSessionsState();
}

class _AcpCustomAgentSessionsState extends State<AcpCustomAgentSessions> {
  var _loading = false;
  AcpCustomAgentSessionListing? _listing;
  var _attempted = false;
  // Bumped whenever the agent or host changes, so a lookup that finishes
  // late is ignored instead of leaving this section loading.
  var _generation = 0;

  @override
  void didUpdateWidget(AcpCustomAgentSessions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.definition.id != widget.definition.id ||
        oldWidget.hostId != widget.hostId) {
      _generation++;
      _listing = null;
      _attempted = false;
      _loading = false;
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _attempted = true;
    });
    final listing = await widget.loadSessions();
    if (!mounted || generation != _generation) return;
    setState(() {
      _loading = false;
      _listing = listing;
    });
    // Keep the chosen session only if the new list still has it, as the
    // new list's entry; otherwise go back to starting a new session.
    final selected = widget.selected;
    if (selected != null) {
      final match = listing?.sessions.firstWhereOrNull(
        (session) => session.sessionId == selected.sessionId,
      );
      if (!identical(match, selected)) widget.onSelected(match);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final listing = _listing;
    final sessions = listing?.sessions ?? const <AcpSessionInfo>[];
    final message = switch (listing?.status) {
      null when _attempted && !_loading =>
        'Couldn’t reach the host to list sessions.',
      null => null,
      AcpCustomAgentSessionListStatus.listed when sessions.isEmpty =>
        'This agent has no saved sessions.',
      AcpCustomAgentSessionListStatus.listed => null,
      AcpCustomAgentSessionListStatus.unsupportedAgent =>
        'This agent doesn’t list its sessions.',
      AcpCustomAgentSessionListStatus.unsupportedHost =>
        'Listing sessions isn’t available on Windows hosts yet.',
      AcpCustomAgentSessionListStatus.notApproved =>
        'Approve this agent before listing its sessions.',
      AcpCustomAgentSessionListStatus.failed =>
        'Couldn’t list sessions. Check that the agent starts on this host.',
    };
    final canRetry =
        !_loading &&
        (listing == null ||
            listing.status == AcpCustomAgentSessionListStatus.failed ||
            listing.status == AcpCustomAgentSessionListStatus.listed);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: FluttyTheme.spacingMd),
        Text('Agent sessions on this host', style: theme.textTheme.labelLarge),
        if (sessions.isNotEmpty)
          RadioGroup<AcpSessionInfo?>(
            groupValue: sessions.firstWhereOrNull(
              (session) => session.sessionId == widget.selected?.sessionId,
            ),
            onChanged: (value) {
              if (widget.enabled) widget.onSelected(value);
            },
            child: Column(
              children: [
                // Tapping the chosen session again goes back to starting a
                // new one, so this list adds no second "new session" row.
                for (final session in sessions)
                  RadioListTile<AcpSessionInfo?>(
                    key: ValueKey('custom-agent-session-${session.sessionId}'),
                    value: session,
                    enabled: widget.enabled,
                    toggleable: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      session.title?.trim().isNotEmpty ?? false
                          ? session.title!.trim()
                          : 'Session in ${acpCwdSummary(session.cwd)}',
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      _subtitle(session),
                      style: FluttyTheme.monoStyle,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
        if (message != null)
          Padding(
            padding: const EdgeInsets.only(top: FluttyTheme.spacingXs),
            child: Text(message, style: muted),
          ),
        if (canRetry)
          TextButton.icon(
            key: const ValueKey('custom-agent-find-sessions'),
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.onSurfaceVariant,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onPressed: widget.enabled ? () => unawaited(_load()) : null,
            icon: const Icon(Icons.history, size: 18),
            label: Text(listing == null ? 'Find sessions' : 'Refresh'),
          )
        else if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: FluttyTheme.spacingSm),
            child: LinearProgressIndicator(),
          ),
      ],
    );
  }

  String _subtitle(AcpSessionInfo session) {
    final updated = acpSessionInfoUpdatedAt(session);
    final known = updated.millisecondsSinceEpoch > 0;
    return [
      acpCwdSummary(session.cwd),
      if (known) acpRelativeTime(updated),
    ].join(' · ');
  }
}

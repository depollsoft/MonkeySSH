/// Session switching surfaces for the Agent workspace.
///
/// Provides a one-handed bottom sheet (mobile app bar) and an inline rail
/// (wide layouts) that list active, detached, and recent ACP sessions across
/// hosts and providers. Selecting a session navigates to its chat; a recent,
/// not-yet-live session is reconnected by the chat screen on open. Free users
/// can switch by replacement; the replacement itself is enforced by the
/// session manager, not just the UI.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../domain/models/acp_recent_session.dart';
import '../../domain/models/acp_session_keys.dart';
import '../../domain/models/acp_session_state.dart';
import '../../domain/services/acp_session_manager.dart';
import '../../domain/services/local_notification_service.dart';
import 'acp_new_session_sheet.dart';
import 'acp_session_presentation.dart';

/// A switcher entry: either a tracked live/detached session or a recent ref.
@immutable
class AcpSwitcherEntry {
  /// Creates a switcher entry from a tracked session.
  const AcpSwitcherEntry.session(this.session) : recent = null;

  /// Creates a switcher entry from a recent (not tracked) reference.
  const AcpSwitcherEntry.recent(this.recent) : session = null;

  /// The tracked session, when this entry is live/detached.
  final AcpSessionState? session;

  /// The recent reference, when this entry is not currently tracked.
  final AcpRecentSessionRef? recent;

  /// The composite key value for this entry.
  String get keyValue => session?.key.value ?? recent!.key.value;

  /// The one-line title for this entry.
  String get title => session != null
      ? acpSessionDisplayTitle(session!)
      : (recent!.title?.trim().isNotEmpty ?? false
            ? recent!.title!
            : 'Session ${acpCwdSummary(recent!.cwd)}');
}

/// Merges tracked sessions with recent refs (deduped by key) into ordered
/// switcher entries, most recently active first.
List<AcpSwitcherEntry> buildAcpSwitcherEntries({
  required List<AcpSessionState> sessions,
  required List<AcpRecentSessionRef> recents,
}) {
  final trackedKeys = {for (final s in sessions) s.key.value};
  final entries =
      <AcpSwitcherEntry>[
        for (final session in sessions) AcpSwitcherEntry.session(session),
        for (final recent in recents)
          if (!trackedKeys.contains(recent.key.value))
            AcpSwitcherEntry.recent(recent),
      ]..sort((a, b) {
        final aTime = a.session?.lastActivityAt ?? a.recent!.lastActivityAt;
        final bTime = b.session?.lastActivityAt ?? b.recent!.lastActivityAt;
        return bTime.compareTo(aTime);
      });
  return entries;
}

/// Orders live native ACP sessions like mux windows, independent of activity.
///
/// Window numbers must not reshuffle merely because a background agent emits
/// output, so creation time and the stable session key are used as tie-breaks.
List<AcpSwitcherEntry> buildAcpMuxWindowEntries(
  List<AcpSessionState> sessions,
) =>
    <AcpSwitcherEntry>[
      for (final session in sessions) AcpSwitcherEntry.session(session),
    ]..sort((a, b) {
      final created = a.session!.createdAt.compareTo(b.session!.createdAt);
      return created != 0 ? created : a.keyValue.compareTo(b.keyValue);
    });

/// Navigates to the chat for [key], replacing the current chat route.
void _openChat(BuildContext context, AcpSessionKey key) {
  final location = buildAgentChatLocation(
    hostId: key.hostId,
    providerId: key.providerId,
    bridgeId: key.bridgeId,
    acpSessionId: key.acpSessionId,
  );
  context.replace(location);
}

/// Opens the session switcher bottom sheet.
Future<void> showAcpSessionSwitcher(
  BuildContext context, {
  AcpSessionKey? currentKey,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (context) => _SessionSwitcherSheet(currentKey: currentKey),
);

class _SessionSwitcherSheet extends ConsumerStatefulWidget {
  const _SessionSwitcherSheet({this.currentKey});

  final AcpSessionKey? currentKey;

  @override
  ConsumerState<_SessionSwitcherSheet> createState() =>
      _SessionSwitcherSheetState();
}

class _SessionSwitcherSheetState extends ConsumerState<_SessionSwitcherSheet> {
  late Future<List<AcpRecentSessionRef>> _recents;

  @override
  void initState() {
    super.initState();
    _recents = ref.read(acpSessionManagerProvider).loadRecentSessions();
  }

  Future<void> _newSession() async {
    final navigator = Navigator.of(context);
    final key = await showAcpNewSessionSheet(context);
    if (!mounted) {
      return;
    }
    navigator.pop();
    if (key != null) {
      _openChat(context, key);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final managerState = ref
        .watch(acpSessionManagerStateProvider)
        .asData
        ?.value;
    final sessions = managerState?.sessions ?? const <AcpSessionState>[];
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FluttyTheme.spacingMd,
        0,
        FluttyTheme.spacingMd,
        FluttyTheme.spacingLg,
      ),
      child: FutureBuilder<List<AcpRecentSessionRef>>(
        future: _recents,
        builder: (context, snapshot) {
          final entries = buildAcpSwitcherEntries(
            sessions: sessions,
            recents: snapshot.data ?? const <AcpRecentSessionRef>[],
          );
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: FluttyTheme.spacingXs,
                ),
                child: Text(
                  'agent sessions',
                  style: FluttyTheme.displayMono(
                    fontSize: 18,
                    color: colorScheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(height: FluttyTheme.spacingSm),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final entry in entries)
                      AcpSessionTile(
                        entry: entry,
                        selected: entry.keyValue == widget.currentKey?.value,
                        onTap: () {
                          final navigator = Navigator.of(context);
                          final key = entry.session?.key ?? entry.recent!.key;
                          navigator.pop();
                          _openChat(context, key);
                        },
                      ),
                  ],
                ),
              ),
              const SizedBox(height: FluttyTheme.spacingSm),
              FilledButton.icon(
                onPressed: _newSession,
                icon: const Icon(Icons.add),
                label: const Text('New session'),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A single session row shared by the switcher sheet and the wide rail.
class AcpSessionTile extends StatelessWidget {
  /// Creates a session tile.
  const AcpSessionTile({
    required this.entry,
    required this.onTap,
    this.selected = false,
    super.key,
  });

  /// The entry to render.
  final AcpSwitcherEntry entry;

  /// Whether this entry is the current session.
  final bool selected;

  /// Tap handler.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final session = entry.session;
    final status = session != null
        ? acpSessionActivityDisplay(session)
        : const AcpStatusDisplay(
            label: 'recent',
            icon: Icons.history,
            tone: AcpStatusTone.neutral,
          );
    final cwd = session?.cwd ?? entry.recent?.cwd;
    final activity = session?.lastActivityAt ?? entry.recent?.lastActivityAt;
    return Semantics(
      selected: selected,
      button: true,
      child: ListTile(
        selected: selected,
        onTap: onTap,
        minVerticalPadding: 12,
        leading: Icon(
          status.icon,
          color: acpStatusColor(colorScheme, status.tone),
        ),
        title: Text(entry.title, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${entry.session?.providerLabel ?? ''} · ${acpCwdSummary(cwd)}'
          '${activity != null ? ' · ${acpRelativeTime(activity)}' : ''}',
          style: FluttyTheme.monoStyle.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Text(
          status.label,
          style: FluttyTheme.monoStyle.copyWith(
            color: acpStatusColor(colorScheme, status.tone),
          ),
        ),
      ),
    );
  }
}

/// The persistent session rail shown alongside the conversation on wide
/// layouts.
class AcpSessionRail extends ConsumerStatefulWidget {
  /// Creates a session rail.
  const AcpSessionRail({required this.currentKey, super.key});

  /// The currently open session.
  final AcpSessionKey currentKey;

  @override
  ConsumerState<AcpSessionRail> createState() => _AcpSessionRailState();
}

class _AcpSessionRailState extends ConsumerState<AcpSessionRail> {
  late Future<List<AcpRecentSessionRef>> _recents;

  @override
  void initState() {
    super.initState();
    _recents = ref.read(acpSessionManagerProvider).loadRecentSessions();
  }

  Future<void> _newSession() async {
    final key = await showAcpNewSessionSheet(context);
    if (key != null && mounted) {
      _openChat(context, key);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final managerState = ref
        .watch(acpSessionManagerStateProvider)
        .asData
        ?.value;
    final sessions = managerState?.sessions ?? const <AcpSessionState>[];
    return Container(
      width: 300,
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: colorScheme.outline.withValues(alpha: 0.24)),
        ),
      ),
      child: Material(
        color: colorScheme.surface,
        child: SafeArea(
          right: false,
          child: FutureBuilder<List<AcpRecentSessionRef>>(
            future: _recents,
            builder: (context, snapshot) {
              final entries = buildAcpSwitcherEntries(
                sessions: sessions,
                recents: snapshot.data ?? const <AcpRecentSessionRef>[],
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      FluttyTheme.spacingMd,
                      FluttyTheme.spacingMd,
                      FluttyTheme.spacingMd,
                      FluttyTheme.spacingSm,
                    ),
                    child: Text(
                      'sessions',
                      style: FluttyTheme.displayMono(
                        fontSize: 16,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final entry in entries)
                          AcpSessionTile(
                            entry: entry,
                            selected: entry.keyValue == widget.currentKey.value,
                            onTap: () => _openChat(
                              context,
                              entry.session?.key ?? entry.recent!.key,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(FluttyTheme.spacingMd),
                    child: FilledButton.icon(
                      onPressed: _newSession,
                      icon: const Icon(Icons.add),
                      label: const Text('New session'),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

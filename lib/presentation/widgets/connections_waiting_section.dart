/// The "waiting on you" section at the top of the Connections tab.
///
/// Lists every native agent session, on any connected host, that is blocked
/// until the user answers: a permission request, a question, a sign-in, or a
/// request the host reports for a session with no attached client. Each row
/// opens that exact session, where the request is shown with its full tool
/// details. Answers are never given from this list.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../providers/connection_attention_provider.dart';
import 'acp_session_presentation.dart';
import 'agent_tool_icon.dart';
import 'attention_presentation.dart';

/// Opens a route for a waiting row.
typedef WaitingOnYouOpener = void Function(
  BuildContext context,
  String location,
);

void _pushLocation(BuildContext context, String location) {
  unawaited(GoRouter.of(context).push<void>(location));
}

/// Section listing native sessions waiting on the user. Renders nothing when
/// no session is waiting or the surface is offstage.
class ConnectionsWaitingSection extends ConsumerStatefulWidget {
  /// Creates the section.
  const ConnectionsWaitingSection({
    this.onOpen = _pushLocation,
    this.now,
    super.key,
  });

  /// Navigates to a row's session.
  final WaitingOnYouOpener onOpen;

  /// Clock override for tests.
  final DateTime Function()? now;

  @override
  ConsumerState<ConnectionsWaitingSection> createState() =>
      _ConnectionsWaitingSectionState();
}

class _ConnectionsWaitingSectionState
    extends ConsumerState<ConnectionsWaitingSection> {
  Timer? _ageTicker;

  @override
  void dispose() {
    _ageTicker?.cancel();
    super.dispose();
  }

  /// Keeps "5m ago" labels honest while rows are on screen.
  void _syncAgeTicker({required bool active}) {
    if (!active) {
      _ageTicker?.cancel();
      _ageTicker = null;
      return;
    }
    _ageTicker ??= Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!attentionSurfaceVisible(context)) {
      _syncAgeTicker(active: false);
      return const SizedBox.shrink();
    }
    final items = ref.watch(waitingOnYouProvider).items;
    _syncAgeTicker(active: items.isNotEmpty);
    if (items.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final now = widget.now?.call() ?? DateTime.now();
    return Padding(
      key: const ValueKey('connections-waiting-section'),
      padding: const EdgeInsets.fromLTRB(
        FluttyTheme.spacingMd,
        FluttyTheme.spacingSm,
        FluttyTheme.spacingMd,
        FluttyTheme.spacingSm,
      ),
      child: Material(
        color: scheme.surfaceContainerHighest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(FluttyTheme.radiusMd),
          side: BorderSide(color: scheme.outline),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              container: true,
              header: true,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
                child: Row(
                  children: [
                    Text(
                      'waiting on you',
                      style: FluttyTheme.displayMono(
                        fontSize: 15,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(width: FluttyTheme.spacingSm),
                    Text(
                      '${items.length}',
                      semanticsLabel: items.length == 1
                          ? '1 session'
                          : '${items.length} sessions',
                      style: FluttyTheme.displayMono(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            for (var index = 0; index < items.length; index++) ...[
              if (index > 0)
                Divider(
                  height: 1,
                  thickness: 1,
                  indent: 14,
                  endIndent: 14,
                  color: scheme.outline,
                ),
              WaitingOnYouRow(
                key: ValueKey('waiting-on-you-${items[index].key.value}'),
                item: items[index],
                now: now,
                onOpen: () => widget.onOpen(context, items[index].location),
              ),
            ],
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}

/// One waiting session. The whole row is the Open action.
class WaitingOnYouRow extends StatelessWidget {
  /// Creates a row.
  const WaitingOnYouRow({
    required this.item,
    required this.now,
    required this.onOpen,
    super.key,
  });

  /// Session to show.
  final WaitingOnYouItem item;

  /// Reference time for the age label.
  final DateTime now;

  /// Opens the session.
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final reason = item.reason;
    final (reasonForeground, reasonBackground) = attentionToneColors(
      scheme,
      reason.tone,
    );
    final age = acpRelativeTime(item.since, now: now);
    // Host and age first: they decide which to open, and long lines elide
    // from the end.
    final details = [
      item.hostLabel,
      age,
      if (item.providerLabel != item.title) item.providerLabel,
      ?item.cwdSummary,
    ].join(' · ');
    return Semantics(
      container: true,
      button: true,
      label:
          'Open ${item.title}. ${item.providerLabel} on ${item.hostLabel} '
          '${reason.description}, $age.',
      excludeSemantics: true,
      onTap: onOpen,
      child: InkWell(
        onTap: onOpen,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
            child: Row(
              children: [
                AgentToolIcon(tool: item.tool, color: scheme.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          DecoratedBox(
                            key: ValueKey('waiting-reason-${reason.name}'),
                            decoration: BoxDecoration(
                              color: reasonBackground,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    reason.icon,
                                    size: 12,
                                    color: reasonForeground,
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    reason.label,
                                    style: FluttyTheme.monoStyle.copyWith(
                                      fontSize: 11,
                                      height: 1.2,
                                      fontWeight: FontWeight.w600,
                                      color: reasonForeground,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              details,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: FluttyTheme.monoStyle.copyWith(
                                fontSize: 11,
                                height: 1.2,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: scheme.outline),
                    borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Open',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: scheme.onSurface,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Icon(
                          Icons.chevron_right,
                          size: 16,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

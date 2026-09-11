import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../domain/models/tmux_state.dart';
import '../../domain/services/agent_session_discovery_service.dart';
import 'acp_session_presentation.dart';
import 'agent_tool_icon.dart';

/// Derived UI state for a discovered-session provider row.
class AiSessionProviderEntry {
  /// Creates a new [AiSessionProviderEntry].
  const AiSessionProviderEntry({
    required this.toolName,
    required this.hasSessions,
    required this.wasAttempted,
    required this.hasFailure,
    required this.isLoading,
  });

  /// Provider display name.
  final String toolName;

  /// Whether the provider currently has at least one discovered session.
  final bool hasSessions;

  /// Whether discovery finished for this provider in the current pass.
  final bool wasAttempted;

  /// Whether discovery failed for this provider.
  final bool hasFailure;

  /// Whether this provider is still pending during the current load.
  final bool isLoading;

  /// Full status text for roomy list tiles.
  String get statusLabel {
    if (hasFailure) return 'Could not load recent sessions';
    if (hasSessions) return 'Recent sessions available';
    if (isLoading) return 'Loading recent sessions…';
    if (wasAttempted) return 'No recent sessions for this project';
    return 'Tap to view recent sessions';
  }

  /// Compact status text for tighter provider rows.
  String get compactStatusLabel {
    if (hasFailure) return 'error';
    if (hasSessions) return 'ready';
    if (isLoading) return 'loading';
    if (wasAttempted) return 'no recent';
    return '';
  }
}

/// A discovered-session provider row shared by the mux pickers.
class AiSessionProviderTile extends StatelessWidget {
  /// Creates a provider tile with the surrounding picker's spacing.
  const AiSessionProviderTile({
    required this.provider,
    required this.onTap,
    required this.visualDensity,
    required this.contentPadding,
    required this.minLeadingWidth,
    required this.iconColor,
    this.iconSize = 20,
    super.key,
  });

  /// Current provider status.
  final AiSessionProviderEntry provider;

  /// Opens or retries discovery for this provider.
  final VoidCallback onTap;

  /// Tile density.
  final VisualDensity visualDensity;

  /// Padding matching the surrounding rows.
  final EdgeInsetsGeometry contentPadding;

  /// Space reserved for the provider icon.
  final double minLeadingWidth;

  /// Provider icon color.
  final Color iconColor;

  /// Provider icon size.
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      visualDensity: visualDensity,
      minVerticalPadding: 2,
      contentPadding: contentPadding,
      horizontalTitleGap: 12,
      minLeadingWidth: minLeadingWidth,
      leading: AgentToolIcon(
        toolName: provider.toolName,
        size: iconSize,
        color: iconColor,
      ),
      title: Text(
        provider.toolName,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: provider.hasFailure
              ? theme.colorScheme.error
              : theme.colorScheme.onSurface,
        ),
      ),
      subtitle: Text(
        provider.statusLabel,
        style: theme.textTheme.bodySmall?.copyWith(
          color: provider.hasFailure
              ? theme.colorScheme.error
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: provider.isLoading && !provider.hasSessions
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator.adaptive(strokeWidth: 2),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (provider.isLoading) ...[
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                  ),
                  const SizedBox(width: 4),
                ],
                Icon(
                  Icons.chevron_right,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
      onTap: onTap,
    );
  }
}

/// Loader callback used by [AiSessionPickerDialog].
typedef AiSessionLoader =
    Stream<DiscoveredSessionsResult> Function(int maxSessions);

/// Loader callback used by [AiSessionProviderList].
typedef AiSessionProviderLoader =
    Stream<DiscoveredSessionsResult> Function(int maxSessions);

/// Builder callback used by [AiSessionProviderList].
typedef AiSessionProviderEntryBuilder =
    Widget Function(BuildContext context, AiSessionProviderEntry provider);

/// Stable provider rows that live-update as each provider finishes loading.
class AiSessionProviderList extends StatefulWidget {
  /// Creates a new [AiSessionProviderList].
  const AiSessionProviderList({
    required this.orderedTools,
    required this.loadSessions,
    required this.itemBuilder,
    this.initialMaxSessions = 6,
    super.key,
  });

  /// Ordered provider names to render.
  final Iterable<String> orderedTools;

  /// Loads recent sessions for all rendered providers.
  final AiSessionProviderLoader loadSessions;

  /// Builds each provider row.
  final AiSessionProviderEntryBuilder itemBuilder;

  /// Initial number of sessions to request per provider row.
  final int initialMaxSessions;

  @override
  State<AiSessionProviderList> createState() => _AiSessionProviderListState();
}

class _AiSessionProviderListState extends State<AiSessionProviderList> {
  final Map<String, ValueNotifier<AiSessionProviderEntry>> _entryNotifiers =
      <String, ValueNotifier<AiSessionProviderEntry>>{};
  final Map<String, bool> _currentLoadHasSessions = <String, bool>{};
  // ignore: cancel_subscriptions
  StreamSubscription<DiscoveredSessionsResult>? _subscription;
  late List<String> _orderedTools;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _orderedTools = widget.orderedTools.toList(growable: false);
    _disposeObsoleteNotifiers();
    _startLoadingProviders();
  }

  @override
  void didUpdateWidget(covariant AiSessionProviderList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final orderedTools = widget.orderedTools.toList(growable: false);
    if (_sameOrderedTools(_orderedTools, orderedTools) &&
        oldWidget.initialMaxSessions == widget.initialMaxSessions) {
      _orderedTools = orderedTools;
      return;
    }

    if (_sameToolSet(_orderedTools, orderedTools) &&
        oldWidget.initialMaxSessions == widget.initialMaxSessions) {
      return;
    }

    _orderedTools = orderedTools;
    unawaited(_restartLoadingProviders());
  }

  @override
  void dispose() {
    _loadGeneration++;
    final subscription = _subscription;
    _subscription = null;
    unawaited(subscription?.cancel());
    for (final notifier in _entryNotifiers.values) {
      notifier.dispose();
    }
    super.dispose();
  }

  bool _sameOrderedTools(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  bool _sameToolSet(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    return a.toSet().containsAll(b);
  }

  Future<void> _restartLoadingProviders() async {
    await _cancelSubscriptions();
    if (!mounted) return;
    _disposeObsoleteNotifiers();
    for (final toolName in _orderedTools) {
      final current = _entryForTool(toolName);
      _setEntry(
        toolName,
        hasSessions: current.hasSessions,
        wasAttempted: current.wasAttempted,
        hasFailure: current.hasFailure,
        isLoading: false,
      );
    }
    _startLoadingProviders();
  }

  Future<void> _cancelSubscriptions() async {
    _loadGeneration++;
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
  }

  void _disposeObsoleteNotifiers() {
    final orderedToolSet = _orderedTools.toSet();
    final obsoleteToolNames = _entryNotifiers.keys
        .where((toolName) => !orderedToolSet.contains(toolName))
        .toList(growable: false);
    for (final toolName in obsoleteToolNames) {
      _currentLoadHasSessions.remove(toolName);
      _entryNotifiers.remove(toolName)?.dispose();
    }
  }

  AiSessionProviderEntry _createInitialEntry(String toolName) =>
      AiSessionProviderEntry(
        toolName: toolName,
        wasAttempted: false,
        hasFailure: false,
        isLoading: false,
        hasSessions: false,
      );

  ValueNotifier<AiSessionProviderEntry> _entryNotifier(String toolName) =>
      _entryNotifiers.putIfAbsent(
        toolName,
        () => ValueNotifier<AiSessionProviderEntry>(
          _createInitialEntry(toolName),
        ),
      );

  AiSessionProviderEntry _entryForTool(String toolName) =>
      _entryNotifier(toolName).value;

  bool _sameEntry(AiSessionProviderEntry a, AiSessionProviderEntry b) =>
      a.toolName == b.toolName &&
      a.hasSessions == b.hasSessions &&
      a.wasAttempted == b.wasAttempted &&
      a.hasFailure == b.hasFailure &&
      a.isLoading == b.isLoading;

  void _setEntry(
    String toolName, {
    required bool hasSessions,
    required bool wasAttempted,
    required bool hasFailure,
    required bool isLoading,
  }) {
    final notifier = _entryNotifier(toolName);
    final next = AiSessionProviderEntry(
      toolName: toolName,
      wasAttempted: wasAttempted,
      hasFailure: hasFailure,
      isLoading: isLoading,
      hasSessions: hasSessions,
    );
    if (_sameEntry(notifier.value, next)) {
      return;
    }
    notifier.value = next;
  }

  void _startLoadingProviders() {
    final generation = _loadGeneration;
    for (final toolName in _orderedTools) {
      _currentLoadHasSessions[toolName] = false;
      final current = _entryForTool(toolName);
      final hasVisibleState =
          current.hasSessions || current.wasAttempted || current.hasFailure;
      if (!hasVisibleState) {
        _setEntry(
          toolName,
          hasSessions: false,
          wasAttempted: false,
          hasFailure: false,
          isLoading: true,
        );
      }
    }
    _subscription = widget
        .loadSessions(widget.initialMaxSessions)
        .listen(
          (result) {
            if (!mounted || generation != _loadGeneration) return;
            _applyDiscoveryResult(result);
          },
          onError: (Object _) {
            if (!mounted || generation != _loadGeneration) return;
            for (final toolName in _orderedTools) {
              final current = _entryForTool(toolName);
              _setEntry(
                toolName,
                hasSessions:
                    current.hasSessions ||
                    (_currentLoadHasSessions[toolName] ?? false),
                wasAttempted: true,
                hasFailure: true,
                isLoading: false,
              );
              _currentLoadHasSessions.remove(toolName);
            }
            _subscription = null;
          },
          onDone: () {
            if (!mounted || generation != _loadGeneration) return;
            for (final toolName in _orderedTools) {
              final current = _entryForTool(toolName);
              _setEntry(
                toolName,
                hasSessions:
                    current.hasSessions ||
                    (_currentLoadHasSessions[toolName] ?? false),
                wasAttempted: true,
                hasFailure: current.hasFailure,
                isLoading: false,
              );
              _currentLoadHasSessions.remove(toolName);
            }
            _subscription = null;
          },
          cancelOnError: true,
        );
  }

  void _applyDiscoveryResult(DiscoveredSessionsResult result) {
    final sessionsByTool = result.sessionTools;
    final attemptedTools = result.attemptedTools;
    final failedTools = result.failedTools;

    for (final toolName in _orderedTools) {
      final sawSessions = sessionsByTool.contains(toolName);
      if (sawSessions) {
        _currentLoadHasSessions[toolName] = true;
      }
      final wasAttempted =
          attemptedTools.contains(toolName) ||
          failedTools.contains(toolName) ||
          sawSessions;
      if (!wasAttempted) continue;

      final current = _entryForTool(toolName);
      _setEntry(
        toolName,
        hasSessions:
            current.hasSessions || (_currentLoadHasSessions[toolName] ?? false),
        wasAttempted: true,
        hasFailure: failedTools.contains(toolName),
        isLoading: false,
      );
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final toolName in _orderedTools)
        RepaintBoundary(
          child: ValueListenableBuilder<AiSessionProviderEntry>(
            key: ValueKey<String>('ai-session-provider-$toolName'),
            valueListenable: _entryNotifier(toolName),
            builder: (context, provider, _) =>
                widget.itemBuilder(context, provider),
          ),
        ),
    ],
  );
}

/// Shows a dialog for picking one of a provider's recent sessions.
Future<ToolSessionInfo?> showAiSessionPickerDialog({
  required BuildContext context,
  required String toolName,
  required AiSessionLoader loadSessions,
  int initialMaxSessions = 12,
  int sessionFetchStep = 12,
  ValueChanged<ToolSessionInfo>? onSessionLongPress,
}) => showDialog<ToolSessionInfo>(
  context: context,
  builder: (context) => AiSessionPickerDialog(
    toolName: toolName,
    loadSessions: loadSessions,
    initialMaxSessions: initialMaxSessions,
    sessionFetchStep: sessionFetchStep,
    onSessionLongPress: onSessionLongPress,
  ),
);

/// Builds a compact, identifiable subtitle for one recent session.
///
/// Pi titles commonly come from the first prompt and can repeat across
/// worktrees/subtrees, so include the final cwd segment before recency. Other
/// providers retain the existing time/tool fallback.
String aiSessionSubtitle(ToolSessionInfo session) {
  final updated = session.lastUpdatedLabel;
  if (session.toolName == 'Pi' &&
      (session.workingDirectory?.trim().isNotEmpty ?? false)) {
    final directory = acpCwdSummary(session.workingDirectory);
    return updated.isEmpty ? directory : '$directory · $updated';
  }
  return updated.isNotEmpty ? updated : session.toolName;
}

/// Dialog for picking one of a provider's recent sessions.
class AiSessionPickerDialog extends StatefulWidget {
  /// Creates a new [AiSessionPickerDialog].
  const AiSessionPickerDialog({
    required this.toolName,
    required this.loadSessions,
    this.initialMaxSessions = 12,
    this.sessionFetchStep = 12,
    this.onSessionLongPress,
    super.key,
  });

  /// Provider display name.
  final String toolName;

  /// Loads recent sessions for the selected provider.
  final AiSessionLoader loadSessions;

  /// Initial number of sessions to request.
  final int initialMaxSessions;

  /// Step to use when the user asks for more sessions.
  final int sessionFetchStep;

  /// Called when a session is held for a one-off launch-mode choice.
  final ValueChanged<ToolSessionInfo>? onSessionLongPress;

  @override
  State<AiSessionPickerDialog> createState() => _AiSessionPickerDialogState();
}

class _AiSessionPickerDialogState extends State<AiSessionPickerDialog> {
  static const _loadMoreScrollThreshold = 240.0;

  final ScrollController _scrollController = ScrollController();
  StreamSubscription<DiscoveredSessionsResult>? _subscription;
  List<ToolSessionInfo>? _sessions;
  String? _error;
  late int _maxSessions;
  int _loadGeneration = 0;
  bool _isLoading = false;
  bool _hasFailure = false;
  bool _canLoadMore = false;

  @override
  void initState() {
    super.initState();
    _maxSessions = widget.initialMaxSessions;
    _scrollController.addListener(_maybeLoadMoreForScrollPosition);
    unawaited(_loadSessions());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  Future<void> _loadSessions() async {
    final loadGeneration = ++_loadGeneration;
    await _subscription?.cancel();
    _subscription = null;
    if (!mounted) return;

    setState(() {
      _isLoading = true;
      _error = null;
      _hasFailure = false;
      _canLoadMore = false;
    });

    _subscription = widget
        .loadSessions(_maxSessions)
        .listen(
          (result) {
            if (!mounted || loadGeneration != _loadGeneration) return;
            setState(() {
              _sessions = result.sessions;
              _hasFailure = result.hasFailures;
              _error = result.failureMessage;
            });
          },
          onError: (Object _) {
            if (!mounted || loadGeneration != _loadGeneration) return;
            setState(() {
              _sessions ??= const <ToolSessionInfo>[];
              _hasFailure = true;
              _error = 'Could not load recent AI sessions.';
              _isLoading = false;
              _canLoadMore = false;
            });
            _subscription = null;
          },
          onDone: () {
            if (!mounted || loadGeneration != _loadGeneration) return;
            final sessions = _sessions ?? const <ToolSessionInfo>[];
            setState(() {
              _isLoading = false;
              _canLoadMore = !_hasFailure && sessions.length >= _maxSessions;
            });
            _subscription = null;
          },
          cancelOnError: true,
        );
  }

  void _loadMore() {
    if (_isLoading) return;
    setState(() => _maxSessions += widget.sessionFetchStep);
    unawaited(_loadSessions());
  }

  void _maybeLoadMoreForScrollPosition() {
    if (_isLoading || !_canLoadMore || !_scrollController.hasClients) return;
    if (_scrollController.position.extentAfter <= _loadMoreScrollThreshold) {
      _loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sessions = _sessions ?? const <ToolSessionInfo>[];
    final hasSessions = sessions.isNotEmpty;
    final maxDialogHeight = MediaQuery.sizeOf(context).height * 0.6;

    return AlertDialog(
      title: Text(
        widget.toolName,
        style: FluttyTheme.displayMono(
          fontSize: 18,
          color: theme.colorScheme.onSurface,
        ),
      ),
      contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
      content: hasSessions
          ? SizedBox(
              width: double.maxFinite,
              height: maxDialogHeight,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                        _error!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  Expanded(
                    child: Scrollbar(
                      child: ListView.separated(
                        controller: _scrollController,
                        itemCount: sessions.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) => _AiSessionPickerTile(
                          session: sessions[index],
                          onTap: () =>
                              Navigator.of(context).pop(sessions[index]),
                          onLongPress: widget.onSessionLongPress == null
                              ? null
                              : () {
                                  widget.onSessionLongPress!(sessions[index]);
                                  Navigator.of(context).pop();
                                },
                        ),
                      ),
                    ),
                  ),
                  if (_isLoading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator.adaptive(
                          strokeWidth: 2,
                        ),
                      ),
                    ),
                ],
              ),
            )
          : ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                child: _buildEmptyContent(theme),
              ),
            ),
      actions: [
        if (!_isLoading && !hasSessions)
          TextButton(
            onPressed: () => unawaited(_loadSessions()),
            child: const Text('Retry'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _buildEmptyContent(ThemeData theme) {
    if (_isLoading) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator.adaptive(strokeWidth: 2),
        ),
      );
    }

    if (_error != null) {
      return Text(
        _error!,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.error,
        ),
      );
    }

    return Text(
      'No recent sessions found.',
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _AiSessionPickerTile extends StatelessWidget {
  const _AiSessionPickerTile({
    required this.session,
    required this.onTap,
    this.onLongPress,
  });

  final ToolSessionInfo session;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      horizontalTitleGap: 12,
      minLeadingWidth: 20,
      leading: AgentToolIcon(
        toolName: session.toolName,
        color: theme.colorScheme.primary,
      ),
      title: Text(
        session.summary ?? session.sessionId,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: FluttyTheme.monoStyle.copyWith(
          fontSize: 13,
          color: theme.colorScheme.onSurface,
        ),
      ),
      subtitle: Text(
        aiSessionSubtitle(session),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}

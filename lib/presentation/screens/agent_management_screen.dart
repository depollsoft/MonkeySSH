import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../domain/models/agent_runtime_info.dart';
import '../../domain/models/agent_usage.dart';
import '../../domain/models/monetization.dart';
import '../../domain/services/agent_management_service.dart';
import '../../domain/services/monetization_service.dart';
import '../../domain/services/ssh_service.dart';
import '../view_models/agent_management_view_model.dart';
import '../widgets/agent_tool_icon.dart';
import '../widgets/agent_usage_summary.dart';
import '../widgets/premium_access.dart';
import 'agent_management_presentation.dart';

/// Manages coding-agent CLIs and ACP adapters on an active remote host.
class AgentManagementScreen extends ConsumerStatefulWidget {
  /// Creates the management screen for [session].
  const AgentManagementScreen({
    required this.session,
    this.service,
    this.onProvidersRefreshed,
    this.onRuntimesRefreshed,
    super.key,
  });

  /// Active remote SSH session.
  final SshSession session;

  /// Optional service override used by tests and embedded callers.
  final AgentManagementService? service;

  /// Called after remote probes invalidate and refresh provider discovery.
  final VoidCallback? onProvidersRefreshed;

  /// Publishes the latest runtime state for an existing update notice.
  final ValueChanged<List<AgentRuntimeInfo>>? onRuntimesRefreshed;

  @override
  ConsumerState<AgentManagementScreen> createState() =>
      _AgentManagementScreenState();
}

class _AgentManagementScreenState extends ConsumerState<AgentManagementScreen> {
  late final AgentManagementViewModel _model;
  final Set<AgentRuntimeKind> _absentExpanded = <AgentRuntimeKind>{};

  @override
  void initState() {
    super.initState();
    // Access checks for a started batch must outlive this widget's ref.
    final monetization = ref.read(monetizationServiceProvider);
    _model = AgentManagementViewModel(
      session: () => widget.session,
      service: () => widget.service ?? ref.read(agentManagementServiceProvider),
      canManageAgents: () =>
          monetization.canUseFeature(MonetizationFeature.agentManagement),
      onRuntimesRefreshed: (runtimes) =>
          widget.onRuntimesRefreshed?.call(runtimes),
      onProvidersRefreshed: () => widget.onProvidersRefreshed?.call(),
      showActionResult: _showActionResult,
      showBulkFailures: _showBulkFailures,
    )..addListener(_modelChanged);
    _model.initialize();
  }

  bool get _nothingInstalled =>
      _model.runtimes.isNotEmpty && _model.runtimes.every(isAgentRuntimeAbsent);

  // An empty host lists every agent. Keep that catalog open after the first
  // install instead of folding it away under the user's thumb.
  void _modelChanged() => setState(() {
    if (_nothingInstalled) _absentExpanded.addAll(AgentRuntimeKind.values);
  });

  @override
  void dispose() {
    _model.removeListener(_modelChanged);
    _model.dispose();
    super.dispose();
  }

  Future<void> _showBulkFailures(List<String> failures) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(
          Icons.error_outline,
          color: Theme.of(context).colorScheme.error,
        ),
        title: const Text('Some updates failed'),
        content: Text('Could not update ${failures.join(', ')}.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _showActionResult(
    AgentRuntimeInfo runtime,
    AgentRuntimeActionResult result,
  ) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      icon: Icon(
        result.succeeded ? Icons.check_circle_outline : Icons.error_outline,
        color: result.succeeded
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.error,
      ),
      title: Text(
        result.succeeded
            ? '${runtime.definition.label} ready'
            : '${runtime.definition.label} failed',
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 360),
        child: SingleChildScrollView(
          child: SelectableText(
            result.output.isEmpty
                ? result.succeeded
                      ? 'The remote command completed successfully.'
                      : 'The remote command did not return output.'
                : result.output,
            style: FluttyTheme.monoStyle.copyWith(fontSize: 12),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final access =
        ref.watch(monetizationStateProvider).asData?.value ??
        ref.read(monetizationServiceProvider).currentState;
    if (!access.allowsFeature(MonetizationFeature.agentManagement)) {
      return Scaffold(
        appBar: AppBar(
          title: Text('Agent Management', style: FluttyTheme.displayMono()),
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.lock_outline_rounded,
                      size: 32,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Agent Management requires Pro',
                      textAlign: TextAlign.center,
                      style: FluttyTheme.displayMono(fontSize: 18),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Install, repair, and update coding agents on your remote hosts.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: () async {
                        if (await requireMonetizationFeatureAccess(
                              context: context,
                              ref: ref,
                              feature: MonetizationFeature.agentManagement,
                            ) &&
                            mounted) {
                          await _model.refresh();
                        }
                      },
                      child: const Text('Unlock Pro'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    final updates = _model.runtimes
        .where((runtime) => runtime.hasUpdate)
        .toList();
    final managedUpdates = updates
        .where((runtime) => runtime.managedByPackageManager)
        .length;
    final initiallyChecking =
        _model.runtimes.isNotEmpty &&
        _model.runtimes.every(
          (runtime) => runtime.status == AgentRuntimeStatus.checking,
        );
    final nothingInstalled = _nothingInstalled;
    Widget section(
      AgentRuntimeKind kind,
      String title,
      String singular,
      String subtitle,
    ) => _RuntimeSection(
      kind: kind,
      title: title,
      singular: singular,
      subtitle: subtitle,
      runtimes: _model.runtimes
          .where((runtime) => runtime.definition.kind == kind)
          .toList(),
      showAbsentInline: nothingInstalled,
      absentExpanded: _absentExpanded.contains(kind),
      onToggleAbsent: () => setState(() {
        if (!_absentExpanded.remove(kind)) _absentExpanded.add(kind);
      }),
      runningActions: _model.runningActions,
      queuedActions: _model.queuedActions,
      recheckingActions: _model.recheckingActions,
      actionOutput: _model.actionOutput,
      usage: _model.usage,
      checkingUsage: _model.checkingUsage,
      locked: _model.busy || _model.refreshing,
      onAction: _model.runAction,
      onRecheck: _model.recheck,
    );
    final cliSection = section(
      AgentRuntimeKind.cli,
      'agent CLIs',
      'agent CLI',
      'Launch and resume tools available on this host',
    );
    final acpSection = section(
      AgentRuntimeKind.acpAdapter,
      'ACP adapters',
      'ACP adapter',
      'Providers available to native agent windows',
    );
    return Scaffold(
      appBar: AppBar(
        title: Text('Agent Management', style: FluttyTheme.displayMono()),
        actions: [
          IconButton(
            key: const ValueKey('agent-management-refresh'),
            tooltip: 'Refresh agents',
            onPressed: _model.refreshing || _model.busy ? null : _model.refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: SizedBox(
            height: 2,
            child: _model.refreshing
                ? const LinearProgressIndicator(
                    minHeight: 2,
                    semanticsLabel: 'Checking agent versions',
                  )
                : null,
          ),
        ),
      ),
      // Always present so the bar can ease in and out; the empty state only
      // holds the bottom inset the body gives up to a bottom bar.
      bottomNavigationBar: _LayoutSize(
        child: updates.isNotEmpty || _model.updatingAll
            ? _UpdateBar(
                label: _model.updatingAll
                    ? 'Updating ${_model.completedUpdates + 1 > _model.totalUpdates ? _model.totalUpdates : _model.completedUpdates + 1} of ${_model.totalUpdates}'
                    : '${updates.length} ${updates.length == 1 ? 'update' : 'updates'} available',
                busy: _model.updatingAll,
                managedCount: managedUpdates,
                manualCount: updates.length - managedUpdates,
                onUpdate: _model.busy || _model.refreshing
                    ? null
                    : _model.updateAll,
              )
            : const SafeArea(
                top: false,
                child: SizedBox(width: double.infinity),
              ),
      ),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: _model.refresh,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide =
                  constraints.maxWidth >= 760 &&
                  MediaQuery.textScalerOf(context).scale(14) <= 19;
              final padding = _contentInset(constraints.maxWidth);
              return ListView(
                key: const ValueKey('agent-management-list'),
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(padding, 16, padding, 24),
                children: [
                  if (_model.refreshError != null)
                    _ErrorBanner(
                      message: _model.refreshError!,
                      onRetry: _model.refreshing || _model.busy
                          ? null
                          : _model.refresh,
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: _LayoutSize(
                        child: Semantics(
                          key: const ValueKey('agent-usage-announcement'),
                          liveRegion: true,
                          label: _model.checkingUsage
                              ? 'Checking account usage.'
                              : _model.usageGeneration > 0
                              ? 'Account usage checks complete. Review each agent for results.'
                              : null,
                          child: Row(
                            children: [
                              Icon(
                                initiallyChecking
                                    ? Icons.sync_rounded
                                    : Icons.dns_outlined,
                                size: 18,
                                color: scheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  initiallyChecking
                                      ? 'Checking installed agents…'
                                      : _model.refreshing
                                      ? 'Refreshing versions…'
                                      : nothingInstalled
                                      ? 'No agents on this host yet. Install one below.'
                                      : 'Installed versions and account usage',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (_model.runtimes.isEmpty && !_model.refreshing)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 32),
                      child: Text(
                        'No agent information returned. Refresh to try again.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    )
                  else if (wide)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: constraints.maxWidth >= 1000 ? 3 : 1,
                          child: cliSection,
                        ),
                        const SizedBox(width: 24),
                        Expanded(
                          flex: constraints.maxWidth >= 1000 ? 2 : 1,
                          child: acpSection,
                        ),
                      ],
                    )
                  else ...[
                    cliSection,
                    const SizedBox(height: 24),
                    acpSection,
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Horizontal inset that centres content at 1152dp on wide layouts.
double _contentInset(double width) => width > 1200
    ? (width - 1152) / 2
    : width >= 700
    ? 24
    : 16;

class _UpdateBar extends StatelessWidget {
  const _UpdateBar({
    required this.label,
    required this.busy,
    required this.onUpdate,
    required this.managedCount,
    required this.manualCount,
  });
  final int managedCount;
  final int manualCount;
  final String label;
  final bool busy;
  final VoidCallback? onUpdate;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: _contentInset(MediaQuery.sizeOf(context).width),
            vertical: 12,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final status = Semantics(
                liveRegion: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: FluttyTheme.displayMono(
                        fontSize: 13,
                        letterSpacing: 0,
                      ),
                    ),
                    if (manualCount > 0) ...[
                      const SizedBox(height: 4),
                      Text(
                        '$manualCount ${manualCount == 1 ? 'requires' : 'require'} a manual update on the host.',
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              );
              final button = FilledButton(
                key: const ValueKey('agent-update-all'),
                onPressed: onUpdate,
                style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                child: Text(
                  busy
                      ? 'Updating…'
                      : manualCount > 0
                      ? 'Update $managedCount'
                      : 'Update all',
                ),
              );
              if (!busy && managedCount == 0) return status;
              if (constraints.maxWidth < 350 ||
                  MediaQuery.textScalerOf(context).scale(14) > 20) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [status, const SizedBox(height: 12), button],
                );
              }
              return Row(
                children: [
                  Expanded(child: status),
                  const SizedBox(width: 16),
                  button,
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _RuntimeSection extends StatelessWidget {
  const _RuntimeSection({
    required this.kind,
    required this.title,
    required this.singular,
    required this.subtitle,
    required this.runtimes,
    required this.showAbsentInline,
    required this.absentExpanded,
    required this.onToggleAbsent,
    required this.runningActions,
    required this.queuedActions,
    required this.recheckingActions,
    required this.actionOutput,
    required this.usage,
    required this.checkingUsage,
    required this.locked,
    required this.onAction,
    required this.onRecheck,
  });
  final AgentRuntimeKind kind;
  final String title;
  final String singular;
  final String subtitle;
  final List<AgentRuntimeInfo> runtimes;
  final bool showAbsentInline;
  final bool absentExpanded;
  final VoidCallback onToggleAbsent;
  final Set<String> runningActions;
  final Set<String> queuedActions;
  final Set<String> recheckingActions;
  final Map<String, String> actionOutput;
  final Map<String, AgentUsage> usage;
  final bool checkingUsage;
  final bool locked;
  final ValueChanged<AgentRuntimeInfo> onAction;
  final ValueChanged<AgentRuntimeInfo> onRecheck;

  @override
  Widget build(BuildContext context) {
    if (runtimes.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final checking = runtimes.every(
      (runtime) => runtime.status == AgentRuntimeStatus.checking,
    );
    final installed = runtimes.where(isAgentRuntimeInstalled).length;
    final shown = [
      for (final runtime in runtimes)
        if (showAbsentInline || !isAgentRuntimeAbsent(runtime)) runtime,
    ];
    final absent = [
      for (final runtime in runtimes)
        if (!showAbsentInline && isAgentRuntimeAbsent(runtime)) runtime,
    ];
    String count(int value) => '$value ${value == 1 ? singular : title}';
    Widget divider() => Divider(
      height: 1,
      indent: 12,
      endIndent: 12,
      color: scheme.outlineVariant,
    );
    Widget row(AgentRuntimeInfo runtime) {
      final id = runtime.definition.id;
      return _RuntimeRow(
        key: ValueKey(id),
        runtime: runtime,
        usage: usage[id],
        checkingUsage: checkingUsage,
        busy: runningActions.contains(id),
        queued: queuedActions.contains(id),
        rechecking: recheckingActions.contains(id),
        locked: locked,
        actionOutput: actionOutput[id],
        onAction: () => onAction(runtime),
        onRecheck: () => onRecheck(runtime),
      );
    }

    final List<Widget> rows;
    if (checking) {
      // Row-per-agent placeholders would shrink to the installed few once
      // discovery lands; one line keeps the section steady until then.
      rows = [
        _GroupRow(
          key: ValueKey('agent-checking-${kind.name}'),
          icon: Icons.sync_rounded,
          label: 'Checking ${count(runtimes.length)}…',
        ),
      ];
    } else {
      final names = absent
          .map(
            (runtime) =>
                kind == AgentRuntimeKind.acpAdapter &&
                    runtime.definition.label.endsWith(' ACP')
                ? runtime.definition.label.substring(
                    0,
                    runtime.definition.label.length - 4,
                  )
                : runtime.definition.label,
          )
          .join(', ');
      rows = [
        for (var index = 0; index < shown.length; index++) ...[
          if (index > 0) divider(),
          row(shown[index]),
        ],
        if (absent.isNotEmpty) ...[
          if (shown.isNotEmpty) divider(),
          _GroupRow(
            key: ValueKey('agent-absent-toggle-${kind.name}'),
            icon: Icons.download_rounded,
            label: '${absent.length} not installed',
            detail: absentExpanded ? null : names,
            expanded: absentExpanded,
            onTap: onToggleAbsent,
            semanticsLabel: absentExpanded
                ? '${count(absent.length)} not installed'
                : '${count(absent.length)} not installed: $names',
          ),
          _Reveal(
            child: absentExpanded
                ? Column(
                    key: ValueKey('agent-absent-list-${kind.name}'),
                    children: [
                      for (final runtime in absent) ...[
                        divider(),
                        row(runtime),
                      ],
                    ],
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ];
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 0, 0, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: FluttyTheme.displayMono(fontSize: 15),
                    ),
                  ),
                  Semantics(
                    container: true,
                    label: checking
                        ? count(runtimes.length)
                        : '$installed of ${runtimes.length} installed',
                    excludeSemantics: true,
                    child: Text(
                      checking
                          ? '${runtimes.length}'
                          : '$installed/${runtimes.length}',
                      style: FluttyTheme.monoStyle.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        Material(
          color: scheme.surfaceContainerLow,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: scheme.outlineVariant),
          ),
          // Discovery replaces the placeholder with however many rows the
          // host has; grow into them rather than jumping.
          child: _Reveal(
            child: Column(key: ValueKey(checking), children: rows),
          ),
        ),
      ],
    );
  }
}

Duration _layoutMotion(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context)
    ? Duration.zero
    : const Duration(milliseconds: 200);

/// Avoids a zero-duration size animation mutating its own layout.
class _LayoutSize extends StatelessWidget {
  const _LayoutSize({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return AnimatedSize(
      duration: _layoutMotion(context),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: child,
    );
  }
}

/// Swaps [child] by growing the new content in from the top while the old
/// content fades and folds away, so neighbours slide instead of jump.
class _Reveal extends StatelessWidget {
  const _Reveal({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: _layoutMotion(context),
    switchInCurve: Curves.easeOutCubic,
    switchOutCurve: Curves.easeInCubic,
    transitionBuilder: (child, animation) => SizeTransition(
      sizeFactor: animation,
      alignment: Alignment.topCenter,
      child: FadeTransition(opacity: animation, child: child),
    ),
    layoutBuilder: (current, previous) => Stack(
      alignment: Alignment.topCenter,
      children: [...previous, ?current],
    ),
    child: child,
  );
}

/// A non-agent line inside a section card: the discovery placeholder, or the
/// disclosure that folds away agents missing from the host.
class _GroupRow extends StatelessWidget {
  const _GroupRow({
    required this.icon,
    required this.label,
    this.detail,
    this.expanded,
    this.onTap,
    this.semanticsLabel,
    super.key,
  });

  final IconData icon;
  final String label;
  final String? detail;
  final bool? expanded;
  final VoidCallback? onTap;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Row(
          children: [
            Icon(icon, size: 20, color: scheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: FluttyTheme.monoStyle.copyWith(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                  if (detail case final detail?) ...[
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // Same 48px column as the rows' re-check buttons.
            if (expanded case final expanded?)
              SizedBox(
                width: 48,
                child: Icon(
                  expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
    if (onTap == null) return content;
    return Semantics(
      container: true,
      button: true,
      expanded: expanded,
      label: semanticsLabel,
      // excludeSemantics drops the InkWell's own tap action, so the node
      // must carry it for VoiceOver and TalkBack to activate the toggle.
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(onTap: onTap, child: content),
    );
  }
}

class _RuntimeRow extends StatefulWidget {
  const _RuntimeRow({
    required this.runtime,
    required this.busy,
    required this.queued,
    required this.rechecking,
    required this.locked,
    required this.actionOutput,
    required this.usage,
    required this.checkingUsage,
    required this.onAction,
    required this.onRecheck,
    super.key,
  });
  final AgentRuntimeInfo runtime;
  final bool busy;
  final bool queued;
  final bool rechecking;
  final bool locked;
  final String? actionOutput;
  final AgentUsage? usage;
  final bool checkingUsage;
  final VoidCallback onAction;
  final VoidCallback onRecheck;

  @override
  State<_RuntimeRow> createState() => _RuntimeRowState();
}

class _RuntimeRowState extends State<_RuntimeRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final runtime = widget.runtime;
    final scheme = Theme.of(context).colorScheme;
    final status = widget.queued
        ? AgentStatusPresentation(
            'Queued',
            Icons.schedule_rounded,
            scheme.onSurfaceVariant,
          )
        : widget.busy
        ? AgentStatusPresentation(
            widget.rechecking
                ? 'Checking…'
                : runtime.hasUpdate
                ? 'Updating…'
                : runtime.status == AgentRuntimeStatus.needsRepair
                ? 'Repairing…'
                : 'Installing…',
            Icons.sync_rounded,
            scheme.onSurfaceVariant,
          )
        : agentStatusPresentation(runtime, scheme);
    final repair =
        runtime.status == AgentRuntimeStatus.needsRepair &&
        runtime.definition.supportsManagedInstall;
    final canInstall =
        repair ||
        (runtime.status == AgentRuntimeStatus.notInstalled
            ? runtime.definition.supportsManagedInstall
            : runtime.hasUpdate && runtime.managedByPackageManager);
    final label = runtime.hasUpdate
        ? 'Update'
        : repair
        ? 'Repair'
        : 'Install';
    final Widget action;
    if (widget.busy) {
      action = SizedBox.square(
        dimension: 48,
        child: Center(
          child: SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              semanticsLabel: '${runtime.definition.label}: ${status.label}',
            ),
          ),
        ),
      );
    } else if (widget.queued) {
      action = const SizedBox(width: 48);
    } else if (canInstall) {
      action = Semantics(
        label: '$label ${runtime.definition.label}',
        button: true,
        child: OutlinedButton.icon(
          key: ValueKey('agent-action-${runtime.definition.id}'),
          onPressed: widget.locked ? null : widget.onAction,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            side: BorderSide(color: scheme.outline),
          ),
          icon: Icon(
            runtime.hasUpdate
                ? Icons.upgrade_rounded
                : repair
                ? Icons.build_outlined
                : Icons.download_rounded,
            size: 18,
          ),
          label: Text(label),
        ),
      );
    } else {
      action = IconButton(
        key: ValueKey('agent-recheck-${runtime.definition.id}'),
        tooltip: 'Re-check ${runtime.definition.label}',
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        onPressed:
            widget.locked || runtime.status == AgentRuntimeStatus.checking
            ? null
            : widget.onRecheck,
        icon: const Icon(Icons.refresh_rounded, size: 20),
      );
    }
    return Padding(
      key: ValueKey('agent-runtime-${runtime.definition.id}'),
      padding: const EdgeInsets.all(12),
      // Usage, status, and details arrive after the row; ease each height
      // change so rows below slide instead of jump.
      child: _LayoutSize(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final stacked =
                constraints.maxWidth < 300 ||
                MediaQuery.textScalerOf(context).scale(14) > 20;
            final heading = Semantics(
              button: true,
              expanded: _expanded,
              label: '${runtime.definition.label} details',
              child: InkWell(
                key: ValueKey('agent-details-${runtime.definition.id}'),
                onTap: () => setState(() => _expanded = !_expanded),
                borderRadius: BorderRadius.circular(8),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Row(
                    children: [
                      AgentToolIcon(
                        tool: runtime.definition.tool,
                        color: scheme.onSurfaceVariant,
                        fallbackIcon: Icons.hub_outlined,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          runtime.definition.label,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Icon(
                        _expanded
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: heading),
                    if (!stacked) ...[const SizedBox(width: 8), action],
                  ],
                ),
                const SizedBox(height: 4),
                Semantics(
                  liveRegion: widget.busy || widget.queued,
                  child: _StatusLabel(presentation: status),
                ),
                if (agentSourceLine(runtime) case final String source
                    when !_expanded) ...[
                  const SizedBox(height: 4),
                  Text(
                    source,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: FluttyTheme.monoStyle.copyWith(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (runtime.message case final message?) ...[
                  const SizedBox(height: 6),
                  Text(
                    message,
                    maxLines: _expanded ? null : 2,
                    overflow: _expanded ? null : TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
                if (runtime.definition.kind == AgentRuntimeKind.cli &&
                    (runtime.status == AgentRuntimeStatus.installed ||
                        runtime.status ==
                            AgentRuntimeStatus.updateAvailable)) ...[
                  const SizedBox(height: 8),
                  AgentUsageSummary(
                    usage: widget.usage,
                    checking: widget.checkingUsage,
                    expanded: _expanded,
                  ),
                ],
                if (stacked)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: action,
                    ),
                  ),
                if (_expanded) ...[
                  const SizedBox(height: 12),
                  if (runtime.installedVersion case final value?)
                    _DetailLine(label: 'Installed version', value: value),
                  if (runtime.latestVersion case final value?)
                    _DetailLine(label: 'Latest version', value: value),
                  if (runtime.detectionSource case final value?)
                    _DetailLine(label: 'Install source', value: value),
                  if (runtime.executablePath case final value?)
                    _DetailLine(
                      label: 'Executable',
                      value: displayAgentExecutablePath(value),
                    ),
                  if (runtime.hasUpdate && !runtime.managedByPackageManager)
                    const Text(
                      'Update this installation on the host, then re-check its version.',
                    ),
                  if (runtime.status == AgentRuntimeStatus.notInstalled &&
                      !runtime.definition.supportsManagedInstall)
                    const Text(
                      'Install this agent on the host, then re-check its version.',
                    ),
                  if (runtime.executablePath == null &&
                      runtime.installedVersion == null &&
                      runtime.latestVersion == null)
                    const Text('No installation details detected yet.'),
                ],
                if (widget.busy &&
                    widget.actionOutput != null &&
                    widget.actionOutput!.trim().isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Divider(height: 1),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 88),
                    child: SingleChildScrollView(
                      reverse: true,
                      child: SelectableText(
                        widget.actionOutput!.trim(),
                        style: FluttyTheme.monoStyle.copyWith(fontSize: 12),
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 2),
        SelectableText(
          value,
          style: FluttyTheme.monoStyle.copyWith(fontSize: 12),
        ),
      ],
    ),
  );
}

class _StatusLabel extends StatelessWidget {
  const _StatusLabel({required this.presentation});

  final AgentStatusPresentation presentation;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(presentation.icon, size: 14, color: presentation.color),
      const SizedBox(width: 4),
      Flexible(
        child: Text(
          presentation.label,
          style: FluttyTheme.monoStyle.copyWith(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
    ],
  );
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 20, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Could not refresh agents. $message',
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

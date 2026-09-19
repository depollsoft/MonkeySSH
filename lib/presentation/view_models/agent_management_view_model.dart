// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/models/agent_runtime_info.dart';
import '../../domain/models/agent_usage.dart';
import '../../domain/services/agent_management_service.dart';
import '../../domain/services/ssh_service.dart';

class AgentManagementViewModel extends ChangeNotifier {
  AgentManagementViewModel({
    required this.session,
    required this.service,
    required this.canManageAgents,
    required this.onRuntimesRefreshed,
    required this.onProvidersRefreshed,
    required this.showActionResult,
    required this.showBulkFailures,
  });

  final SshSession Function() session;
  final AgentManagementService Function() service;
  final Future<bool> Function() canManageAgents;
  final void Function(List<AgentRuntimeInfo>) onRuntimesRefreshed;
  final VoidCallback onProvidersRefreshed;
  final Future<void> Function(AgentRuntimeInfo, AgentRuntimeActionResult)
  showActionResult;
  final Future<void> Function(List<String>) showBulkFailures;
  bool _disposed = false;
  bool get mounted => !_disposed;
  void _change(VoidCallback change) {
    change();
    notifyListeners();
  }

  List<AgentRuntimeInfo> runtimes = const [];
  final Set<String> runningActions = <String>{};
  final Map<String, String> actionOutput = <String, String>{};
  bool refreshing = false;
  bool checkingUsage = false;
  int usageGeneration = 0;
  Map<String, AgentUsage> usage = {};
  Timer? _usageClock;
  bool updatingAll = false;
  String? refreshError;
  final Set<String> queuedActions = <String>{};
  final Set<String> recheckingActions = <String>{};
  int completedUpdates = 0;
  int totalUpdates = 0;

  bool get busy => updatingAll || runningActions.isNotEmpty;

  void initialize() {
    runtimes = [
      for (final definition in agentRuntimeDefinitions)
        AgentRuntimeInfo(
          definition: definition,
          status: AgentRuntimeStatus.checking,
        ),
    ];
    _usageClock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted && usage.isNotEmpty) notifyListeners();
    });
    unawaited(refresh());
  }

  @override
  void dispose() {
    _disposed = true;
    _usageClock?.cancel();
    super.dispose();
  }

  Future<void> _refreshUsage() async {
    final generation = ++usageGeneration;
    _change(() => checkingUsage = true);
    try {
      final usage = await service().readUsage(
        session(),
        runtimes
            .where((runtime) => runtime.definition.kind == AgentRuntimeKind.cli)
            .toList(),
      );
      if (!mounted || generation != usageGeneration) return;
      _change(() => this.usage = usage);
    } on Object {
      if (!mounted || generation != usageGeneration) return;
      _change(
        () => usage = {
          for (final runtime in runtimes)
            if (runtime.definition.kind == AgentRuntimeKind.cli)
              runtime.definition.id: const AgentUsage(
                status: AgentUsageStatus.unavailable,
              ),
        },
      );
    } finally {
      if (mounted && generation == usageGeneration) {
        _change(() => checkingUsage = false);
      }
    }
  }

  Future<void> refresh({bool afterAction = false}) async {
    if (!await canManageAgents() || !mounted) return;
    if (refreshing || (busy && !afterAction)) return;
    _change(() {
      refreshing = true;
      refreshError = null;
    });
    try {
      var usageStarted = false;
      final runtimes = await service().refreshAll(
        session(),
        onDiscovered: (discovered) {
          if (!mounted) return;
          _change(() => this.runtimes = discovered);
          usageStarted = true;
          unawaited(_refreshUsage());
        },
      );
      if (!mounted) return;
      _change(() => this.runtimes = runtimes);
      onRuntimesRefreshed(runtimes);
      onProvidersRefreshed();
      if (!usageStarted) unawaited(_refreshUsage());
    } on Object catch (error) {
      if (!mounted) return;
      _change(() => refreshError = error.toString());
    } finally {
      if (mounted) _change(() => refreshing = false);
    }
  }

  Future<void> updateAll() async {
    if (!await canManageAgents() || !mounted) return;
    final updates = runtimes
        .where(
          (runtime) => runtime.hasUpdate && runtime.managedByPackageManager,
        )
        .toList(growable: false);
    if (updates.isEmpty || busy || refreshing) return;

    _change(() {
      updatingAll = true;
      completedUpdates = 0;
      totalUpdates = updates.length;
      for (final runtime in updates) {
        queuedActions.add(runtime.definition.id);
        actionOutput[runtime.definition.id] = '';
      }
    });
    final failures = <String>[];
    try {
      for (final runtime in updates) {
        if (!mounted || !await canManageAgents() || !mounted) break;
        final result = await _executeAction(runtime, refreshAfterAction: false);
        if (!result.succeeded) failures.add(runtime.definition.label);
        if (mounted) _change(() => completedUpdates++);
      }
    } finally {
      if (mounted) {
        try {
          await refresh(afterAction: true);
        } finally {
          if (mounted) {
            _change(() {
              updatingAll = false;
              queuedActions.clear();
            });
          }
        }
      }
    }
    if (!mounted || failures.isEmpty) return;
    await showBulkFailures(failures);
  }

  Future<void> runAction(AgentRuntimeInfo runtime) async {
    if (!await canManageAgents() || !mounted) return;
    if (busy || refreshing) return;
    final result = await _executeAction(runtime);
    if (!mounted) return;
    if (!result.succeeded) await showActionResult(runtime, result);
  }

  Future<AgentRuntimeActionResult> _executeAction(
    AgentRuntimeInfo runtime, {
    bool refreshAfterAction = true,
  }) async {
    final id = runtime.definition.id;
    final update = runtime.status == AgentRuntimeStatus.updateAvailable;
    _change(() {
      queuedActions.remove(id);
      runningActions.add(id);
      actionOutput[id] = '';
    });

    late final AgentRuntimeActionResult result;
    try {
      result = await service().installOrUpdate(
        session(),
        runtime.definition,
        update: update,
        current: runtime,
        onOutput: (chunk) {
          if (!mounted) return;
          _change(() {
            final combined = '${actionOutput[id] ?? ''}$chunk';
            actionOutput[id] = combined.length <= 1200
                ? combined
                : combined.substring(combined.length - 1200);
          });
        },
      );
    } on Object catch (error) {
      result = AgentRuntimeActionResult(
        succeeded: false,
        output: 'The remote command could not be completed. $error',
      );
    } finally {
      if (mounted) {
        if (refreshAfterAction) await refresh(afterAction: true);
        if (mounted) _change(() => runningActions.remove(id));
      }
    }
    return result;
  }

  Future<void> recheck(AgentRuntimeInfo runtime) async {
    if (!await canManageAgents() || !mounted || busy || refreshing) return;
    final id = runtime.definition.id;
    _change(() {
      runningActions.add(id);
      recheckingActions.add(id);
      actionOutput[id] = '';
    });
    try {
      final updated = await service().inspect(session(), runtime.definition);
      if (!mounted) return;
      if (updated.status == AgentRuntimeStatus.failed) {
        await showActionResult(
          runtime,
          AgentRuntimeActionResult(
            succeeded: false,
            output:
                'Could not check this agent. ${updated.message ?? 'The probe failed.'}',
          ),
        );
        return;
      }
      _change(() {
        final index = runtimes.indexWhere((entry) => entry.definition.id == id);
        if (index >= 0) runtimes[index] = updated;
      });
      onRuntimesRefreshed(runtimes);
      onProvidersRefreshed();
      unawaited(_refreshUsage());
    } on Object catch (error) {
      if (!mounted) return;
      await showActionResult(
        runtime,
        AgentRuntimeActionResult(
          succeeded: false,
          output: 'Could not check this agent. $error',
        ),
      );
    } finally {
      if (mounted) {
        _change(() {
          runningActions.remove(id);
          recheckingActions.remove(id);
        });
      }
    }
  }
}

// Development-only native preview with deterministic agent states. No SSH runs.
// flutter run --flavor private -t tool/agent_management_preview.dart -d <device>
// Use --dart-define=AGENT_PREVIEW_PRO=false to preview the locked state.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/models/agent_runtime_info.dart';
import 'package:monkeyssh/domain/models/agent_usage.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/services/agent_management_service.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/domain/services/ssh_exec_queue.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/screens/agent_management_screen.dart';

const _pro = bool.fromEnvironment('AGENT_PREVIEW_PRO', defaultValue: true);
const _access = MonetizationState(
  billingAvailability: MonetizationBillingAvailability.unavailable,
  entitlements: _pro
      ? MonetizationEntitlements.pro()
      : MonetizationEntitlements.free(),
  offers: [],
  debugUnlockAvailable: false,
  debugUnlocked: false,
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  runApp(
    ProviderScope(
      overrides: [
        monetizationServiceProvider.overrideWithValue(_PreviewBilling()),
        monetizationStateProvider.overrideWith((ref) => Stream.value(_access)),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: FluttyTheme.light,
        darkTheme: FluttyTheme.dark,
        home: AgentManagementScreen(
          session: _PreviewSession(),
          service: _PreviewManagement(),
        ),
      ),
    ),
  );
}

class _PreviewBilling extends Fake implements MonetizationService {
  @override
  MonetizationState get currentState => _access;
  @override
  Future<bool> canUseFeature(MonetizationFeature feature) async => _pro;
}

class _PreviewSession extends Fake implements SshSession {}

class _PreviewManagement extends Fake implements AgentManagementService {
  final _runtimes = [
    for (final definition in agentRuntimeDefinitions) _sample(definition),
  ];

  static AgentRuntimeInfo _sample(AgentRuntimeDefinition definition) {
    final id = definition.id;
    final status = switch (id) {
      'cli:claude' || 'cli:codex' => AgentRuntimeStatus.updateAvailable,
      _ when definition.kind == AgentRuntimeKind.cli =>
        AgentRuntimeStatus.installed,
      _ => AgentRuntimeStatus.notInstalled,
    };
    final installed = status != AgentRuntimeStatus.notInstalled;
    final version = switch (id) {
      'cli:claude' => '2.1.44',
      'cli:codex' => '0.114.0',
      'cli:copilot' => '0.0.412',
      'cli:opencode' => '1.2.8',
      _ => '1.4.0',
    };
    return AgentRuntimeInfo(
      definition: definition,
      status: status,
      installedVersion: installed ? version : null,
      latestVersion: status == AgentRuntimeStatus.updateAvailable
          ? (id == 'cli:claude' ? '2.1.51' : '0.115.0')
          : version,
      executablePath: installed
          ? '/opt/homebrew/bin/${definition.executableNames.first}'
          : null,
      detectionSource: installed ? 'Homebrew' : null,
      managedByPackageManager: installed,
      message: status == AgentRuntimeStatus.needsRepair
          ? 'Required setup scripts did not run.'
          : null,
    );
  }

  @override
  Future<Map<String, AgentUsage>> readUsage(
    SshSession session,
    List<AgentRuntimeInfo> runtimes,
  ) async => {
    for (final runtime in runtimes)
      runtime.definition.id: _sampleUsage(runtime.definition.id),
  };

  static AgentUsage _sampleUsage(String id) {
    final now = DateTime.now();
    final reset = now.add(const Duration(hours: 2));
    if (id == 'cli:antigravity') {
      return AgentUsage(status: AgentUsageStatus.needsRunning, checkedAt: now);
    }
    return AgentUsage(
      status: AgentUsageStatus.available,
      checkedAt: now,
      resetCredits: id == 'cli:codex' ? 2 : null,
      notices: id == 'cli:opencode'
          ? const [
              AgentUsageNotice(
                provider: 'Anthropic',
                status: AgentUsageStatus.signInRequired,
              ),
            ]
          : const [],
      windows: switch (id) {
        'cli:cursor' => [
          AgentUsageWindow(
            label: 'Account access',
            restricted: true,
            resetsAt: reset,
          ),
        ],
        'cli:hermes' => const [
          AgentUsageWindow(
            label: 'Nous · Purchased balance',
            remaining: 12.34,
            unit: 'USD',
          ),
        ],
        'cli:grok' => [
          AgentUsageWindow(
            label: 'Included credits',
            usedPercent: 28,
            resetsAt: reset,
          ),
        ],
        'cli:copilot' => [
          AgentUsageWindow(
            label: 'Premium requests',
            usedPercent: 42,
            resetsAt: reset,
          ),
        ],
        _ => [
          AgentUsageWindow(
            label: id == 'cli:opencode' ? 'OpenAI · 5 hours' : '5 hours',
            usedPercent: id == 'cli:codex' ? 100 : 42,
            resetsAt: reset,
          ),
          AgentUsageWindow(
            label: 'Weekly',
            usedPercent: 28,
            resetsAt: now.add(const Duration(days: 3)),
          ),
        ],
      },
    );
  }

  @override
  Future<List<AgentRuntimeInfo>> refreshAll(
    SshSession session, {
    void Function(List<AgentRuntimeInfo>)? onDiscovered,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 650));
    return List.of(_runtimes);
  }

  @override
  Future<AgentRuntimeInfo> inspect(
    SshSession session,
    AgentRuntimeDefinition definition, {
    SshExecPriority priority = SshExecPriority.normal,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 650));
    return _runtimes.firstWhere(
      (runtime) => runtime.definition.id == definition.id,
    );
  }

  @override
  Future<AgentRuntimeActionResult> installOrUpdate(
    SshSession session,
    AgentRuntimeDefinition definition, {
    required bool update,
    AgentRuntimeInfo? current,
    ValueChanged<String>? onOutput,
  }) async {
    onOutput?.call('Checking installation…\n');
    await Future<void>.delayed(const Duration(seconds: 2));
    onOutput?.call('Installing package…\n');
    await Future<void>.delayed(const Duration(seconds: 2));
    final index = _runtimes.indexWhere(
      (runtime) => runtime.definition.id == definition.id,
    );
    _runtimes[index] = AgentRuntimeInfo(
      definition: definition,
      status: AgentRuntimeStatus.installed,
      installedVersion: current?.latestVersion ?? '1.4.0',
      latestVersion: current?.latestVersion ?? '1.4.0',
      executablePath:
          current?.executablePath ??
          '/opt/homebrew/bin/${definition.executableNames.first}',
      detectionSource: 'Homebrew',
      managedByPackageManager: true,
    );
    return const AgentRuntimeActionResult(
      succeeded: true,
      output: 'Package installed.',
    );
  }
}

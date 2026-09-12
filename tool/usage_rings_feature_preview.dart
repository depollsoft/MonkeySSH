// Development-only native proof. Real feature widgets, illustrative account data.
// No SSH, account access, or persistence outside this preview.
// ignore_for_file: public_member_api_docs
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/agent_usage.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/services/agent_management_service.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/widgets/agent_tool_icon.dart';
import 'package:monkeyssh/presentation/widgets/agent_usage_rings.dart';
import 'package:monkeyssh/presentation/widgets/agent_usage_rings_menu_item.dart';
import 'package:monkeyssh/presentation/widgets/terminal_menu_style.dart';

void main() => runApp(const UsageRingsFeaturePreview());

class UsageRingsFeaturePreview extends StatefulWidget {
  const UsageRingsFeaturePreview({
    this.tool = AgentLaunchTool.claudeCode,
    this.codexUsedPercent = 23,
    super.key,
  });
  final AgentLaunchTool tool;
  final double codexUsedPercent;
  @override
  State<UsageRingsFeaturePreview> createState() =>
      _UsageRingsFeaturePreviewState();
}

class _UsageRingsFeaturePreviewState extends State<UsageRingsFeaturePreview> {
  final billing = _Billing();
  final updates = StreamController<MonetizationState>.broadcast();
  final preference = _Preference();
  late final reader = _Reader(widget.codexUsedPercent);
  final session = _Session();
  final menu = MenuController();
  bool expanded = false;

  @override
  void dispose() {
    unawaited(updates.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ProviderScope(
    overrides: [
      monetizationServiceProvider.overrideWithValue(billing),
      monetizationStateProvider.overrideWith((ref) => updates.stream),
      agentManagementServiceProvider.overrideWithValue(reader),
      showUsageRingsNotifierProvider.overrideWith(() => preference),
      activeSessionsProvider.overrideWith(_Connections.new),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: FluttyTheme.light,
      darkTheme: FluttyTheme.dark,
      themeMode: ThemeMode.dark,
      home: Builder(
        builder: (context) {
          final scheme = Theme.of(context).colorScheme;
          final icon = AgentUsageRingIcon(
            session: session,
            tool: widget.tool,
            child: AgentToolIcon(
              tool: widget.tool,
              size: 16,
              color: scheme.primary,
            ),
          );
          final terminal = Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Illustrative session · no live connection',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 28),
                Text(
                  switch (widget.tool) {
                    AgentLaunchTool.codex => r'$ codex',
                    AgentLaunchTool.antigravity => r'$ agy',
                    AgentLaunchTool.grokBuild => r'$ grok',
                    _ => r'$ claude',
                  },
                  style: TextStyle(
                    fontFamily: 'JetBrains Mono',
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '> Review the reconnect change.',
                  style: TextStyle(
                    fontFamily: 'JetBrains Mono',
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Reading connection state…',
                  style: TextStyle(
                    fontFamily: 'JetBrains Mono',
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          );
          final wide = MediaQuery.sizeOf(context).width >= 750;
          final bar = Material(
            color: scheme.surfaceContainerHighest,
            child: InkWell(
              key: const ValueKey('feature-bar'),
              onTap: () => setState(() => expanded = !expanded),
              child: SizedBox(
                height: wide ? 56 : 44,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: wide
                      ? Center(child: icon)
                      : Row(
                          children: [
                            icon,
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Reconnect handling',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelMedium
                                    ?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              width: 28,
                              height: 4,
                              decoration: BoxDecoration(
                                color: scheme.onSurfaceVariant.withAlpha(110),
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              expanded
                                  ? Icons.keyboard_arrow_down
                                  : Icons.keyboard_arrow_up,
                              size: 20,
                              color: scheme.onSurfaceVariant,
                            ),
                          ],
                        ),
                ),
              ),
            ),
          );
          return Scaffold(
            appBar: AppBar(
              title: const Text('MonkeyMux'),
              actions: [
                TextButton(
                  key: const ValueKey('preview-access'),
                  onPressed: () {
                    menu.close();
                    billing.pro = !billing.pro;
                    updates.add(billing.currentState);
                    setState(() {});
                  },
                  child: Text(billing.pro ? 'Preview: Pro' : 'Preview: Free'),
                ),
                MenuAnchor(
                  controller: menu,
                  style: TerminalMenuStyles.menuStyle(context),
                  menuChildren: [
                    SubmenuButton(
                      menuStyle: TerminalMenuStyles.menuStyle(context),
                      menuChildren: const [AgentUsageRingsMenuItem()],
                      child: const Text('Options'),
                    ),
                  ],
                  builder: (context, controller, child) => IconButton(
                    key: const ValueKey('preview-options'),
                    tooltip: 'More options',
                    onPressed: () => controller.isOpen
                        ? controller.close()
                        : controller.open(),
                    icon: const Icon(Icons.more_vert),
                  ),
                ),
              ],
            ),
            body: SafeArea(
              top: false,
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: 64,
                          child: ColoredBox(
                            color: scheme.surfaceContainerHighest,
                            child: Column(children: [bar]),
                          ),
                        ),
                        Expanded(child: terminal),
                      ],
                    )
                  : Column(
                      children: [
                        Expanded(
                          child: SizedBox(
                            width: double.infinity,
                            child: terminal,
                          ),
                        ),
                        if (expanded)
                          const Padding(
                            padding: EdgeInsets.all(16),
                            child: Text('MonkeyMux windows'),
                          ),
                        bar,
                      ],
                    ),
            ),
          );
        },
      ),
    ),
  );
}

class _Session extends Fake implements SshSession {
  @override
  int get connectionId => 7;
}

class _Connections extends ActiveSessionsNotifier {
  @override
  Map<int, SshConnectionState> build() => {7: SshConnectionState.connected};
}

class _Billing extends Fake implements MonetizationService {
  bool pro = true;
  @override
  MonetizationState get currentState => MonetizationState(
    billingAvailability: MonetizationBillingAvailability.unavailable,
    entitlements: pro
        ? const MonetizationEntitlements.pro()
        : const MonetizationEntitlements.free(),
    offers: const [],
    debugUnlockAvailable: false,
    debugUnlocked: false,
  );
  @override
  Future<bool> canUseFeature(MonetizationFeature feature) async => pro;
}

class _Preference extends ShowUsageRingsNotifier {
  bool enabled = true;
  @override
  bool build() => enabled;
  @override
  Future<bool> initializedValue() async => state;
  @override
  Future<void> setEnabled({required bool enabled}) async =>
      state = this.enabled = enabled;
}

class _Reader extends Fake implements AgentManagementService {
  _Reader(this.codexUsedPercent);
  final double codexUsedPercent;

  @override
  Future<AgentUsage?> readUsageForTool(
    SshSession session,
    AgentLaunchTool tool, {
    bool Function()? shouldContinue,
  }) async => AgentUsage(
    status: AgentUsageStatus.available,
    checkedAt: DateTime.now(),
    windows: switch (tool) {
      AgentLaunchTool.codex => [
        AgentUsageWindow(label: 'Weekly', usedPercent: codexUsedPercent),
        const AgentUsageWindow(
          label: 'codex_bengalfox · 5 hours',
          usedPercent: 0,
        ),
        const AgentUsageWindow(
          label: 'codex_bengalfox · Weekly',
          usedPercent: 0,
        ),
      ],
      AgentLaunchTool.grokBuild => const [
        AgentUsageWindow(
          label: 'Included credits',
          usedPercent: 0,
          unit: 'USD',
        ),
        AgentUsageWindow(
          label: 'On-demand spending',
          usedPercent: 50,
          unit: 'USD',
        ),
        AgentUsageWindow(label: 'Prepaid balance', remaining: 25, unit: 'USD'),
      ],
      AgentLaunchTool.antigravity => const [
        AgentUsageWindow(label: 'Fast · Basic', usedPercent: 0),
        AgentUsageWindow(label: 'Thinking · Pro', usedPercent: 25),
        AgentUsageWindow(label: 'Tools · Coding', usedPercent: 50),
        AgentUsageWindow(label: 'Vision · Pro', usedPercent: 75),
      ],
      _ => [
        AgentUsageWindow(
          label: '5 hours',
          usedPercent: 42,
          resetsAt: DateTime.now().add(const Duration(hours: 1)),
        ),
        AgentUsageWindow(
          label: 'Weekly',
          usedPercent: 36,
          resetsAt: DateTime.now().add(const Duration(days: 3)),
        ),
      ],
    },
  );
}

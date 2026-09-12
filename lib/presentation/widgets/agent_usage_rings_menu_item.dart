import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/monetization.dart';
import '../../domain/services/monetization_service.dart';
import '../../domain/services/settings_service.dart';
import 'premium_access.dart';
import 'premium_badge.dart';
import 'terminal_menu_style.dart';

/// Persistent Pro-only checkbox in the terminal Options submenu.
class AgentUsageRingsMenuItem extends ConsumerWidget {
  /// Creates the existing-menu-style usage-ring option.
  const AgentUsageRingsMenuItem({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access =
        ref.watch(monetizationStateProvider).asData?.value ??
        ref.watch(monetizationServiceProvider).currentState;
    final allowed = access.allowsFeature(MonetizationFeature.agentUsageRings);
    final enabled = ref.watch(showUsageRingsProvider).asData?.value ?? false;
    // MenuAnchor unmounts its menu before dispatching selection callbacks.
    // Capture stable owners now, never read the menu WidgetRef after dismissal.
    final navigationContext = Navigator.of(context).context;
    final service = ref.watch(monetizationServiceProvider);
    final notifier = ref.read(showUsageRingsNotifierProvider.notifier);
    return CheckboxMenuButton(
      key: const ValueKey('show-usage-rings-option'),
      style: TerminalMenuStyles.itemButtonStyle(context),
      value: allowed && enabled,
      trailingIcon: allowed ? null : const PremiumBadge(),
      onChanged: (_) async {
        if (!await requireMonetizationFeatureAccessWithService(
              context: navigationContext,
              service: service,
              feature: MonetizationFeature.agentUsageRings,
            ) ||
            !navigationContext.mounted) {
          return;
        }
        final current = await notifier.initializedValue();
        if (!navigationContext.mounted) return;
        await notifier.setEnabled(enabled: !allowed || !current);
      },
      child: Text(
        'Show usage rings',
        style: TerminalMenuStyles.itemTextStyle(context),
      ),
    );
  }
}

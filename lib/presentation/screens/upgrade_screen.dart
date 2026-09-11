import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme.dart';
import '../../domain/models/monetization.dart';
import '../../domain/services/monetization_service.dart';
import '../../domain/services/telemetry_service.dart';
import '../widgets/premium_badge.dart';

final _privacyPolicyUri = Uri.parse(
  'https://github.com/depollsoft/MonkeySSH/blob/main/docs/privacy-policy.md',
);
final _termsOfUseUri = Uri.parse(
  'https://www.apple.com/legal/internet-services/itunes/dev/stdeula/',
);

/// Upgrade screen for MonkeySSH Pro.
class UpgradeScreen extends ConsumerStatefulWidget {
  /// Creates a new [UpgradeScreen].
  const UpgradeScreen({
    this.feature,
    this.blockedAction,
    this.blockedOutcome,
    super.key,
  });

  /// Feature that triggered the upgrade flow, when known.
  final MonetizationFeature? feature;

  /// User action that was blocked by the paywall.
  final String? blockedAction;

  /// Outcome the user gets after upgrading for the blocked action.
  final String? blockedOutcome;

  @override
  ConsumerState<UpgradeScreen> createState() => _UpgradeScreenState();
}

class _UpgradeScreenState extends ConsumerState<UpgradeScreen> {
  var _restoreInProgress = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(
        ref
            .read(telemetryServiceProvider)
            .logPaywallShown(
              feature: widget.feature?.name ?? 'settings',
              source: widget.feature == null ? 'settings' : 'feature_gate',
            ),
      );
    });
  }

  MonetizationOffer? _offerForPeriod(
    List<MonetizationOffer> offers,
    MonetizationBillingPeriod billingPeriod,
  ) {
    for (final offer in offers) {
      if (offer.billingPeriod == billingPeriod) {
        return offer;
      }
    }
    return null;
  }

  int? _annualSavingsPercent(List<MonetizationOffer> offers) {
    final monthlyOffer = _offerForPeriod(
      offers,
      MonetizationBillingPeriod.monthly,
    );
    final annualOffer = _offerForPeriod(
      offers,
      MonetizationBillingPeriod.annual,
    );
    if (monthlyOffer == null ||
        annualOffer == null ||
        monthlyOffer.currencyCode != annualOffer.currencyCode) {
      return null;
    }
    final yearlyMonthlyCost = monthlyOffer.rawPrice * 12;
    if (yearlyMonthlyCost <= annualOffer.rawPrice) {
      return null;
    }
    final savingsPercent =
        ((yearlyMonthlyCost - annualOffer.rawPrice) / yearlyMonthlyCost * 100)
            .round();
    return savingsPercent <= 0 ? null : savingsPercent;
  }

  String? _sharedIntroductoryOfferLabel(List<MonetizationOffer> offers) {
    final offersWithIntro = offers
        .where((offer) => offer.introductoryOfferLabel != null)
        .toList(growable: false);
    if (offersWithIntro.isEmpty) {
      return null;
    }
    if (offersWithIntro.length == 1) {
      return offersWithIntro.first.introductoryOfferLabel;
    }
    final sharedIntro = offersWithIntro.first.introductoryOfferLabel!;
    if (offersWithIntro.any(
      (offer) => offer.introductoryOfferLabel != sharedIntro,
    )) {
      return null;
    }
    final planLabels = offersWithIntro
        .map((offer) => offer.planLabel.toLowerCase())
        .toList(growable: false);
    late final String planSummary;
    if (planLabels.length == 2) {
      planSummary = '${planLabels.first} and ${planLabels.last}';
    } else {
      final leadingPlans = planLabels.take(planLabels.length - 1).join(', ');
      planSummary = '$leadingPlans, and ${planLabels.last}';
    }
    return '$sharedIntro on $planSummary plans.';
  }

  String _pricingSourceLabel() => switch (defaultTargetPlatform) {
    TargetPlatform.iOS ||
    TargetPlatform.macOS => 'Pricing loads from the App Store',
    TargetPlatform.android => 'Pricing loads from Google Play',
    _ => 'Pricing loads from your local storefront',
  };

  String _storefrontLabel() => switch (defaultTargetPlatform) {
    TargetPlatform.iOS || TargetPlatform.macOS => 'the App Store',
    TargetPlatform.android => 'Google Play',
    _ => 'your local storefront',
  };

  String _lifetimeDetailLabel(BuildContext context, MonetizationState state) {
    if (state.entitlementUpdatedAt case final unlockedAt?) {
      final formattedDate = MaterialLocalizations.of(
        context,
      ).formatMediumDate(unlockedAt);
      return 'Unlocked with a one-time purchase on $formattedDate.';
    }
    return 'Unlocked with a one-time purchase.';
  }

  Future<void> _purchasePro(String offerId) async {
    final messenger = ScaffoldMessenger.of(context);
    final productType = _productTypeForOffer(offerId);
    final telemetryService = ref.read(telemetryServiceProvider);
    final monetizationService = ref.read(monetizationServiceProvider);
    unawaited(telemetryService.logPurchaseStarted(productType: productType));
    final result = await monetizationService.purchaseOffer(offerId);
    unawaited(
      result.success
          ? telemetryService.logPurchaseCompleted(productType: productType)
          : telemetryService.logPurchaseFailed(
              productType: productType,
              failureCategory: result.cancelled ? 'cancelled' : 'failed',
            ),
    );
    if (!mounted) {
      return;
    }
    messenger.showSnackBar(SnackBar(content: Text(result.message)));
  }

  String _productTypeForOffer(String offerId) {
    final state =
        ref.read(monetizationStateProvider).asData?.value ??
        ref.read(monetizationServiceProvider).currentState;
    for (final offer in state.offers) {
      if (offer.id == offerId) {
        return offer.billingPeriod.name;
      }
    }
    return 'unknown';
  }

  Future<void> _restorePurchases() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _restoreInProgress = true);
    try {
      final result = await ref
          .read(monetizationServiceProvider)
          .restorePurchases();
      if (!mounted) {
        return;
      }
      messenger.showSnackBar(SnackBar(content: Text(result.message)));
    } finally {
      if (mounted) {
        setState(() => _restoreInProgress = false);
      }
    }
  }

  Uri? _manageSubscriptionUrl() => switch (defaultTargetPlatform) {
    TargetPlatform.iOS || TargetPlatform.macOS => Uri.parse(
      'https://apps.apple.com/account/subscriptions',
    ),
    TargetPlatform.android => Uri.parse(
      'https://play.google.com/store/account/subscriptions',
    ),
    _ => null,
  };

  Future<void> _openManageSubscriptions() async {
    final url = _manageSubscriptionUrl();
    if (url == null) {
      return;
    }
    await _openLegalUrl(url, 'the subscription management page');
  }

  Future<void> _openLegalUrl(Uri url, String label) async {
    final messenger = ScaffoldMessenger.of(context);
    var didOpen = false;
    try {
      // Attempt the launch directly: Android package visibility can make a
      // canLaunchUrl check fail even when a browser can open the page.
      didOpen = await launchUrl(url, mode: LaunchMode.externalApplication);
    } on PlatformException {
      // A missing browser or refused launch can throw instead of returning false.
      didOpen = false;
    }
    if (!didOpen && mounted) {
      messenger.showSnackBar(SnackBar(content: Text('Could not open $label.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final manageSubscriptionUrl = _manageSubscriptionUrl();
    final state =
        ref.watch(monetizationStateProvider).asData?.value ??
        ref.read(monetizationServiceProvider).currentState;
    final isLifetimeUnlocked = state.isLifetimeUnlocked;
    final isCatalogLoading = state.isLoading && state.offers.isEmpty;
    final isBusy = state.isLoading || _restoreInProgress;
    final progressMessage = switch ((state.isLoading, _restoreInProgress)) {
      (_, true) => 'Restoring purchases from ${_storefrontLabel()}...',
      (true, false) when state.offers.isEmpty =>
        'Loading plans from ${_storefrontLabel()}...',
      (true, false) => 'Processing your request with ${_storefrontLabel()}...',
      _ => null,
    };
    final feature = widget.feature;
    final highlightedOffer = isLifetimeUnlocked
        ? null
        : state.activeOffer ?? state.defaultOffer;
    final priceLabel = isLifetimeUnlocked
        ? 'MonkeySSH Pro Lifetime'
        : highlightedOffer?.displayPriceLabel ??
              (isCatalogLoading ? 'Loading pricing...' : _pricingSourceLabel());
    final priceDetailLabel = isLifetimeUnlocked
        ? _lifetimeDetailLabel(context, state)
        : highlightedOffer?.detailLabel ??
              (highlightedOffer == null
                  ? 'The exact price comes from your local storefront and currency.'
                  : null);
    final sharedIntroductoryOfferLabel = _sharedIntroductoryOfferLabel(
      state.offers,
    );
    final introductoryOfferLabel = isLifetimeUnlocked
        ? null
        : sharedIntroductoryOfferLabel ??
              highlightedOffer?.introductoryOfferLabel;
    final annualSavingsPercent = _annualSavingsPercent(state.offers);
    final priceCardTextStyle = theme.textTheme.bodyMedium?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );
    final priceCardEmphasisStyle = theme.textTheme.bodyMedium?.copyWith(
      color: colorScheme.onSurface,
      fontWeight: FontWeight.w600,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('MonkeySSH Pro')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Row(
            children: [
              const PremiumBadge(),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Keep more agent work connected, make repeatable workflows one tap away, and move between remote sessions without losing your place.',
                  style: theme.textTheme.bodyLarge,
                ),
              ),
            ],
          ),
          if (feature != null) ...[
            const SizedBox(height: 20),
            _UpgradeReasonCard(
              feature: feature,
              blockedAction: widget.blockedAction,
              blockedOutcome: widget.blockedOutcome,
            ),
          ],
          if (progressMessage case final message?) ...[
            const SizedBox(height: 20),
            _UpgradeProgressBanner(message: message),
          ],
          const SizedBox(height: 20),
          _SubscriptionLegalCard(
            onOpenPrivacyPolicy: () =>
                _openLegalUrl(_privacyPolicyUri, 'the privacy policy'),
            onOpenTermsOfUse: () =>
                _openLegalUrl(_termsOfUseUri, 'the Terms of Use'),
          ),
          if (isLifetimeUnlocked) ...[
            const SizedBox(height: 20),
            _UpgradeBanner(
              key: const ValueKey('lifetime-status-banner'),
              message:
                  'MonkeySSH Pro Lifetime is already active. If an older monthly or annual subscription is still renewing, manage it in ${_storefrontLabel()} to cancel future renewals.',
              backgroundColor: colorScheme.tertiaryContainer,
              foregroundColor: colorScheme.onTertiaryContainer,
            ),
          ],
          const SizedBox(height: 24),
          Text(
            'included with Pro',
            style: FluttyTheme.displayMono(
              fontSize: 15,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 12),
          const _UpgradeBenefitTile(
            icon: Icons.hub_outlined,
            title: 'Parallel native chats',
            subtitle:
                'Keep multiple native agents connected, switch instantly, and fork active sessions.',
          ),
          const _UpgradeBenefitTile(
            icon: Icons.history_outlined,
            title: 'Recent terminal sessions',
            subtitle:
                'Discover agent work across windows and jump back in without hunting for it.',
          ),
          const _UpgradeBenefitTile(
            icon: Icons.system_update_alt_rounded,
            title: 'Agent Management',
            subtitle:
                'Install, repair, and update remote coding agents, with automatic update checks.',
          ),
          const _UpgradeBenefitTile(
            icon: Icons.rocket_launch_outlined,
            title: 'Agent launch presets',
            subtitle:
                'Save repeatable startup flows per host for Codex, Claude Code, Copilot CLI, OpenCode, and more.',
          ),
          const _UpgradeBenefitTile(
            icon: Icons.play_circle_outline,
            title: 'Auto-connect workflows',
            subtitle:
                'Run a command or saved snippet automatically after opening a terminal.',
          ),
          const _UpgradeBenefitTile(
            icon: Icons.swap_horiz_outlined,
            title: 'Encrypted transfers',
            subtitle:
                'Share hosts, keys, and migration bundles through encrypted files.',
          ),
          if (state.offers.isNotEmpty && !isLifetimeUnlocked) ...[
            const SizedBox(height: 24),
            Text(
              'choose a plan',
              style: FluttyTheme.displayMono(
                fontSize: 15,
                color: theme.colorScheme.onSurface,
              ),
            ),
            if (annualSavingsPercent case final savings?) ...[
              const SizedBox(height: 8),
              _UpgradeBanner(
                key: const ValueKey('annual-savings-label'),
                message:
                    'Annual is the best value - save about $savings% compared with paying monthly.',
                backgroundColor: colorScheme.secondaryContainer,
                foregroundColor: colorScheme.onSecondaryContainer,
              ),
            ],
            if (sharedIntroductoryOfferLabel case final intro?) ...[
              const SizedBox(height: 8),
              _UpgradeBanner(
                key: const ValueKey('shared-intro-offer-label'),
                message: intro,
                backgroundColor: colorScheme.primaryContainer,
                foregroundColor: colorScheme.onPrimaryContainer,
              ),
            ],
            const SizedBox(height: 12),
            Column(
              children: state.offers
                  .map(
                    (offer) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _PlanOfferCard(
                        offer: offer,
                        isCurrentPlan: state.isActiveOffer(offer),
                        isBestValue:
                            annualSavingsPercent != null &&
                            offer.billingPeriod ==
                                MonetizationBillingPeriod.annual,
                        savingsPercent:
                            offer.billingPeriod ==
                                MonetizationBillingPeriod.annual
                            ? annualSavingsPercent
                            : null,
                        hasAnyActiveSubscription: state.isProUnlocked,
                        isBusy: isBusy,
                        canManageSubscription: manageSubscriptionUrl != null,
                        onSelect: () => _purchasePro(offer.id),
                        onManage: _openManageSubscriptions,
                      ),
                    ),
                  )
                  .toList(growable: false),
            ),
          ],
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    priceLabel,
                    style: FluttyTheme.displayMono(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (priceDetailLabel case final detail?) ...[
                    Text(detail, style: priceCardTextStyle),
                    const SizedBox(height: 8),
                  ],
                  if (introductoryOfferLabel case final intro?) ...[
                    _UpgradeBanner(
                      message: intro,
                      backgroundColor: colorScheme.primaryContainer,
                      foregroundColor: colorScheme.onPrimaryContainer,
                      compact: true,
                    ),
                    const SizedBox(height: 8),
                  ],
                  Text(
                    state.isProUnlocked
                        ? isLifetimeUnlocked
                              ? 'You already own MonkeySSH Pro Lifetime. If an older monthly or annual subscription is still active, manage it in ${_storefrontLabel()} to cancel future renewals.'
                              : switch (state.activeOffer) {
                                  final activeOffer? =>
                                    '${activeOffer.planLabel} is active on this device.',
                                  null =>
                                    'MonkeySSH Pro is already unlocked on this device.',
                                }
                        : 'No trial traps, fake urgency, or hidden close buttons. You can restore or manage your subscription from Settings at any time.',
                    style: priceCardEmphasisStyle,
                  ),
                  if (state.lastError case final error?
                      when error.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      error,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          OutlinedButton(
            onPressed: isBusy ? null : _restorePurchases,
            child: Text(
              _restoreInProgress ? 'Working...' : 'Restore purchases',
            ),
          ),
          TextButton(
            onPressed: isBusy || manageSubscriptionUrl == null
                ? null
                : _openManageSubscriptions,
            style: TextButton.styleFrom(foregroundColor: colorScheme.onSurface),
            child: Text(
              isLifetimeUnlocked
                  ? 'Manage existing subscription'
                  : 'Manage subscription',
            ),
          ),
          if (state.debugUnlockAvailable) ...[
            const SizedBox(height: 24),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Debug: local Pro unlock'),
              subtitle: const Text(
                'Development-only switch for testing premium flows before the store product is live.',
              ),
              value: state.debugUnlocked,
              onChanged: (value) => ref
                  .read(monetizationServiceProvider)
                  .setDebugUnlocked(unlocked: value),
            ),
          ],
        ],
      ),
    );
  }
}

class _SubscriptionLegalCard extends StatelessWidget {
  const _SubscriptionLegalCard({
    required this.onOpenPrivacyPolicy,
    required this.onOpenTermsOfUse,
  });

  final VoidCallback onOpenPrivacyPolicy;
  final VoidCallback onOpenTermsOfUse;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'subscription details',
              style: FluttyTheme.displayMono(
                fontSize: 15,
                color: theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'MonkeySSH Pro subscriptions are auto-renewable. Monthly plans '
              'renew every month and annual plans renew every year. Prices are '
              'shown on the plan cards below and load from your storefront.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                TextButton.icon(
                  onPressed: onOpenPrivacyPolicy,
                  icon: const Icon(Icons.privacy_tip_outlined),
                  label: const Text('Privacy Policy'),
                ),
                TextButton.icon(
                  onPressed: onOpenTermsOfUse,
                  icon: const Icon(Icons.description_outlined),
                  label: const Text('Terms of Use (EULA)'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PlanOfferCard extends StatelessWidget {
  const _PlanOfferCard({
    required this.offer,
    required this.isCurrentPlan,
    required this.isBestValue,
    required this.savingsPercent,
    required this.hasAnyActiveSubscription,
    required this.isBusy,
    required this.canManageSubscription,
    required this.onSelect,
    required this.onManage,
  });

  final MonetizationOffer offer;
  final bool isCurrentPlan;
  final bool isBestValue;
  final int? savingsPercent;
  final bool hasAnyActiveSubscription;
  final bool isBusy;
  final bool canManageSubscription;
  final VoidCallback onSelect;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final shouldEmphasizeBestValue = isBestValue && !hasAnyActiveSubscription;
    final cardColor = isCurrentPlan
        ? Color.alphaBlend(
            colorScheme.primaryContainer.withAlpha(72),
            theme.cardColor,
          )
        : shouldEmphasizeBestValue
        ? Color.alphaBlend(
            colorScheme.secondaryContainer.withAlpha(60),
            theme.cardColor,
          )
        : theme.cardColor;
    final borderColor = isCurrentPlan
        ? colorScheme.primary
        : shouldEmphasizeBestValue
        ? colorScheme.onSecondaryContainer
        : colorScheme.outline;
    final actionLabel = isCurrentPlan
        ? canManageSubscription
              ? 'Manage current plan'
              : 'Current plan'
        : hasAnyActiveSubscription
        ? 'Switch to ${offer.planLabel}'
        : 'Subscribe ${offer.planLabel.toLowerCase()}';
    final onTap = isBusy
        ? null
        : isCurrentPlan
        ? (canManageSubscription ? onManage : null)
        : onSelect;

    return Card(
      clipBehavior: Clip.antiAlias,
      color: cardColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: borderColor,
          width: isCurrentPlan ? 3 : (shouldEmphasizeBestValue ? 2 : 1),
        ),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      offer.planLabel,
                      style: FluttyTheme.displayMono(
                        fontWeight: FontWeight.w700,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ),
                  if (isCurrentPlan || isBestValue)
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (isBestValue)
                          _PlanPill(
                            label: savingsPercent == null
                                ? 'Best value'
                                : 'Best value - Save $savingsPercent%',
                            backgroundColor: colorScheme.secondaryContainer,
                            foregroundColor: colorScheme.onSecondaryContainer,
                          ),
                        if (isCurrentPlan)
                          _PlanPill(
                            label: 'Current',
                            backgroundColor: colorScheme.primaryContainer,
                            foregroundColor: colorScheme.onPrimaryContainer,
                          ),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                offer.displayPriceLabel,
                style: FluttyTheme.displayMono(
                  fontSize: 16,
                  color: colorScheme.onSurface,
                ),
              ),
              if (offer.detailLabel case final detail?) ...[
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (offer.introductoryOfferLabel case final intro?) ...[
                const SizedBox(height: 8),
                _UpgradeBanner(
                  message: intro,
                  backgroundColor: colorScheme.primaryContainer,
                  foregroundColor: colorScheme.onPrimaryContainer,
                  compact: true,
                ),
              ],
              const SizedBox(height: 16),
              Text(
                actionLabel,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: onTap == null
                      ? colorScheme.onSurfaceVariant
                      : isCurrentPlan
                      ? colorScheme.onPrimaryContainer
                      : shouldEmphasizeBestValue
                      ? colorScheme.onSecondaryContainer
                      : colorScheme.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlanPill extends StatelessWidget {
  const _PlanPill({
    required this.label,
    required this.backgroundColor,
    required this.foregroundColor,
  });

  final String label;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: backgroundColor,
      border: Border.all(color: foregroundColor.withAlpha(40)),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: foregroundColor,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class _UpgradeBanner extends StatelessWidget {
  const _UpgradeBanner({
    required this.message,
    required this.backgroundColor,
    required this.foregroundColor,
    this.compact = false,
    super.key,
  });

  final String message;
  final Color backgroundColor;
  final Color foregroundColor;
  final bool compact;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: EdgeInsets.symmetric(horizontal: 12, vertical: compact ? 10 : 12),
    decoration: BoxDecoration(
      color: backgroundColor,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      message,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
        color: foregroundColor,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class _UpgradeProgressBanner extends StatelessWidget {
  const _UpgradeProgressBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      key: const ValueKey('store-progress-banner'),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: const LinearProgressIndicator(minHeight: 4),
          ),
        ],
      ),
    );
  }
}

class _UpgradeReasonCard extends StatelessWidget {
  const _UpgradeReasonCard({
    required this.feature,
    this.blockedAction,
    this.blockedOutcome,
  });

  final MonetizationFeature feature;
  final String? blockedAction;
  final String? blockedOutcome;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            blockedAction ?? feature.blockedAction,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(blockedOutcome ?? feature.blockedOutcome),
        ],
      ),
    ),
  );
}

class _UpgradeBenefitTile extends StatelessWidget {
  const _UpgradeBenefitTile({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(subtitle),
  );
}

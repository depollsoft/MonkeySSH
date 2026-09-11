import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

/// Product identifiers used by the mobile subscription flow.
abstract final class MonetizationProductIds {
  /// Google Play subscription product.
  static const androidPro = 'monkeyssh_pro';

  /// Apple App Store monthly subscription product for the preview app.
  static const iosMonthly = 'monkeyssh_pro_monthly';

  /// Apple App Store annual subscription product for the preview app.
  static const iosAnnual = 'monkeyssh_pro_annual';

  /// Apple App Store monthly subscription product for the production app.
  static const iosMonthlyProd = 'monkeyssh_pro_monthly_prod';

  /// Apple App Store annual subscription product for the production app.
  static const iosAnnualProd = 'monkeyssh_pro_annual_prod';

  /// Google Play one-time lifetime product.
  ///
  /// This product is intentionally never displayed in the in-app paywall.
  /// It is distributed exclusively via Google Play promo codes redeemed
  /// outside of the app and surfaces in the app through the store
  /// purchase/restore flow.
  static const androidProLifetime = 'monkeyssh_pro_lifetime';

  /// Apple App Store non-consumable lifetime product for the preview app.
  ///
  /// Distributed exclusively via App Store offer/promo codes and surfaces
  /// in the app via the store purchase/restore flow.
  static const iosProLifetime = 'monkeyssh_pro_lifetime';

  /// Apple App Store non-consumable lifetime product for the production app.
  ///
  /// Distributed exclusively via App Store offer/promo codes and surfaces
  /// in the app via the store purchase/restore flow.
  static const iosProLifetimeProd = 'monkeyssh_pro_lifetime_prod';

  /// All recognized paid products across platforms.
  // The Android lifetime SKU and the iOS preview lifetime SKU share the
  // same product identifier on purpose; we only list each unique string
  // once to keep this a valid `const` set literal.
  static const allKnown = <String>{
    androidPro,
    iosMonthly,
    iosAnnual,
    iosMonthlyProd,
    iosAnnualProd,
    androidProLifetime,
    iosProLifetimeProd,
  };

  /// All recognized lifetime (one-time) product identifiers.
  // Same identifier sharing applies as in [allKnown].
  static const allLifetime = <String>{androidProLifetime, iosProLifetimeProd};

  /// Product identifiers to query on the current platform.
  static Set<String> forPlatform(
    TargetPlatform platform, {
    String? packageName,
  }) => switch (platform) {
    TargetPlatform.android => const {androidPro, androidProLifetime},
    TargetPlatform.iOS ||
    TargetPlatform.macOS => _forApplePackageName(packageName),
    _ => const {},
  };

  /// Whether [productId] identifies a lifetime (one-time) product.
  static bool isLifetime(String? productId) =>
      productId != null && allLifetime.contains(productId);

  static Set<String> _forApplePackageName(String? packageName) {
    final normalizedPackageName = packageName?.trim();
    return switch (normalizedPackageName) {
      'xyz.depollsoft.monkeyssh.private' => const {
        iosMonthly,
        iosAnnual,
        iosProLifetime,
      },
      'xyz.depollsoft.monkeyssh' => const {
        iosMonthlyProd,
        iosAnnualProd,
        iosProLifetimeProd,
      },
      _ => const {
        iosMonthly,
        iosAnnual,
        iosMonthlyProd,
        iosAnnualProd,
        iosProLifetime,
        iosProLifetimeProd,
      },
    };
  }
}

/// Premium features controlled by MonkeySSH Pro.
enum MonetizationFeature {
  /// Encrypted host and key transfer bundles.
  encryptedTransfers,

  /// Full app migration import/export packages.
  migrationImportExport,

  /// Auto-connect commands and snippets.
  autoConnectAutomation,

  /// Guided launch presets for coding-agent CLIs.
  agentLaunchPresets,

  /// Remote agent installation, repair, version checks, and updates.
  agentManagement,

  /// More than one concurrently live ACP coding-agent session.
  concurrentAcpSessions,

  /// Per-host terminal theme overrides.
  hostSpecificThemes,
}

/// Presentation helpers for [MonetizationFeature].
extension MonetizationFeaturePresentation on MonetizationFeature {
  /// Human-readable label for this premium feature.
  String get label => switch (this) {
    MonetizationFeature.encryptedTransfers => 'Encrypted transfers',
    MonetizationFeature.migrationImportExport => 'Migration import/export',
    MonetizationFeature.autoConnectAutomation => 'Auto-connect automation',
    MonetizationFeature.agentLaunchPresets => 'Agent launch presets',
    MonetizationFeature.agentManagement => 'Agent Management',
    MonetizationFeature.concurrentAcpSessions => 'Parallel native chats',
    MonetizationFeature.hostSpecificThemes => 'Host-specific themes',
  };

  /// Plain-language description shown in upgrade prompts.
  String get description => switch (this) {
    MonetizationFeature.encryptedTransfers =>
      'Share encrypted host and key bundles between devices.',
    MonetizationFeature.migrationImportExport =>
      'Move the whole app state with encrypted migration packages.',
    MonetizationFeature.autoConnectAutomation =>
      'Run commands or saved snippets automatically after connect.',
    MonetizationFeature.agentLaunchPresets =>
      'Save repeatable startup flows for tools like Codex, Claude Code, Copilot CLI, or OpenCode.',
    MonetizationFeature.agentManagement =>
      'Install, repair, and update coding agents on your remote hosts.',
    MonetizationFeature.concurrentAcpSessions =>
      'Keep multiple native agent chats connected across hosts and providers.',
    MonetizationFeature.hostSpecificThemes =>
      'Save terminal theme overrides for individual hosts while keeping app-wide defaults unchanged.',
  };

  /// The blocked action shown at the top of feature-triggered paywalls.
  String get blockedAction => switch (this) {
    MonetizationFeature.encryptedTransfers =>
      'Import or export encrypted transfer files',
    MonetizationFeature.migrationImportExport => 'Import or export app data',
    MonetizationFeature.autoConnectAutomation =>
      'Save auto-connect commands and snippets',
    MonetizationFeature.agentLaunchPresets =>
      'Save coding-agent launch presets',
    MonetizationFeature.agentManagement => 'Manage remote coding agents',
    MonetizationFeature.concurrentAcpSessions =>
      'Connect another native agent chat',
    MonetizationFeature.hostSpecificThemes => 'Save a host-specific theme',
  };

  /// The outcome unlocked by Pro for this feature.
  String get blockedOutcome => switch (this) {
    MonetizationFeature.encryptedTransfers =>
      'Unlock Pro to move hosts and keys between devices with encrypted files.',
    MonetizationFeature.migrationImportExport =>
      'Unlock Pro to restore or migrate all MonkeySSH data in one encrypted package.',
    MonetizationFeature.autoConnectAutomation =>
      'Unlock Pro to run a command or saved snippet automatically after connecting.',
    MonetizationFeature.agentLaunchPresets =>
      'Unlock Pro to repeat your preferred coding-agent startup flow on each host.',
    MonetizationFeature.concurrentAcpSessions =>
      'Unlock Pro to keep multiple native chats connected, switch instantly, and fork active sessions.',
    MonetizationFeature.hostSpecificThemes =>
      'Unlock Pro to keep this host on its own terminal theme while preserving your app defaults.',
    MonetizationFeature.agentManagement =>
      'Unlock Pro to install, repair, and update agents, with automatic update checks.',
  };
}

/// Whether store billing can be used on the current device.
enum MonetizationBillingAvailability {
  /// Billing has not been checked yet.
  unknown,

  /// Billing is unsupported on this platform.
  unsupported,

  /// Billing is supported but currently unavailable.
  unavailable,

  /// Billing is supported and product information was loaded.
  available,
}

/// Billing period for a MonkeySSH Pro plan.
enum MonetizationBillingPeriod {
  /// Monthly billing cadence.
  monthly,

  /// Annual billing cadence.
  annual,

  /// One-time, lifetime purchase (no recurring billing).
  lifetime,

  /// A billing cadence that could not be identified.
  unknown,
}

/// Presentation helpers for [MonetizationBillingPeriod].
extension MonetizationBillingPeriodPresentation on MonetizationBillingPeriod {
  /// Human-readable plan title.
  String get label => switch (this) {
    MonetizationBillingPeriod.monthly => 'Monthly',
    MonetizationBillingPeriod.annual => 'Annual',
    MonetizationBillingPeriod.lifetime => 'Lifetime',
    MonetizationBillingPeriod.unknown => 'MonkeySSH Pro',
  };
}

/// Current subscription entitlements.
class MonetizationEntitlements {
  /// Creates a new [MonetizationEntitlements].
  const MonetizationEntitlements({required this.proUnlocked});

  /// No premium features are unlocked.
  const MonetizationEntitlements.free() : proUnlocked = false;

  /// MonkeySSH Pro is unlocked.
  const MonetizationEntitlements.pro() : proUnlocked = true;

  /// Whether MonkeySSH Pro is active.
  final bool proUnlocked;

  /// Whether this entitlement unlocks [feature].
  bool allows(MonetizationFeature feature) => proUnlocked;
}

/// Store offer that can unlock MonkeySSH Pro.
class MonetizationOffer {
  /// Creates a new [MonetizationOffer].
  const MonetizationOffer({
    required this.id,
    required this.productId,
    required this.billingPeriod,
    required this.planLabel,
    required this.priceLabel,
    required this.displayPriceLabel,
    required this.rawPrice,
    required this.currencyCode,
    required this.currencySymbol,
    this.detailLabel,
    this.introductoryOfferLabel,
  });

  /// Unique identifier for this selectable offer.
  final String id;

  /// Store product identifier.
  final String productId;

  /// Billing period represented by this offer.
  final MonetizationBillingPeriod billingPeriod;

  /// Human-readable plan title.
  final String planLabel;

  /// Store-provided recurring price string.
  final String priceLabel;

  /// UI-ready recurring price label with billing cadence.
  final String displayPriceLabel;

  /// Raw recurring price in the store currency.
  final double rawPrice;

  /// ISO currency code for this offer.
  final String currencyCode;

  /// Currency symbol for this offer locale.
  final String currencySymbol;

  /// Secondary billing detail for this offer.
  final String? detailLabel;

  /// Introductory offer copy, such as a free trial.
  final String? introductoryOfferLabel;
}

/// Current billing and entitlement state for MonkeySSH Pro.
class MonetizationState {
  /// Creates a new [MonetizationState].
  const MonetizationState({
    required this.billingAvailability,
    required this.entitlements,
    required this.offers,
    required this.debugUnlockAvailable,
    required this.debugUnlocked,
    this.activeProductId,
    this.activeOfferId,
    this.entitlementUpdatedAt,
    this.lastError,
    this.isLoading = false,
  });

  /// Creates the initial free state.
  factory MonetizationState.initial({required bool debugUnlockAvailable}) =>
      MonetizationState(
        billingAvailability: MonetizationBillingAvailability.unknown,
        entitlements: const MonetizationEntitlements.free(),
        offers: const [],
        debugUnlockAvailable: debugUnlockAvailable,
        debugUnlocked: false,
      );

  /// Store billing availability on the current device.
  final MonetizationBillingAvailability billingAvailability;

  /// Current premium entitlements.
  final MonetizationEntitlements entitlements;

  /// Loaded subscription offers.
  final List<MonetizationOffer> offers;

  /// Whether a debug-only local unlock switch should be shown.
  final bool debugUnlockAvailable;

  /// Whether the debug-only local unlock is active.
  final bool debugUnlocked;

  /// Product ID that most recently unlocked Pro, if known.
  final String? activeProductId;

  /// Offer ID that most recently unlocked Pro, if known.
  final String? activeOfferId;

  /// Timestamp of the most recent entitlement update.
  final DateTime? entitlementUpdatedAt;

  /// Last billing-related error surfaced to the UI.
  final String? lastError;

  /// Whether a billing action is in flight.
  final bool isLoading;

  /// Whether MonkeySSH Pro is currently unlocked.
  bool get isProUnlocked => entitlements.proUnlocked;

  /// Whether the active product is the lifetime (one-time) purchase.
  ///
  /// `true` only when [isProUnlocked] is `true` and [activeProductId]
  /// matches a known lifetime SKU. The lifetime product is intentionally
  /// not exposed in the in-app paywall, so this is the canonical signal
  /// for UI surfaces that need to render lifetime-specific copy.
  bool get isLifetimeUnlocked =>
      isProUnlocked && MonetizationProductIds.isLifetime(activeProductId);

  /// Default offer to preselect on the paywall, if any.
  MonetizationOffer? get defaultOffer =>
      offers.firstWhereOrNull(
        (offer) => offer.billingPeriod == MonetizationBillingPeriod.monthly,
      ) ??
      (offers.isEmpty ? null : offers.first);

  /// Offer that matches the current active subscription, when it can be inferred.
  MonetizationOffer? get activeOffer {
    if (activeOfferId != null) {
      return offers.firstWhereOrNull((offer) => offer.id == activeOfferId);
    }
    if (activeProductId == null) {
      return null;
    }
    final matches = offers
        .where((offer) => offer.productId == activeProductId)
        .toList(growable: false);
    return matches.length == 1 ? matches.first : null;
  }

  /// Whether [offer] is the currently active subscription offer.
  bool isActiveOffer(MonetizationOffer offer) {
    if (activeOfferId != null) {
      return offer.id == activeOfferId;
    }
    if (activeProductId == null) {
      return false;
    }
    return activeOffer?.id == offer.id;
  }

  /// Whether [feature] is currently available.
  bool allowsFeature(MonetizationFeature feature) =>
      entitlements.allows(feature);

  /// Returns a copy of this state with selected fields replaced.
  MonetizationState copyWith({
    MonetizationBillingAvailability? billingAvailability,
    MonetizationEntitlements? entitlements,
    List<MonetizationOffer>? offers,
    bool? debugUnlockAvailable,
    bool? debugUnlocked,
    Object? activeProductId = _unsetField,
    Object? activeOfferId = _unsetField,
    Object? entitlementUpdatedAt = _unsetField,
    Object? lastError = _unsetField,
    bool? isLoading,
  }) => MonetizationState(
    billingAvailability: billingAvailability ?? this.billingAvailability,
    entitlements: entitlements ?? this.entitlements,
    offers: offers ?? this.offers,
    debugUnlockAvailable: debugUnlockAvailable ?? this.debugUnlockAvailable,
    debugUnlocked: debugUnlocked ?? this.debugUnlocked,
    activeProductId: identical(activeProductId, _unsetField)
        ? this.activeProductId
        : activeProductId as String?,
    activeOfferId: identical(activeOfferId, _unsetField)
        ? this.activeOfferId
        : activeOfferId as String?,
    entitlementUpdatedAt: identical(entitlementUpdatedAt, _unsetField)
        ? this.entitlementUpdatedAt
        : entitlementUpdatedAt as DateTime?,
    lastError: identical(lastError, _unsetField)
        ? this.lastError
        : lastError as String?,
    isLoading: isLoading ?? this.isLoading,
  );
}

/// Result of a purchase or restore action.
class MonetizationActionResult {
  /// Creates a new [MonetizationActionResult].
  const MonetizationActionResult({
    required this.success,
    required this.cancelled,
    required this.message,
  });

  /// Creates a successful result.
  const MonetizationActionResult.success(String message)
    : this(success: true, cancelled: false, message: message);

  /// Creates a failed result.
  const MonetizationActionResult.failure(String message)
    : this(success: false, cancelled: false, message: message);

  /// Creates a cancelled result.
  const MonetizationActionResult.cancelled(String message)
    : this(success: false, cancelled: true, message: message);

  /// Whether the action succeeded.
  final bool success;

  /// Whether the user cancelled the action.
  final bool cancelled;

  /// Human-readable result message.
  final String message;
}

const _unsetField = Object();

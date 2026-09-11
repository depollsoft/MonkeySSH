import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';
import 'package:in_app_purchase_storekit/store_kit_2_wrappers.dart';
import 'package:in_app_purchase_storekit/store_kit_wrappers.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/monetization.dart';
import 'diagnostics_log_service.dart';
import 'settings_service.dart';

const _lifetimeAlreadyActiveMessage =
    'MonkeySSH Pro Lifetime is already active. Manage your subscription in the '
    'store if you need to cancel a monthly or annual renewal.';
const _noActiveStorePurchaseMessage =
    'No active MonkeySSH Pro purchase could be restored.';

/// Coordinates local premium state and mobile store purchase flows.
class MonetizationService {
  /// Creates a new [MonetizationService].
  MonetizationService(
    this._settings, {
    InAppPurchase? inAppPurchase,
    InAppPurchaseAndroidPlatformAddition? androidPlatformAddition,
    bool? allowDebugUnlock,
    Duration purchaseTimeout = const Duration(seconds: 60),
    Duration restoreTimeout = const Duration(seconds: 45),
    Duration restoreEmptyResultGracePeriod = const Duration(seconds: 2),
    Future<String> Function()? packageNameLoader,
    DiagnosticsLogger? diagnostics,
  }) : _inAppPurchase = inAppPurchase ?? InAppPurchase.instance,
       _androidPlatformAddition = androidPlatformAddition,
       _allowDebugUnlock = allowDebugUnlock ?? kDebugMode,
       _purchaseTimeout = purchaseTimeout,
       _restoreTimeout = restoreTimeout,
       _restoreEmptyResultGracePeriod = restoreEmptyResultGracePeriod,
       _packageNameLoader = packageNameLoader ?? _loadPackageName,
       _diagnostics = diagnostics ?? DiagnosticsLogService.instance;

  final SettingsService _settings;
  final InAppPurchase _inAppPurchase;
  final InAppPurchaseAndroidPlatformAddition? _androidPlatformAddition;
  final bool _allowDebugUnlock;
  final Duration _purchaseTimeout;
  final Duration _restoreTimeout;
  // Grace period to wait after an Apple restore finishes before concluding
  // that there was nothing to restore. StoreKit delivers restored
  // transactions through the purchase stream on a channel separate from the
  // `restorePurchases` reply, so this absorbs that cross-channel delivery lag
  // instead of blocking on the full [_restoreTimeout].
  final Duration _restoreEmptyResultGracePeriod;
  final Future<String> Function() _packageNameLoader;
  final DiagnosticsLogger _diagnostics;
  Timer? _restoreEmptyResultTimer;
  final _controller = StreamController<MonetizationState>.broadcast();
  final _purchaseOptionsByOfferId = <String, _MonetizationPurchaseOption>{};

  StreamSubscription<List<PurchaseDetails>>? _purchaseSubscription;
  Completer<MonetizationActionResult>? _pendingPurchaseResult;
  String? _pendingOfferId;
  bool _pendingPurchaseFlowStarted = false;
  bool _pendingPurchaseObservedUpdate = false;
  bool _restoreInFlight = false;
  bool _restoreObservedPurchaseUpdate = false;
  Future<void>? _initializationFuture;
  // Serializes entitlement clears and per-purchase handlers so a batch of restore
  // updates (e.g. an old subscription transaction + a redeemed lifetime
  // transaction delivered together by StoreKit) is processed in order.
  // Without this, multiple `_handleSuccessfulPurchase` calls race and
  // the last finisher overwrites `activeProductId`/`activeOfferId`,
  // which can demote a freshly redeemed lifetime back to a stale
  // subscription label.
  Future<void> _purchaseHandlerChain = Future<void>.value();
  bool _initialized = false;
  MonetizationState _state = MonetizationState.initial(
    debugUnlockAvailable: kDebugMode,
  );

  /// Current monetization state.
  MonetizationState get currentState => _state;

  /// Stream of monetization state updates.
  Stream<MonetizationState> get states async* {
    yield _state;
    yield* _controller.stream;
  }

  /// Initializes cached state and starts listening for store purchase updates.
  Future<void> initialize() {
    if (_initialized) {
      return Future.value();
    }
    final initializationFuture = _initializationFuture;
    if (initializationFuture != null) {
      return initializationFuture;
    }
    final future = _initializeInternal();
    _initializationFuture = future;
    return future;
  }

  Future<void> _initializeInternal() async {
    try {
      _purchaseSubscription ??= _inAppPurchase.purchaseStream.listen(
        _handlePurchaseUpdates,
        onError: (Object error, StackTrace stackTrace) {
          if (kDebugMode) {
            debugPrint('Purchase stream error: $error\n$stackTrace');
          }
          _emit(
            _state.copyWith(
              isLoading: false,
              lastError: 'Could not update purchase status. Try again.',
            ),
          );
        },
      );

      final cachedProUnlocked = await _settings.getBool(
        SettingKeys.monetizationProUnlocked,
      );
      var debugUnlocked = false;
      if (_allowDebugUnlock) {
        debugUnlocked = await _settings.getBool(
          SettingKeys.monetizationDebugUnlocked,
        );
      }
      final updatedAt = _parseCachedDate(
        await _settings.getString(SettingKeys.monetizationEntitlementUpdatedAt),
      );
      final activeProductId = await _settings.getString(
        SettingKeys.monetizationActiveProductId,
      );
      final activeOfferId = await _settings.getString(
        SettingKeys.monetizationActiveOfferId,
      );

      _emit(
        _state.copyWith(
          billingAvailability: _supportsStoreBilling
              ? MonetizationBillingAvailability.unknown
              : MonetizationBillingAvailability.unsupported,
          entitlements: cachedProUnlocked || debugUnlocked
              ? const MonetizationEntitlements.pro()
              : const MonetizationEntitlements.free(),
          debugUnlockAvailable: _allowDebugUnlock,
          debugUnlocked: debugUnlocked,
          activeProductId: activeProductId,
          activeOfferId: activeOfferId,
          entitlementUpdatedAt: updatedAt,
        ),
      );

      if (_supportsStoreBilling) {
        await _refreshCatalogInternal();
        if (defaultTargetPlatform == TargetPlatform.android &&
            cachedProUnlocked) {
          await _reconcileAndroidStoreEntitlement();
        }
      }
      _initialized = true;
    } finally {
      _initializationFuture = null;
    }
  }

  /// Refreshes store product metadata.
  Future<void> refreshCatalog() async {
    await initialize();
    await _refreshCatalogInternal();
  }

  Future<void> _refreshCatalogInternal() async {
    if (!_supportsStoreBilling) {
      return;
    }

    _emit(_state.copyWith(isLoading: true, lastError: null));
    final isAvailable = await _inAppPurchase.isAvailable();
    if (!isAvailable) {
      _purchaseOptionsByOfferId.clear();
      _emit(
        _state.copyWith(
          isLoading: false,
          billingAvailability: MonetizationBillingAvailability.unavailable,
          offers: const [],
          lastError: null,
        ),
      );
      return;
    }

    final requestedProductIds = await _productIdsForCurrentStorefront();
    final response = await _inAppPurchase.queryProductDetails(
      requestedProductIds,
    );
    final catalog = _buildMonetizationCatalog(response.productDetails);
    _purchaseOptionsByOfferId
      ..clear()
      ..addAll(catalog.purchaseOptionsByOfferId);
    _logCatalogLoaded(
      requestedProductIds: requestedProductIds,
      response: response,
      offers: catalog.offers,
    );

    _emit(
      _state.copyWith(
        isLoading: false,
        billingAvailability: MonetizationBillingAvailability.available,
        offers: catalog.offers,
        lastError: response.error == null
            ? null
            : 'Could not load purchase options. Try again.',
      ),
    );
  }

  /// Records a safe, primitive breadcrumb describing which store products the
  /// current storefront actually returned.
  ///
  /// This deliberately logs only counts and booleans (never product IDs,
  /// prices, or any user content) so a diagnostics export can reveal cases
  /// where the store omits an expected plan — for example an App Store
  /// subscription that is not in a returnable state, which surfaces in the app
  /// as a paywall that is missing its monthly or annual option.
  void _logCatalogLoaded({
    required Set<String> requestedProductIds,
    required ProductDetailsResponse response,
    required List<MonetizationOffer> offers,
  }) {
    final billingPeriods = offers.map((offer) => offer.billingPeriod).toSet();
    _diagnostics.info(
      'monetization',
      'catalog_loaded',
      fields: {
        'platform': defaultTargetPlatform.name,
        'requestedCount': requestedProductIds.length,
        'loadedProductCount': response.productDetails.length,
        'offerCount': offers.length,
        'notFoundCount': response.notFoundIDs.length,
        'hasError': response.error != null,
        'monthlyLoaded': billingPeriods.contains(
          MonetizationBillingPeriod.monthly,
        ),
        'annualLoaded': billingPeriods.contains(
          MonetizationBillingPeriod.annual,
        ),
      },
    );
  }

  Future<Set<String>> _productIdsForCurrentStorefront() async {
    final packageName = switch (defaultTargetPlatform) {
      TargetPlatform.iOS || TargetPlatform.macOS => await _packageNameLoader(),
      _ => null,
    };
    return MonetizationProductIds.forPlatform(
      defaultTargetPlatform,
      packageName: packageName,
    );
  }

  /// Whether [feature] is currently unlocked.
  Future<bool> canUseFeature(MonetizationFeature feature) async {
    await initialize();
    return _state.allowsFeature(feature);
  }

  /// Starts a purchase flow for the selected MonkeySSH Pro offer.
  Future<MonetizationActionResult> purchaseOffer(String offerId) async {
    await initialize();
    if (!_supportsStoreBilling) {
      return const MonetizationActionResult.failure(
        'Purchases are only available through the App Store and Google Play.',
      );
    }
    if (_state.isLifetimeUnlocked) {
      return const MonetizationActionResult.failure(
        _lifetimeAlreadyActiveMessage,
      );
    }
    await _tryRecoverStaleAndroidPurchaseAttempt();
    if (_state.isLifetimeUnlocked) {
      return const MonetizationActionResult.failure(
        _lifetimeAlreadyActiveMessage,
      );
    }
    if (_pendingPurchaseResult != null || _restoreInFlight) {
      return const MonetizationActionResult.failure(
        'Another purchase or restore is already in progress.',
      );
    }
    var purchaseOption = _purchaseOptionsByOfferId[offerId];
    if (purchaseOption == null) {
      await refreshCatalog();
      purchaseOption = _purchaseOptionsByOfferId[offerId];
    }
    if (purchaseOption == null) {
      return const MonetizationActionResult.failure(
        'The subscription is not currently available.',
      );
    }

    final completer = Completer<MonetizationActionResult>();
    _pendingPurchaseResult = completer;
    _pendingOfferId = offerId;
    _pendingPurchaseFlowStarted = false;
    _pendingPurchaseObservedUpdate = false;
    _restoreInFlight = false;
    _restoreObservedPurchaseUpdate = false;
    _emit(_state.copyWith(isLoading: true, lastError: null));
    final purchaseParam = switch (purchaseOption) {
      _MonetizationPurchaseOption(
        productDetails: final GooglePlayProductDetails productDetails,
        offerToken: final offerToken?,
      ) =>
        GooglePlayPurchaseParam(
          productDetails: productDetails,
          offerToken: offerToken,
        ),
      _MonetizationPurchaseOption(productDetails: final productDetails) =>
        PurchaseParam(productDetails: productDetails),
    };
    var started = false;
    try {
      started = await _inAppPurchase.buyNonConsumable(
        purchaseParam: purchaseParam,
      );
    } on PlatformException {
      _diagnostics.warning('billing', 'purchase_launch_failed');
    } finally {
      // Release the pending attempt even if a programming error propagates.
      if (!started) {
        const result = MonetizationActionResult.failure(
          'Could not start the purchase flow.',
        );
        _emit(_state.copyWith(isLoading: false, lastError: result.message));
        _resolvePendingPurchase(result);
      }
    }
    if (!started) {
      return completer.future;
    }
    _pendingPurchaseFlowStarted = true;

    return completer.future.timeout(
      _purchaseTimeout,
      onTimeout: () {
        _pendingPurchaseResult = null;
        _pendingOfferId = null;
        _pendingPurchaseFlowStarted = false;
        _pendingPurchaseObservedUpdate = false;
        _restoreInFlight = false;
        _restoreObservedPurchaseUpdate = false;
        _emit(_state.copyWith(isLoading: false));
        return const MonetizationActionResult.failure(
          'The purchase is taking longer than expected. If it completed, try restoring purchases.',
        );
      },
    );
  }

  /// Restores previous purchases from the store.
  Future<MonetizationActionResult> restorePurchases() async {
    await initialize();
    if (!_supportsStoreBilling) {
      return const MonetizationActionResult.failure(
        'Restoring purchases is only available through the App Store and Google Play.',
      );
    }
    if (_state.isLifetimeUnlocked) {
      return const MonetizationActionResult.success(
        'MonkeySSH Pro Lifetime is already active.',
      );
    }
    await _tryRecoverStaleAndroidPurchaseAttempt();
    if (_pendingPurchaseResult != null || _restoreInFlight) {
      return const MonetizationActionResult.failure(
        'Another purchase or restore is already in progress.',
      );
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      return _restoreAndroidPurchases();
    }

    final completer = Completer<MonetizationActionResult>();
    _pendingPurchaseResult = completer;
    _pendingPurchaseFlowStarted = false;
    _pendingPurchaseObservedUpdate = false;
    _restoreInFlight = true;
    _restoreObservedPurchaseUpdate = false;
    _emit(_state.copyWith(isLoading: true, lastError: null));
    try {
      await _inAppPurchase.restorePurchases();
    } on Object catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('restorePurchases failed: $error\n$stackTrace');
      }
      if (_pendingPurchaseResult == completer) {
        const message = 'Could not restore purchases. Try again.';
        _emit(_state.copyWith(isLoading: false, lastError: message));
        _resolvePendingPurchase(
          const MonetizationActionResult.failure(message),
        );
      }
      return completer.future;
    }

    // StoreKit has finished the restore/sync by the time the call above
    // completes. A real subscription restore delivers its transaction through
    // the purchase stream (which resolves [completer]). When there is nothing
    // to restore, StoreKit1 emits an empty purchase list and StoreKit2 emits
    // nothing at all, so give any in-flight stream event a brief moment to be
    // processed and then finalize as "nothing to restore" instead of blocking
    // on the full restore timeout.
    _scheduleEmptyRestoreFinalization(completer);

    return completer.future.timeout(
      _restoreTimeout,
      onTimeout: () async {
        await _finishRestoreWithoutPurchases(completer);
        if (_pendingPurchaseResult == completer) {
          _emit(_state.copyWith(isLoading: false));
          _resolvePendingPurchase(
            const MonetizationActionResult.failure(
              _noActiveStorePurchaseMessage,
            ),
          );
        }
        return completer.future;
      },
    );
  }

  void _scheduleEmptyRestoreFinalization(
    Completer<MonetizationActionResult> completer,
  ) {
    if (_pendingPurchaseResult != completer) {
      return;
    }
    _restoreEmptyResultTimer?.cancel();
    _restoreEmptyResultTimer = Timer(_restoreEmptyResultGracePeriod, () {
      _restoreEmptyResultTimer = null;
      if (_pendingPurchaseResult == completer) {
        unawaited(_finishRestoreWithoutPurchases(completer));
      }
    });
  }

  /// Resolves a pending Apple restore that produced no restorable purchases.
  ///
  /// Clears any stale cached subscription entitlement (preserving a lifetime
  /// unlock) and completes the pending action with the no-purchase message.
  /// No-ops if a purchase update was already observed so the normal
  /// purchase-handling path can resolve the restore instead.
  Future<void> _finishRestoreWithoutPurchases(
    Completer<MonetizationActionResult>? completer,
  ) async {
    if (completer == null ||
        _pendingPurchaseResult != completer ||
        completer.isCompleted ||
        !_restoreInFlight ||
        _restoreObservedPurchaseUpdate) {
      return;
    }
    await _enqueuePurchaseHandler(() async {
      if (_pendingPurchaseResult != completer ||
          !_restoreInFlight ||
          _restoreObservedPurchaseUpdate) {
        return;
      }
      await _clearCachedStoreEntitlement(preserveLifetime: true);
      // Transactions arriving during clearing run next in the same queue.
      if (_pendingPurchaseResult == completer &&
          !_restoreObservedPurchaseUpdate) {
        _resolvePendingPurchase(
          const MonetizationActionResult.failure(_noActiveStorePurchaseMessage),
        );
      }
    });
  }

  /// Enables or disables the debug-only local unlock.
  Future<void> setDebugUnlocked({required bool unlocked}) async {
    if (!_allowDebugUnlock) {
      return;
    }
    await _settings.setBool(
      SettingKeys.monetizationDebugUnlocked,
      value: unlocked,
    );
    final hasStoreUnlock = await _settings.getBool(
      SettingKeys.monetizationProUnlocked,
    );
    _emit(
      _state.copyWith(
        debugUnlocked: unlocked,
        entitlements: unlocked || hasStoreUnlock
            ? const MonetizationEntitlements.pro()
            : const MonetizationEntitlements.free(),
        entitlementUpdatedAt: DateTime.now(),
      ),
    );
  }

  /// Releases store listeners held by this service.
  Future<void> dispose() async {
    _restoreEmptyResultTimer?.cancel();
    _restoreEmptyResultTimer = null;
    await _purchaseSubscription?.cancel();
    await _controller.close();
  }

  bool get _supportsStoreBilling =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  void _handlePurchaseUpdates(List<PurchaseDetails> purchases) {
    if (purchases.isEmpty) {
      // StoreKit1 emits an empty list when a restore finishes with no
      // transactions to restore. Resolve the pending restore right away
      // instead of waiting for the restore timeout to elapse.
      unawaited(_finishRestoreWithoutPurchases(_pendingPurchaseResult));
      return;
    }
    for (final purchase in purchases) {
      if (!MonetizationProductIds.allKnown.contains(purchase.productID)) {
        continue;
      }
      if (_pendingPurchaseResult != null) {
        _pendingPurchaseObservedUpdate = true;
      }

      switch (purchase.status) {
        case PurchaseStatus.pending:
          _emit(_state.copyWith(isLoading: true, lastError: null));
          break;
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          if (_restoreInFlight) {
            _restoreObservedPurchaseUpdate = true;
          }
          unawaited(
            _enqueuePurchaseHandler(() => _handleSuccessfulPurchase(purchase)),
          );
          break;
        case PurchaseStatus.error:
          unawaited(_completePurchaseIfNeeded(purchase));
          const failureMessage = 'Purchase failed. Try again.';
          _emit(_state.copyWith(isLoading: false, lastError: failureMessage));
          _resolvePendingPurchase(
            const MonetizationActionResult.failure(failureMessage),
          );
          break;
        case PurchaseStatus.canceled:
          _emit(_state.copyWith(isLoading: false));
          _resolvePendingPurchase(
            const MonetizationActionResult.cancelled('Purchase cancelled.'),
          );
          break;
      }
    }
  }

  Future<void> _enqueuePurchaseHandler(Future<void> Function() action) {
    final next = _purchaseHandlerChain.then((_) => action());
    // Swallow errors so one bad handler doesn't break the chain for
    // subsequent purchases. Errors are already surfaced via state.
    _purchaseHandlerChain = next.catchError((Object _) {});
    return next;
  }

  Future<void> _handleSuccessfulPurchase(PurchaseDetails purchase) async {
    final isLifetime = MonetizationProductIds.isLifetime(purchase.productID);
    final successMessage = isLifetime
        ? (purchase.status == PurchaseStatus.restored
              ? 'Restored MonkeySSH Pro Lifetime.'
              : 'MonkeySSH Pro Lifetime activated.')
        : 'MonkeySSH Pro unlocked.';
    final result = await _applySuccessfulPurchase(
      purchase,
      successMessage: successMessage,
    );
    _resolvePendingPurchase(result);
  }

  Future<MonetizationActionResult> _applySuccessfulPurchase(
    PurchaseDetails purchase, {
    required String successMessage,
  }) async {
    try {
      await _completePurchaseIfNeeded(purchase);
      final timestamp =
          _parsePurchaseDate(purchase.transactionDate) ?? DateTime.now();
      await _settings.setBool(SettingKeys.monetizationProUnlocked, value: true);
      final isLifetime = MonetizationProductIds.isLifetime(purchase.productID);
      // Lifetime always wins: never let a (possibly older or expiring)
      // subscription transaction overwrite a lifetime entitlement that
      // is already active. StoreKit replays every historical transaction
      // through the purchase stream during a restore, so the chronological
      // order in which they arrive is not meaningful for entitlement
      // precedence.
      final currentIsLifetime = MonetizationProductIds.isLifetime(
        _state.activeProductId,
      );
      if (currentIsLifetime && !isLifetime) {
        return MonetizationActionResult.success(successMessage);
      }

      await _settings.setString(
        SettingKeys.monetizationActiveProductId,
        purchase.productID,
      );
      // For lifetime purchases there is no concept of an offer ID — the
      // product is non-recurring and isn't surfaced as a paywall offer.
      // Force-clear any stale offer ID that may have been carried over
      // from a previous subscription so the UI doesn't render
      // "Current plan" / "Switch to ..." against a defunct sub offer.
      final activeOfferId = isLifetime
          ? null
          : _pendingOfferId ??
                _resolveOfferIdForPurchase(purchase) ??
                _state.activeOfferId;
      if (activeOfferId != null) {
        await _settings.setString(
          SettingKeys.monetizationActiveOfferId,
          activeOfferId,
        );
      } else {
        await _settings.delete(SettingKeys.monetizationActiveOfferId);
      }
      await _settings.setString(
        SettingKeys.monetizationEntitlementUpdatedAt,
        timestamp.toUtc().toIso8601String(),
      );
      _emit(
        _state.copyWith(
          isLoading: false,
          entitlements: const MonetizationEntitlements.pro(),
          activeProductId: purchase.productID,
          activeOfferId: activeOfferId,
          entitlementUpdatedAt: timestamp,
          lastError: null,
        ),
      );
      return MonetizationActionResult.success(successMessage);
    } on Object catch (error, stackTrace) {
      const message = 'Could not finalize purchase. Try again.';
      if (kDebugMode) {
        debugPrint('Failed to finalize purchase: $error\n$stackTrace');
      }
      _emit(_state.copyWith(isLoading: false, lastError: message));
      return const MonetizationActionResult.failure(message);
    }
  }

  Future<void> _completePurchaseIfNeeded(PurchaseDetails purchase) async {
    if (purchase.pendingCompletePurchase) {
      await _inAppPurchase.completePurchase(purchase);
    }
  }

  Future<void> _clearCachedStoreEntitlement({
    bool preserveLifetime = false,
  }) async {
    if (preserveLifetime && _state.isLifetimeUnlocked) {
      _emit(_state.copyWith(isLoading: false, lastError: null));
      return;
    }
    await _settings.setBool(SettingKeys.monetizationProUnlocked, value: false);
    await _settings.delete(SettingKeys.monetizationActiveProductId);
    await _settings.delete(SettingKeys.monetizationActiveOfferId);
    await _settings.delete(SettingKeys.monetizationEntitlementUpdatedAt);
    _emit(
      _state.copyWith(
        isLoading: false,
        entitlements: _state.debugUnlocked
            ? const MonetizationEntitlements.pro()
            : const MonetizationEntitlements.free(),
        activeProductId: null,
        activeOfferId: null,
        entitlementUpdatedAt: null,
        lastError: null,
      ),
    );
  }

  void _resolvePendingPurchase(MonetizationActionResult result) {
    _restoreEmptyResultTimer?.cancel();
    _restoreEmptyResultTimer = null;
    final completer = _pendingPurchaseResult;
    if (completer == null || completer.isCompleted) {
      return;
    }
    _pendingPurchaseResult = null;
    _pendingOfferId = null;
    _pendingPurchaseFlowStarted = false;
    _pendingPurchaseObservedUpdate = false;
    _restoreInFlight = false;
    _restoreObservedPurchaseUpdate = false;
    completer.complete(result);
  }

  String? _resolveOfferIdForPurchase(PurchaseDetails purchase) {
    final matches = _purchaseOptionsByOfferId.entries
        .where((entry) => entry.value.productDetails.id == purchase.productID)
        .map((entry) => entry.key)
        .toList(growable: false);
    return matches.length == 1 ? matches.first : null;
  }

  void _emit(MonetizationState state) {
    _state = state;
    if (!_controller.isClosed) {
      _controller.add(state);
    }
  }

  InAppPurchaseAndroidPlatformAddition get _playBillingAddition =>
      _androidPlatformAddition ??
      _inAppPurchase
          .getPlatformAddition<InAppPurchaseAndroidPlatformAddition>();

  Future<MonetizationActionResult> _restoreAndroidPurchases() async {
    _restoreInFlight = true;
    _emit(_state.copyWith(isLoading: true, lastError: null));
    try {
      final response = await _playBillingAddition.queryPastPurchases();
      if (response.error != null) {
        const message = 'Could not check Google Play purchases.';
        _emit(_state.copyWith(isLoading: false, lastError: message));
        return const MonetizationActionResult.failure(message);
      }

      final purchases = response.pastPurchases
          .where(
            (purchase) =>
                MonetizationProductIds.allKnown.contains(purchase.productID),
          )
          .toList(growable: false);
      if (purchases.isEmpty) {
        await _clearCachedStoreEntitlement();
        return const MonetizationActionResult.failure(
          _noActiveStorePurchaseMessage,
        );
      }

      final selectedPurchase = _preferredAndroidEntitlementPurchase(purchases);

      final isLifetime = MonetizationProductIds.isLifetime(
        selectedPurchase.productID,
      );
      return await _applySuccessfulPurchase(
        selectedPurchase,
        successMessage: isLifetime
            ? 'Restored MonkeySSH Pro Lifetime.'
            : 'Restored MonkeySSH Pro subscription.',
      );
    } finally {
      _restoreInFlight = false;
    }
  }

  Future<void> _reconcileAndroidStoreEntitlement() async {
    final response = await _playBillingAddition.queryPastPurchases();
    if (response.error != null) {
      return;
    }
    final knownPurchases = response.pastPurchases
        .where(
          (purchase) =>
              MonetizationProductIds.allKnown.contains(purchase.productID),
        )
        .toList(growable: false);
    if (knownPurchases.isEmpty) {
      await _clearCachedStoreEntitlement();
      return;
    }

    final selected = _preferredAndroidEntitlementPurchase(knownPurchases);

    final isLifetime = MonetizationProductIds.isLifetime(selected.productID);
    if (_state.activeProductId == selected.productID &&
        (!isLifetime || _state.activeOfferId == null)) {
      return;
    }

    await _settings.setString(
      SettingKeys.monetizationActiveProductId,
      selected.productID,
    );
    if (isLifetime) {
      await _settings.delete(SettingKeys.monetizationActiveOfferId);
    }
    _emit(
      _state.copyWith(
        activeProductId: selected.productID,
        activeOfferId: isLifetime ? null : _state.activeOfferId,
      ),
    );
  }

  Future<void> _tryRecoverStaleAndroidPurchaseAttempt() async {
    if (defaultTargetPlatform != TargetPlatform.android ||
        _pendingPurchaseResult == null ||
        _restoreInFlight ||
        !_pendingPurchaseFlowStarted ||
        _pendingPurchaseObservedUpdate) {
      return;
    }

    final response = await _playBillingAddition.queryPastPurchases();
    if (response.error != null) {
      return;
    }

    final purchases = response.pastPurchases
        .where(
          (purchase) =>
              MonetizationProductIds.allKnown.contains(purchase.productID),
        )
        .toList(growable: false);
    if (purchases.isEmpty) {
      _emit(_state.copyWith(isLoading: false, lastError: null));
      _resolvePendingPurchase(
        const MonetizationActionResult.cancelled('Purchase cancelled.'),
      );
      return;
    }

    final selectedPurchase = _preferredAndroidEntitlementPurchase(purchases);
    final isLifetime = MonetizationProductIds.isLifetime(
      selectedPurchase.productID,
    );
    final result = await _applySuccessfulPurchase(
      selectedPurchase,
      successMessage: isLifetime
          ? 'MonkeySSH Pro Lifetime activated.'
          : 'MonkeySSH Pro unlocked.',
    );
    _resolvePendingPurchase(result);
  }

  GooglePlayPurchaseDetails _preferredAndroidEntitlementPurchase(
    List<GooglePlayPurchaseDetails> purchases,
  ) {
    final lifetimePurchase = purchases.firstWhereOrNull(
      (purchase) => MonetizationProductIds.isLifetime(purchase.productID),
    );
    if (lifetimePurchase != null) {
      return lifetimePurchase;
    }

    return purchases.reduce(
      (latest, purchase) =>
          purchase.billingClientPurchase.purchaseTime >
              latest.billingClientPurchase.purchaseTime
          ? purchase
          : latest,
    );
  }

  DateTime? _parseCachedDate(String? rawValue) =>
      rawValue == null ? null : DateTime.tryParse(rawValue)?.toLocal();

  DateTime? _parsePurchaseDate(String? rawValue) {
    if (rawValue == null || rawValue.isEmpty) {
      return null;
    }
    final milliseconds = int.tryParse(rawValue);
    if (milliseconds == null) {
      return DateTime.tryParse(rawValue)?.toLocal();
    }
    return DateTime.fromMillisecondsSinceEpoch(milliseconds);
  }
}

/// Provider for [MonetizationService].
final monetizationServiceProvider = Provider<MonetizationService>((ref) {
  final service = MonetizationService(ref.watch(settingsServiceProvider));
  ref.onDispose(() => unawaited(service.dispose()));
  unawaited(service.initialize());
  return service;
});

Future<String> _loadPackageName() async {
  final packageInfo = await PackageInfo.fromPlatform();
  return packageInfo.packageName;
}

/// Stream provider for the latest [MonetizationState].
final monetizationStateProvider = StreamProvider<MonetizationState>((ref) {
  final service = ref.watch(monetizationServiceProvider);
  unawaited(service.initialize());
  return service.states;
});

/// Builds normalized MonkeySSH Pro offers from raw store product details.
@visibleForTesting
List<MonetizationOffer> buildMonetizationOffers(
  Iterable<ProductDetails> productDetails,
) => _buildMonetizationCatalog(productDetails).offers;

_MonetizationCatalog _buildMonetizationCatalog(
  Iterable<ProductDetails> productDetails,
) {
  final selectedByGroupKey = <String, _CatalogOfferCandidate>{};
  for (final details in productDetails) {
    final candidate = _buildCatalogOfferCandidate(details);
    if (candidate == null) {
      continue;
    }
    final existing = selectedByGroupKey[candidate.groupKey];
    if (existing == null ||
        candidate.preferenceRank > existing.preferenceRank ||
        (candidate.preferenceRank == existing.preferenceRank &&
            candidate.offer.rawPrice < existing.offer.rawPrice)) {
      selectedByGroupKey[candidate.groupKey] = candidate;
    }
  }

  final selectedCandidates = selectedByGroupKey.values.toList(growable: false)
    ..sort(_compareCatalogOfferCandidates);

  return _MonetizationCatalog(
    offers: selectedCandidates.map((candidate) => candidate.offer).toList(),
    purchaseOptionsByOfferId: {
      for (final candidate in selectedCandidates)
        candidate.offer.id: candidate.purchaseOption,
    },
  );
}

_CatalogOfferCandidate? _buildCatalogOfferCandidate(ProductDetails details) {
  // Lifetime products are intentionally never displayed in the paywall.
  // They are distributed exclusively via store promo/offer codes redeemed
  // outside the app and surface in the app via the purchase / restore
  // flow, where they update the entitlement directly without going
  // through `MonetizationState.offers`.
  if (MonetizationProductIds.isLifetime(details.id)) {
    return null;
  }
  return switch (details) {
    final GooglePlayProductDetails googlePlayDetails =>
      _buildGooglePlayOfferCandidate(googlePlayDetails),
    final AppStoreProductDetails appStoreDetails =>
      _buildAppStoreOfferCandidate(appStoreDetails),
    final AppStoreProduct2Details appStore2Details =>
      _buildAppStore2OfferCandidate(appStore2Details),
    _ => _buildFallbackOfferCandidate(details),
  };
}

_CatalogOfferCandidate? _buildGooglePlayOfferCandidate(
  GooglePlayProductDetails details,
) {
  final subscriptionIndex = details.subscriptionIndex;
  final offerDetails = subscriptionIndex == null
      ? null
      : details.productDetails.subscriptionOfferDetails?[subscriptionIndex];
  if (offerDetails == null) {
    return null;
  }
  if (offerDetails.pricingPhases.isEmpty) {
    return null;
  }

  final recurringPhase = _findRecurringPricingPhase(offerDetails.pricingPhases);
  final billingPeriod = _billingPeriodFromIdentifiers(
    productId: details.id,
    planId: offerDetails.basePlanId,
    recurringIsoPeriod: recurringPhase.billingPeriod,
  );
  final groupKey = '${details.id}:${offerDetails.basePlanId}';
  final offerId = '$groupKey:${offerDetails.offerId ?? 'base'}';
  final priceLabel = recurringPhase.formattedPrice;

  return _CatalogOfferCandidate(
    groupKey: groupKey,
    preferenceRank: _googlePlayOfferPriority(offerDetails),
    offer: MonetizationOffer(
      id: offerId,
      productId: details.id,
      billingPeriod: billingPeriod,
      planLabel: billingPeriod.label,
      priceLabel: priceLabel,
      displayPriceLabel: _buildDisplayPriceLabel(priceLabel, billingPeriod),
      rawPrice: recurringPhase.priceAmountMicros / 1000000,
      currencyCode: recurringPhase.priceCurrencyCode,
      currencySymbol: _extractCurrencySymbol(
        priceLabel,
        recurringPhase.priceCurrencyCode,
      ),
      detailLabel: _defaultOfferDetailLabel(billingPeriod),
      introductoryOfferLabel: _buildGooglePlayIntroductoryOfferLabel(
        offerDetails.pricingPhases,
      ),
    ),
    purchaseOption: _MonetizationPurchaseOption(
      productDetails: details,
      offerToken: details.offerToken,
    ),
  );
}

_CatalogOfferCandidate _buildAppStoreOfferCandidate(
  AppStoreProductDetails details,
) {
  final billingPeriod = _billingPeriodFromIdentifiers(
    productId: details.id,
    storeKitPeriod: details.skProduct.subscriptionPeriod,
  );
  return _CatalogOfferCandidate(
    groupKey: details.id,
    preferenceRank: details.skProduct.introductoryPrice == null ? 0 : 1,
    offer: MonetizationOffer(
      id: details.id,
      productId: details.id,
      billingPeriod: billingPeriod,
      planLabel: billingPeriod.label,
      priceLabel: details.price,
      displayPriceLabel: _buildDisplayPriceLabel(details.price, billingPeriod),
      rawPrice: details.rawPrice,
      currencyCode: details.currencyCode,
      currencySymbol: details.currencySymbol,
      detailLabel: _defaultOfferDetailLabel(billingPeriod),
      introductoryOfferLabel: _buildStoreKitIntroductoryOfferLabel(
        details.skProduct.introductoryPrice,
      ),
    ),
    purchaseOption: _MonetizationPurchaseOption(productDetails: details),
  );
}

_CatalogOfferCandidate _buildAppStore2OfferCandidate(
  AppStoreProduct2Details details,
) {
  final subscription = details.sk2Product.subscription;
  final introductoryOffer = subscription?.promotionalOffers.firstWhereOrNull(
    (offer) => offer.type == SK2SubscriptionOfferType.introductory,
  );
  final billingPeriod = _billingPeriodFromIdentifiers(
    productId: details.id,
    storeKit2Period: subscription?.subscriptionPeriod,
  );
  return _CatalogOfferCandidate(
    groupKey: details.id,
    preferenceRank: introductoryOffer == null ? 0 : 1,
    offer: MonetizationOffer(
      id: details.id,
      productId: details.id,
      billingPeriod: billingPeriod,
      planLabel: billingPeriod.label,
      priceLabel: details.price,
      displayPriceLabel: _buildDisplayPriceLabel(details.price, billingPeriod),
      rawPrice: details.rawPrice,
      currencyCode: details.currencyCode,
      currencySymbol: details.currencySymbol,
      detailLabel: _defaultOfferDetailLabel(billingPeriod),
      introductoryOfferLabel: _buildStoreKit2IntroductoryOfferLabel(
        introductoryOffer,
        details.currencySymbol,
      ),
    ),
    purchaseOption: _MonetizationPurchaseOption(productDetails: details),
  );
}

_CatalogOfferCandidate _buildFallbackOfferCandidate(ProductDetails details) {
  final billingPeriod = _billingPeriodFromIdentifiers(productId: details.id);
  return _CatalogOfferCandidate(
    groupKey: details.id,
    preferenceRank: 0,
    offer: MonetizationOffer(
      id: details.id,
      productId: details.id,
      billingPeriod: billingPeriod,
      planLabel: billingPeriod.label,
      priceLabel: details.price,
      displayPriceLabel: _buildDisplayPriceLabel(details.price, billingPeriod),
      rawPrice: details.rawPrice,
      currencyCode: details.currencyCode,
      currencySymbol: details.currencySymbol,
      detailLabel: _defaultOfferDetailLabel(billingPeriod),
    ),
    purchaseOption: _MonetizationPurchaseOption(productDetails: details),
  );
}

int _compareCatalogOfferCandidates(
  _CatalogOfferCandidate left,
  _CatalogOfferCandidate right,
) {
  final billingComparison = _billingPeriodSortOrder(
    left.offer.billingPeriod,
  ).compareTo(_billingPeriodSortOrder(right.offer.billingPeriod));
  if (billingComparison != 0) {
    return billingComparison;
  }
  return left.offer.rawPrice.compareTo(right.offer.rawPrice);
}

int _billingPeriodSortOrder(MonetizationBillingPeriod billingPeriod) =>
    switch (billingPeriod) {
      MonetizationBillingPeriod.monthly => 0,
      MonetizationBillingPeriod.annual => 1,
      MonetizationBillingPeriod.lifetime => 2,
      MonetizationBillingPeriod.unknown => 3,
    };

PricingPhaseWrapper _findRecurringPricingPhase(
  List<PricingPhaseWrapper> phases,
) =>
    phases.lastWhereOrNull(
      (phase) => phase.recurrenceMode == RecurrenceMode.infiniteRecurring,
    ) ??
    phases.last;

int _googlePlayOfferPriority(SubscriptionOfferDetailsWrapper offerDetails) {
  if (offerDetails.pricingPhases.isEmpty) {
    return 0;
  }
  final firstPhase = offerDetails.pricingPhases.first;
  if (firstPhase.priceAmountMicros == 0) {
    return 2;
  }
  return offerDetails.offerId == null ? 0 : 1;
}

MonetizationBillingPeriod _billingPeriodFromIdentifiers({
  required String productId,
  String? planId,
  String? recurringIsoPeriod,
  SKProductSubscriptionPeriodWrapper? storeKitPeriod,
  SK2SubscriptionPeriod? storeKit2Period,
}) {
  for (final value in [planId, productId]) {
    final normalized = value?.toLowerCase();
    if (normalized == null || normalized.isEmpty) {
      continue;
    }
    if (normalized.contains('annual') || normalized.contains('year')) {
      return MonetizationBillingPeriod.annual;
    }
    if (normalized.contains('monthly') || normalized.contains('month')) {
      return MonetizationBillingPeriod.monthly;
    }
  }
  if (recurringIsoPeriod != null) {
    return _billingPeriodFromIsoPeriod(recurringIsoPeriod);
  }
  if (storeKitPeriod != null) {
    return _billingPeriodFromStoreKitPeriod(
      units: storeKitPeriod.numberOfUnits,
      unitName: storeKitPeriod.unit.name,
    );
  }
  if (storeKit2Period != null) {
    return _billingPeriodFromStoreKitPeriod(
      units: storeKit2Period.value,
      unitName: storeKit2Period.unit.name,
    );
  }
  return MonetizationBillingPeriod.unknown;
}

MonetizationBillingPeriod _billingPeriodFromIsoPeriod(String isoPeriod) {
  final normalized = isoPeriod.toUpperCase();
  if (normalized.contains('Y')) {
    return MonetizationBillingPeriod.annual;
  }
  if (normalized.contains('M')) {
    return MonetizationBillingPeriod.monthly;
  }
  return MonetizationBillingPeriod.unknown;
}

MonetizationBillingPeriod _billingPeriodFromStoreKitPeriod({
  required int units,
  required String unitName,
}) {
  final normalizedUnit = unitName.toLowerCase();
  if (normalizedUnit == 'year' && units >= 1) {
    return MonetizationBillingPeriod.annual;
  }
  if (normalizedUnit == 'month' && units >= 1) {
    return MonetizationBillingPeriod.monthly;
  }
  return MonetizationBillingPeriod.unknown;
}

String _buildDisplayPriceLabel(
  String priceLabel,
  MonetizationBillingPeriod billingPeriod,
) => switch (billingPeriod) {
  MonetizationBillingPeriod.monthly => '$priceLabel / month',
  MonetizationBillingPeriod.annual => '$priceLabel / year',
  MonetizationBillingPeriod.lifetime => '$priceLabel — one-time',
  MonetizationBillingPeriod.unknown => priceLabel,
};

String? _defaultOfferDetailLabel(MonetizationBillingPeriod billingPeriod) =>
    switch (billingPeriod) {
      MonetizationBillingPeriod.monthly => 'Billed monthly',
      MonetizationBillingPeriod.annual => 'Billed yearly',
      MonetizationBillingPeriod.lifetime => 'One-time purchase',
      MonetizationBillingPeriod.unknown => null,
    };

String? _buildGooglePlayIntroductoryOfferLabel(
  List<PricingPhaseWrapper> pricingPhases,
) {
  if (pricingPhases.isEmpty) {
    return null;
  }
  final firstPhase = pricingPhases.first;
  final recurringPhase = _findRecurringPricingPhase(pricingPhases);
  final duration = _formatPricingPhaseDuration(firstPhase);
  if (firstPhase.priceAmountMicros == 0) {
    return duration == null
        ? 'Free trial for eligible new customers'
        : '$duration free trial for eligible new customers';
  }
  if (firstPhase.priceAmountMicros < recurringPhase.priceAmountMicros) {
    return duration == null
        ? 'Introductory pricing available'
        : '${firstPhase.formattedPrice} for $duration';
  }
  return null;
}

String? _buildStoreKitIntroductoryOfferLabel(
  SKProductDiscountWrapper? introductoryPrice,
) {
  if (introductoryPrice == null) {
    return null;
  }
  final duration = _formatStoreKitDuration(
    introductoryPrice.subscriptionPeriod.numberOfUnits,
    introductoryPrice.subscriptionPeriod.unit.name,
    repeatCount: introductoryPrice.numberOfPeriods,
  );
  if (introductoryPrice.paymentMode == SKProductDiscountPaymentMode.freeTrail) {
    return duration == null
        ? 'Free trial for eligible new customers'
        : '$duration free trial for eligible new customers';
  }
  final priceLabel =
      '${introductoryPrice.priceLocale.currencySymbol}${introductoryPrice.price}';
  return duration == null
      ? 'Introductory pricing available'
      : '$priceLabel for $duration';
}

String? _buildStoreKit2IntroductoryOfferLabel(
  SK2SubscriptionOffer? introductoryOffer,
  String currencySymbol,
) {
  if (introductoryOffer == null) {
    return null;
  }
  final duration = _formatStoreKitDuration(
    introductoryOffer.period.value,
    introductoryOffer.period.unit.name,
    repeatCount: introductoryOffer.periodCount,
  );
  if (introductoryOffer.paymentMode ==
      SK2SubscriptionOfferPaymentMode.freeTrial) {
    return duration == null
        ? 'Free trial for eligible new customers'
        : '$duration free trial for eligible new customers';
  }
  final priceLabel =
      '$currencySymbol${introductoryOffer.price.toStringAsFixed(2)}';
  return duration == null
      ? 'Introductory pricing available'
      : '$priceLabel for $duration';
}

String? _formatPricingPhaseDuration(PricingPhaseWrapper pricingPhase) =>
    _formatIsoDuration(
      pricingPhase.billingPeriod,
      repeatCount: pricingPhase.billingCycleCount == 0
          ? 1
          : pricingPhase.billingCycleCount,
    );

String? _formatStoreKitDuration(
  int unitCount,
  String unitName, {
  required int repeatCount,
}) {
  final totalUnits = unitCount * repeatCount;
  return switch (unitName.toLowerCase()) {
    'day' => _pluralize(totalUnits, 'day'),
    'week' => _pluralize(totalUnits, 'week'),
    'month' => _pluralize(totalUnits, 'month'),
    'year' => _pluralize(totalUnits, 'year'),
    _ => null,
  };
}

String? _formatIsoDuration(String isoDuration, {required int repeatCount}) {
  final match = RegExp(
    r'^P(?:(\d+)Y)?(?:(\d+)M)?(?:(\d+)W)?(?:(\d+)D)?$',
  ).firstMatch(isoDuration.toUpperCase());
  if (match == null) {
    return null;
  }
  final years = (int.tryParse(match.group(1) ?? '') ?? 0) * repeatCount;
  final months = (int.tryParse(match.group(2) ?? '') ?? 0) * repeatCount;
  final weeks = (int.tryParse(match.group(3) ?? '') ?? 0) * repeatCount;
  final days = (int.tryParse(match.group(4) ?? '') ?? 0) * repeatCount;
  final parts = <String>[
    if (years > 0) _pluralize(years, 'year'),
    if (months > 0) _pluralize(months, 'month'),
    if (weeks > 0) _pluralize(weeks, 'week'),
    if (days > 0) _pluralize(days, 'day'),
  ];
  if (parts.isEmpty) {
    return null;
  }
  return parts.join(' ');
}

String _pluralize(int count, String unit) =>
    count == 1 ? '1 $unit' : '$count ${unit}s';

String _extractCurrencySymbol(
  String formattedPrice,
  String fallbackCurrencyCode,
) {
  final currencySymbol = RegExp(
    r'^[^\d ]+|[^\d ]+$',
  ).firstMatch(formattedPrice)?.group(0);
  if (currencySymbol == null || currencySymbol.isEmpty) {
    return fallbackCurrencyCode;
  }
  return currencySymbol;
}

class _MonetizationCatalog {
  const _MonetizationCatalog({
    required this.offers,
    required this.purchaseOptionsByOfferId,
  });

  final List<MonetizationOffer> offers;
  final Map<String, _MonetizationPurchaseOption> purchaseOptionsByOfferId;
}

class _MonetizationPurchaseOption {
  const _MonetizationPurchaseOption({
    required this.productDetails,
    this.offerToken,
  });

  final ProductDetails productDetails;
  final String? offerToken;
}

class _CatalogOfferCandidate {
  const _CatalogOfferCandidate({
    required this.groupKey,
    required this.preferenceRank,
    required this.offer,
    required this.purchaseOption,
  });

  final String groupKey;
  final int preferenceRank;
  final MonetizationOffer offer;
  final _MonetizationPurchaseOption purchaseOption;
}

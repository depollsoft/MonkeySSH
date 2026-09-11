// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';
import 'package:in_app_purchase_storekit/store_kit_wrappers.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../helpers/recording_diagnostics_logger.dart';

class MockInAppPurchase extends Mock implements InAppPurchase {}

class MockPurchaseDetails extends Mock implements PurchaseDetails {}

class MockGooglePlayProductDetails extends Mock
    implements GooglePlayProductDetails {}

class MockInAppPurchaseAndroidPlatformAddition extends Mock
    implements InAppPurchaseAndroidPlatformAddition {}

class _FakePurchaseParam extends Fake implements PurchaseParam {}

class _DelayedEntitlementSettings extends SettingsService {
  _DelayedEntitlementSettings(super.db);

  final clearStarted = Completer<void>();
  final allowClear = Completer<void>();
  int clearCount = 0;

  @override
  Future<void> delete(String key) async {
    if (key == SettingKeys.monetizationActiveProductId) {
      clearCount++;
      if (!clearStarted.isCompleted) {
        clearStarted.complete();
      }
      await allowClear.future;
    }
    await super.delete(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(_FakePurchaseParam());
  });

  test('queries the App Store product IDs for the current Apple bundle', () {
    expect(
      MonetizationProductIds.forPlatform(
        TargetPlatform.iOS,
        packageName: 'xyz.depollsoft.monkeyssh.private',
      ),
      unorderedEquals([
        MonetizationProductIds.iosMonthly,
        MonetizationProductIds.iosAnnual,
        MonetizationProductIds.iosProLifetime,
      ]),
    );
    expect(
      MonetizationProductIds.forPlatform(
        TargetPlatform.iOS,
        packageName: 'xyz.depollsoft.monkeyssh',
      ),
      unorderedEquals([
        MonetizationProductIds.iosMonthlyProd,
        MonetizationProductIds.iosAnnualProd,
        MonetizationProductIds.iosProLifetimeProd,
      ]),
    );
    expect(
      MonetizationProductIds.forPlatform(TargetPlatform.android),
      unorderedEquals([
        MonetizationProductIds.androidPro,
        MonetizationProductIds.androidProLifetime,
      ]),
    );
    expect(
      MonetizationProductIds.allKnown,
      containsAll({
        MonetizationProductIds.iosMonthlyProd,
        MonetizationProductIds.iosAnnualProd,
        MonetizationProductIds.iosProLifetimeProd,
        MonetizationProductIds.androidProLifetime,
      }),
    );
    expect(
      MonetizationProductIds.forPlatform(TargetPlatform.macOS),
      containsAll({
        MonetizationProductIds.iosMonthly,
        MonetizationProductIds.iosAnnual,
        MonetizationProductIds.iosMonthlyProd,
        MonetizationProductIds.iosAnnualProd,
        MonetizationProductIds.iosProLifetime,
        MonetizationProductIds.iosProLifetimeProd,
      }),
    );
    expect(
      MonetizationProductIds.isLifetime(
        MonetizationProductIds.androidProLifetime,
      ),
      isTrue,
    );
    expect(
      MonetizationProductIds.isLifetime(
        MonetizationProductIds.iosProLifetimeProd,
      ),
      isTrue,
    );
    expect(
      MonetizationProductIds.isLifetime(MonetizationProductIds.androidPro),
      isFalse,
    );
    expect(MonetizationProductIds.isLifetime(null), isFalse);
  });

  group('buildMonetizationOffers', () {
    test('deduplicates Google Play base plans and keeps trial offers', () {
      final productDetails = GooglePlayProductDetails.fromProductDetails(
        ProductDetailsWrapper(
          description: 'MonkeySSH Pro subscription',
          name: 'MonkeySSH Pro',
          productId: MonetizationProductIds.androidPro,
          productType: ProductType.subs,
          title: 'MonkeySSH Pro',
          subscriptionOfferDetails: [
            _subscriptionOfferDetails(
              basePlanId: 'monthly',
              offerIdToken: 'monthly-base-token',
              pricingPhases: [
                _pricingPhase(
                  formattedPrice: r'$5.00',
                  priceAmountMicros: 5000000,
                  billingPeriod: 'P1M',
                  recurrenceMode: RecurrenceMode.infiniteRecurring,
                ),
              ],
            ),
            _subscriptionOfferDetails(
              basePlanId: 'monthly',
              offerId: 'free-trial',
              offerIdToken: 'monthly-trial-token',
              pricingPhases: [
                _pricingPhase(
                  formattedPrice: 'Free',
                  priceAmountMicros: 0,
                  billingPeriod: 'P2W',
                  recurrenceMode: RecurrenceMode.nonRecurring,
                ),
                _pricingPhase(
                  formattedPrice: r'$5.00',
                  priceAmountMicros: 5000000,
                  billingPeriod: 'P1M',
                  recurrenceMode: RecurrenceMode.infiniteRecurring,
                ),
              ],
            ),
            _subscriptionOfferDetails(
              basePlanId: 'annual',
              offerId: 'free-trial',
              offerIdToken: 'annual-trial-token',
              pricingPhases: [
                _pricingPhase(
                  formattedPrice: 'Free',
                  priceAmountMicros: 0,
                  billingPeriod: 'P2W',
                  recurrenceMode: RecurrenceMode.nonRecurring,
                ),
                _pricingPhase(
                  formattedPrice: r'$50.00',
                  priceAmountMicros: 50000000,
                  billingPeriod: 'P1Y',
                  recurrenceMode: RecurrenceMode.infiniteRecurring,
                ),
              ],
            ),
          ],
        ),
      );

      final offers = buildMonetizationOffers(productDetails);

      expect(offers, hasLength(2));
      expect(offers.map((offer) => offer.billingPeriod), [
        MonetizationBillingPeriod.monthly,
        MonetizationBillingPeriod.annual,
      ]);
      expect(offers[0].displayPriceLabel, r'$5.00 / month');
      expect(
        offers[0].introductoryOfferLabel,
        '2 weeks free trial for eligible new customers',
      );
      expect(offers[1].displayPriceLabel, r'$50.00 / year');
      expect(
        offers[1].introductoryOfferLabel,
        '2 weeks free trial for eligible new customers',
      );
    });

    test('keeps separate App Store monthly and annual products', () {
      final offers = buildMonetizationOffers([
        AppStoreProductDetails.fromSKProduct(
          SKProductWrapper(
            productIdentifier: MonetizationProductIds.iosMonthly,
            localizedTitle: 'MonkeySSH Pro Monthly',
            localizedDescription: 'Monthly MonkeySSH Pro subscription',
            priceLocale: _usdPriceLocale,
            price: '5.00',
            subscriptionPeriod: SKProductSubscriptionPeriodWrapper(
              numberOfUnits: 1,
              unit: SKSubscriptionPeriodUnit.month,
            ),
            introductoryPrice: SKProductDiscountWrapper(
              price: '0.00',
              priceLocale: _usdPriceLocale,
              numberOfPeriods: 2,
              paymentMode: SKProductDiscountPaymentMode.freeTrail,
              subscriptionPeriod: SKProductSubscriptionPeriodWrapper(
                numberOfUnits: 1,
                unit: SKSubscriptionPeriodUnit.week,
              ),
              identifier: 'intro',
              type: SKProductDiscountType.introductory,
            ),
          ),
        ),
        AppStoreProductDetails.fromSKProduct(
          SKProductWrapper(
            productIdentifier: MonetizationProductIds.iosAnnual,
            localizedTitle: 'MonkeySSH Pro Annual',
            localizedDescription: 'Annual MonkeySSH Pro subscription',
            priceLocale: _usdPriceLocale,
            price: '50.00',
            subscriptionPeriod: SKProductSubscriptionPeriodWrapper(
              numberOfUnits: 1,
              unit: SKSubscriptionPeriodUnit.year,
            ),
          ),
        ),
      ]);

      expect(offers, hasLength(2));
      expect(offers.map((offer) => offer.productId), [
        MonetizationProductIds.iosMonthly,
        MonetizationProductIds.iosAnnual,
      ]);
      expect(offers[0].displayPriceLabel, r'$5.00 / month');
      expect(
        offers[0].introductoryOfferLabel,
        '2 weeks free trial for eligible new customers',
      );
      expect(offers[1].displayPriceLabel, r'$50.00 / year');
      expect(offers[1].introductoryOfferLabel, isNull);
    });

    test('skips Google Play offers with no pricing phases', () {
      final productDetails = MockGooglePlayProductDetails();
      when(() => productDetails.subscriptionIndex).thenReturn(0);
      when(
        () => productDetails.id,
      ).thenReturn(MonetizationProductIds.androidPro);
      when(() => productDetails.offerToken).thenReturn('monthly-base-token');
      when(() => productDetails.productDetails).thenReturn(
        ProductDetailsWrapper(
          description: 'MonkeySSH Pro subscription',
          name: 'MonkeySSH Pro',
          productId: MonetizationProductIds.androidPro,
          productType: ProductType.subs,
          title: 'MonkeySSH Pro',
          subscriptionOfferDetails: [
            _subscriptionOfferDetails(
              basePlanId: 'monthly',
              offerIdToken: 'monthly-base-token',
              pricingPhases: const [],
            ),
          ],
        ),
      );

      final offers = buildMonetizationOffers([productDetails]);

      expect(offers, isEmpty);
    });

    test('keeps a trailing currency code when no symbol is prefixed', () {
      final offers = buildMonetizationOffers(
        GooglePlayProductDetails.fromProductDetails(
          ProductDetailsWrapper(
            description: 'MonkeySSH Pro subscription',
            name: 'MonkeySSH Pro',
            productId: MonetizationProductIds.androidPro,
            productType: ProductType.subs,
            title: 'MonkeySSH Pro',
            subscriptionOfferDetails: [
              _subscriptionOfferDetails(
                basePlanId: 'monthly',
                offerIdToken: 'monthly-base-token',
                pricingPhases: [
                  _pricingPhase(
                    formattedPrice: '5.00 USD',
                    priceAmountMicros: 5000000,
                    billingPeriod: 'P1M',
                    recurrenceMode: RecurrenceMode.infiniteRecurring,
                  ),
                ],
              ),
            ],
          ),
        ),
      );

      expect(offers.single.currencySymbol, 'USD');
    });

    test('excludes lifetime products from the paywall offers list', () {
      final offers = buildMonetizationOffers([
        AppStoreProductDetails.fromSKProduct(
          SKProductWrapper(
            productIdentifier: MonetizationProductIds.iosMonthly,
            localizedTitle: 'MonkeySSH Pro Monthly',
            localizedDescription: 'Monthly MonkeySSH Pro subscription',
            priceLocale: _usdPriceLocale,
            price: '5.00',
            subscriptionPeriod: SKProductSubscriptionPeriodWrapper(
              numberOfUnits: 1,
              unit: SKSubscriptionPeriodUnit.month,
            ),
          ),
        ),
        // A non-consumable lifetime App Store product has no
        // subscriptionPeriod. It must never appear in the paywall.
        AppStoreProductDetails.fromSKProduct(
          SKProductWrapper(
            productIdentifier: MonetizationProductIds.iosProLifetimeProd,
            localizedTitle: 'MonkeySSH Pro Lifetime',
            localizedDescription: 'Lifetime MonkeySSH Pro purchase',
            priceLocale: _usdPriceLocale,
            price: '99.00',
          ),
        ),
      ]);

      expect(offers, hasLength(1));
      expect(offers.single.productId, MonetizationProductIds.iosMonthly);
    });

    test(
      'excludes lifetime Google Play one-time products from the paywall',
      () {
        final offers = buildMonetizationOffers(
          GooglePlayProductDetails.fromProductDetails(
            const ProductDetailsWrapper(
              description: 'MonkeySSH Pro Lifetime',
              name: 'MonkeySSH Pro Lifetime',
              productId: MonetizationProductIds.androidProLifetime,
              productType: ProductType.inapp,
              title: 'MonkeySSH Pro Lifetime',
              oneTimePurchaseOfferDetails: OneTimePurchaseOfferDetailsWrapper(
                priceAmountMicros: 99000000,
                priceCurrencyCode: 'USD',
                formattedPrice: r'$99.00',
              ),
            ),
          ),
        );

        expect(offers, isEmpty);
      },
    );
  });

  group('MonetizationService', () {
    late AppDatabase database;
    late SettingsService settings;
    late MockInAppPurchase inAppPurchase;
    late MockInAppPurchaseAndroidPlatformAddition androidPlatformAddition;
    late StreamController<List<PurchaseDetails>> purchaseController;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      settings = SettingsService(database);
      inAppPurchase = MockInAppPurchase();
      androidPlatformAddition = MockInAppPurchaseAndroidPlatformAddition();
      purchaseController = StreamController<List<PurchaseDetails>>.broadcast();
      PackageInfo.setMockInitialValues(
        appName: 'MonkeySSH',
        packageName: 'xyz.depollsoft.monkeyssh',
        version: '0.1.1',
        buildNumber: '1',
        buildSignature: '',
      );

      when(
        () => inAppPurchase.purchaseStream,
      ).thenAnswer((_) => purchaseController.stream);
      when(() => inAppPurchase.isAvailable()).thenAnswer((_) async => false);
    });

    tearDown(() async {
      await purchaseController.close();
      await database.close();
    });

    MonetizationService buildService({
      SettingsService? store,
      DiagnosticsLogger? diagnostics,
      bool android = false,
      Duration restoreTimeout = const Duration(seconds: 45),
      Duration restoreEmptyResultGracePeriod = const Duration(seconds: 2),
    }) {
      final service = MonetizationService(
        store ?? settings,
        diagnostics: diagnostics,
        inAppPurchase: inAppPurchase,
        androidPlatformAddition: android ? androidPlatformAddition : null,
        allowDebugUnlock: false,
        restoreTimeout: restoreTimeout,
        restoreEmptyResultGracePeriod: restoreEmptyResultGracePeriod,
      );
      addTearDown(service.dispose);
      return service;
    }

    test('initializes cached entitlements from settings', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final updatedAt = DateTime.utc(2026, 4, 10, 7);
      await settings.setBool(SettingKeys.monetizationProUnlocked, value: true);
      await settings.setString(
        SettingKeys.monetizationActiveProductId,
        MonetizationProductIds.iosAnnual,
      );
      await settings.setString(
        SettingKeys.monetizationActiveOfferId,
        MonetizationProductIds.iosAnnual,
      );
      await settings.setString(
        SettingKeys.monetizationEntitlementUpdatedAt,
        updatedAt.toIso8601String(),
      );

      final service = buildService();

      await service.initialize();

      expect(service.currentState.isProUnlocked, isTrue);
      expect(
        service.currentState.activeProductId,
        MonetizationProductIds.iosAnnual,
      );
      expect(
        service.currentState.activeOfferId,
        MonetizationProductIds.iosAnnual,
      );
      expect(service.currentState.entitlementUpdatedAt, updatedAt.toLocal());
      expect(
        service.currentState.billingAvailability,
        MonetizationBillingAvailability.unavailable,
      );
    });

    test('canUseFeature reflects the cached Pro entitlement state', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final freeService = MonetizationService(
        settings,
        inAppPurchase: inAppPurchase,
        allowDebugUnlock: false,
      );
      addTearDown(freeService.dispose);

      await freeService.initialize();
      expect(
        await freeService.canUseFeature(MonetizationFeature.agentLaunchPresets),
        isFalse,
      );

      await settings.setBool(SettingKeys.monetizationProUnlocked, value: true);

      final unlockedService = MonetizationService(
        settings,
        inAppPurchase: inAppPurchase,
        allowDebugUnlock: false,
      );
      addTearDown(unlockedService.dispose);

      await unlockedService.initialize();
      expect(
        await unlockedService.canUseFeature(
          MonetizationFeature.autoConnectAutomation,
        ),
        isTrue,
      );
    });

    test(
      'macOS uses the Apple storefront path for billing availability',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        final service = buildService();

        await service.initialize();

        expect(
          service.currentState.billingAvailability,
          MonetizationBillingAvailability.unavailable,
        );
      },
    );

    test(
      'production App Store builds query only production product IDs',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        when(() => inAppPurchase.isAvailable()).thenAnswer((_) async => true);
        when(() => inAppPurchase.queryProductDetails(any())).thenAnswer(
          (_) async => ProductDetailsResponse(
            productDetails: const [],
            notFoundIDs: const [],
          ),
        );

        final service = MonetizationService(
          settings,
          inAppPurchase: inAppPurchase,
          allowDebugUnlock: false,
          packageNameLoader: () async => 'xyz.depollsoft.monkeyssh',
        );
        addTearDown(service.dispose);

        await service.initialize();

        final queriedProductIds =
            verify(
                  () => inAppPurchase.queryProductDetails(captureAny()),
                ).captured.single
                as Set<String>;
        expect(
          queriedProductIds,
          unorderedEquals([
            MonetizationProductIds.iosMonthlyProd,
            MonetizationProductIds.iosAnnualProd,
            MonetizationProductIds.iosProLifetimeProd,
          ]),
        );
      },
    );

    test('private App Store builds query only private product IDs', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      when(() => inAppPurchase.isAvailable()).thenAnswer((_) async => true);
      when(() => inAppPurchase.queryProductDetails(any())).thenAnswer(
        (_) async => ProductDetailsResponse(
          productDetails: const [],
          notFoundIDs: const [],
        ),
      );

      final service = MonetizationService(
        settings,
        inAppPurchase: inAppPurchase,
        allowDebugUnlock: false,
        packageNameLoader: () async => 'xyz.depollsoft.monkeyssh.private',
      );
      addTearDown(service.dispose);

      await service.initialize();

      final queriedProductIds =
          verify(
                () => inAppPurchase.queryProductDetails(captureAny()),
              ).captured.single
              as Set<String>;
      expect(
        queriedProductIds,
        unorderedEquals([
          MonetizationProductIds.iosMonthly,
          MonetizationProductIds.iosAnnual,
          MonetizationProductIds.iosProLifetime,
        ]),
      );
    });

    test(
      'catalog diagnostics record when the App Store omits the monthly plan',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        when(() => inAppPurchase.isAvailable()).thenAnswer((_) async => true);
        // The App Store returns only the annual product; the monthly product
        // is reported as not found (e.g. it is not in a returnable state in
        // App Store Connect), which is what makes the paywall show annual only.
        when(() => inAppPurchase.queryProductDetails(any())).thenAnswer(
          (_) async => ProductDetailsResponse(
            productDetails: [
              AppStoreProductDetails.fromSKProduct(
                SKProductWrapper(
                  productIdentifier: MonetizationProductIds.iosAnnualProd,
                  localizedTitle: 'MonkeySSH Pro Annual',
                  localizedDescription: 'Annual MonkeySSH Pro subscription',
                  priceLocale: _usdPriceLocale,
                  price: '50.00',
                  subscriptionPeriod: SKProductSubscriptionPeriodWrapper(
                    numberOfUnits: 1,
                    unit: SKSubscriptionPeriodUnit.year,
                  ),
                ),
              ),
            ],
            notFoundIDs: [MonetizationProductIds.iosMonthlyProd],
          ),
        );

        final diagnostics = RecordingDiagnosticsLogger();
        final service = MonetizationService(
          settings,
          inAppPurchase: inAppPurchase,
          allowDebugUnlock: false,
          packageNameLoader: () async => 'xyz.depollsoft.monkeyssh',
          diagnostics: diagnostics,
        );
        addTearDown(service.dispose);

        await service.initialize();

        final catalogEntry = diagnostics.events.lastWhere(
          (entry) =>
              entry.category == 'monetization' &&
              entry.message == 'catalog_loaded',
        );
        expect(catalogEntry.fields['annualLoaded'], isTrue);
        expect(catalogEntry.fields['monthlyLoaded'], isFalse);
        expect(catalogEntry.fields['notFoundCount'], 1);
        expect(catalogEntry.fields['offerCount'], 1);
        // The breadcrumb must never leak raw product identifiers.
        expect(
          catalogEntry.fields.values.whereType<String>(),
          everyElement(isNot(contains('monkeyssh_pro'))),
        );
      },
    );

    test(
      'concurrent initialize calls wait for the same in-flight work',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final availabilityCompleter = Completer<bool>();
        when(
          () => inAppPurchase.isAvailable(),
        ).thenAnswer((_) => availabilityCompleter.future);

        final service = buildService();

        var secondInitializeCompleted = false;
        final firstInitialize = service.initialize();
        final secondInitialize = service.initialize().then((_) {
          secondInitializeCompleted = true;
        });
        await Future<void>.delayed(Duration.zero);

        expect(secondInitializeCompleted, isFalse);

        availabilityCompleter.complete(false);
        await Future.wait([firstInitialize, secondInitialize]);

        expect(secondInitializeCompleted, isTrue);
        verify(() => inAppPurchase.isAvailable()).called(1);
      },
    );

    test(
      'purchase stream activates lifetime entitlement when a redeemed lifetime product arrives',
      () async {
        final service = buildService();

        final purchase = _purchase(
          MonetizationProductIds.iosProLifetimeProd,
          PurchaseStatus.purchased,
        );
        when(
          () => inAppPurchase.completePurchase(purchase),
        ).thenAnswer((_) async {});

        await service.initialize();
        purchaseController.add([purchase]);
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(service.currentState.isProUnlocked, isTrue);
        expect(service.currentState.isLifetimeUnlocked, isTrue);
        expect(
          service.currentState.activeProductId,
          MonetizationProductIds.iosProLifetimeProd,
        );
        expect(service.currentState.activeOfferId, isNull);
        expect(
          await settings.getString(SettingKeys.monetizationActiveProductId),
          MonetizationProductIds.iosProLifetimeProd,
        );
        verify(() => inAppPurchase.completePurchase(purchase)).called(1);
      },
    );

    test(
      'lifetime purchase clears any stale activeOfferId carried over from a prior subscription',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        // Simulate a user who previously had a subscription: pre-seed
        // the cached entitlement settings with an active subscription
        // product and offer.
        await settings.setBool(
          SettingKeys.monetizationProUnlocked,
          value: true,
        );
        await settings.setString(
          SettingKeys.monetizationActiveProductId,
          MonetizationProductIds.iosMonthly,
        );
        await settings.setString(
          SettingKeys.monetizationActiveOfferId,
          'monthly-base-offer',
        );

        final service = buildService();

        final purchase = _purchase(
          MonetizationProductIds.iosProLifetimeProd,
          PurchaseStatus.purchased,
        );
        when(
          () => inAppPurchase.completePurchase(purchase),
        ).thenAnswer((_) async {});

        await service.initialize();
        // Sanity check: the prior subscription offer was loaded from settings.
        expect(service.currentState.activeOfferId, 'monthly-base-offer');

        purchaseController.add([purchase]);
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(service.currentState.isLifetimeUnlocked, isTrue);
        expect(
          service.currentState.activeProductId,
          MonetizationProductIds.iosProLifetimeProd,
        );
        // The stale subscription offer must be cleared from both the
        // in-memory state and the persisted settings.
        expect(service.currentState.activeOfferId, isNull);
        expect(
          await settings.getString(SettingKeys.monetizationActiveOfferId),
          isNull,
        );
      },
    );

    test(
      'lifetime entitlement is preserved when a stale subscription transaction is replayed by the purchase stream',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        final service = buildService();

        final lifetime = MockPurchaseDetails();
        when(
          () => lifetime.productID,
        ).thenReturn(MonetizationProductIds.iosProLifetimeProd);
        when(() => lifetime.status).thenReturn(PurchaseStatus.restored);
        when(() => lifetime.pendingCompletePurchase).thenReturn(true);
        when(() => lifetime.transactionDate).thenReturn('1712732400000');
        when(
          () => inAppPurchase.completePurchase(lifetime),
        ).thenAnswer((_) async {});

        final staleSub = MockPurchaseDetails();
        when(
          () => staleSub.productID,
        ).thenReturn(MonetizationProductIds.iosMonthly);
        when(() => staleSub.status).thenReturn(PurchaseStatus.restored);
        when(() => staleSub.pendingCompletePurchase).thenReturn(true);
        when(() => staleSub.transactionDate).thenReturn('1712732401000');
        when(
          () => inAppPurchase.completePurchase(staleSub),
        ).thenAnswer((_) async {});

        await service.initialize();
        // Deliver both transactions in the same batch, mimicking what
        // StoreKit does during a restore.
        purchaseController.add([lifetime, staleSub]);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // Lifetime must win regardless of replay order.
        expect(service.currentState.isLifetimeUnlocked, isTrue);
        expect(
          service.currentState.activeProductId,
          MonetizationProductIds.iosProLifetimeProd,
        );
        expect(service.currentState.activeOfferId, isNull);
        expect(
          await settings.getString(SettingKeys.monetizationActiveProductId),
          MonetizationProductIds.iosProLifetimeProd,
        );
      },
    );

    test(
      'Android reconcile promotes lifetime when a previously cached subscription has lapsed',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        // Pre-seed cached entitlement as the now-defunct subscription.
        await settings.setBool(
          SettingKeys.monetizationProUnlocked,
          value: true,
        );
        await settings.setString(
          SettingKeys.monetizationActiveProductId,
          MonetizationProductIds.androidPro,
        );
        await settings.setString(
          SettingKeys.monetizationActiveOfferId,
          'monthly-base',
        );

        when(() => inAppPurchase.isAvailable()).thenAnswer((_) async => true);
        when(() => inAppPurchase.queryProductDetails(any())).thenAnswer(
          (_) async => ProductDetailsResponse(
            productDetails: const [],
            notFoundIDs: const [],
          ),
        );
        when(androidPlatformAddition.queryPastPurchases).thenAnswer(
          (_) async => QueryPurchaseDetailsResponse(
            pastPurchases: [
              _androidPastLifetimePurchase(purchaseTimeMillis: 1712732400000),
            ],
          ),
        );

        final service = buildService(android: true);

        await service.initialize();

        expect(service.currentState.isProUnlocked, isTrue);
        expect(service.currentState.isLifetimeUnlocked, isTrue);
        expect(
          service.currentState.activeProductId,
          MonetizationProductIds.androidProLifetime,
        );
        expect(service.currentState.activeOfferId, isNull);
        expect(
          await settings.getString(SettingKeys.monetizationActiveProductId),
          MonetizationProductIds.androidProLifetime,
        );
        expect(
          await settings.getString(SettingKeys.monetizationActiveOfferId),
          isNull,
        );
      },
    );

    test('Android restore guards pending purchase completion', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      when(() => inAppPurchase.isAvailable()).thenAnswer((_) async => true);
      when(() => inAppPurchase.queryProductDetails(any())).thenAnswer(
        (_) async => ProductDetailsResponse(
          productDetails: const [],
          notFoundIDs: const [],
        ),
      );
      final purchase = _androidPastLifetimePurchase(
        purchaseTimeMillis: 1712732400000,
      )..pendingCompletePurchase = true;
      final completion = Completer<void>();
      final completionStarted = Completer<void>();
      when(() => inAppPurchase.completePurchase(purchase)).thenAnswer((_) {
        completionStarted.complete();
        return completion.future;
      });
      when(androidPlatformAddition.queryPastPurchases).thenAnswer(
        (_) async => QueryPurchaseDetailsResponse(pastPurchases: [purchase]),
      );

      final service = buildService(android: true);

      final restore = service.restorePurchases();
      await completionStarted.future;
      expect(
        (await service.restorePurchases()).message,
        'Another purchase or restore is already in progress.',
      );
      verify(androidPlatformAddition.queryPastPurchases).called(1);
      completion.complete();
      final result = await restore;

      expect(result.success, isTrue);
      expect(result.message, contains('Lifetime'));
      expect(service.currentState.isProUnlocked, isTrue);
      expect(service.currentState.isLifetimeUnlocked, isTrue);
      expect(
        service.currentState.activeProductId,
        MonetizationProductIds.androidProLifetime,
      );
      expect(
        await settings.getBool(SettingKeys.monetizationProUnlocked),
        isTrue,
      );
    });

    test(
      'restorePurchases keeps an already active lifetime entitlement',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        await settings.setBool(
          SettingKeys.monetizationProUnlocked,
          value: true,
        );
        await settings.setString(
          SettingKeys.monetizationActiveProductId,
          MonetizationProductIds.iosProLifetimeProd,
        );

        final service = buildService();

        final result = await service.restorePurchases();

        expect(result.success, isTrue);
        expect(result.message, contains('Lifetime is already active'));
        expect(service.currentState.isProUnlocked, isTrue);
        expect(service.currentState.isLifetimeUnlocked, isTrue);
        expect(
          await settings.getBool(SettingKeys.monetizationProUnlocked),
          isTrue,
        );
        expect(
          await settings.getString(SettingKeys.monetizationActiveProductId),
          MonetizationProductIds.iosProLifetimeProd,
        );
        verifyNever(() => inAppPurchase.restorePurchases());
      },
    );

    test(
      'initialization retry retains one purchase listener and disposes it',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        when(() => inAppPurchase.isAvailable()).thenAnswer((_) async => true);
        when(
          () => inAppPurchase.queryProductDetails(any()),
        ).thenThrow(StateError('Catalog unavailable'));
        final service = buildService();

        final purchase = _purchase(
          MonetizationProductIds.androidPro,
          PurchaseStatus.purchased,
        );
        when(
          () => inAppPurchase.completePurchase(purchase),
        ).thenAnswer((_) async {});

        await expectLater(service.initialize(), throwsStateError);
        when(() => inAppPurchase.queryProductDetails(any())).thenAnswer(
          (_) async => ProductDetailsResponse(
            productDetails: const [],
            notFoundIDs: const [],
          ),
        );
        await service.initialize();
        purchaseController.add([purchase]);
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(service.currentState.isProUnlocked, isTrue);
        expect(
          await settings.getBool(SettingKeys.monetizationProUnlocked),
          isTrue,
        );
        expect(
          await settings.getString(SettingKeys.monetizationActiveProductId),
          MonetizationProductIds.androidPro,
        );
        expect(
          service.currentState.activeProductId,
          MonetizationProductIds.androidPro,
        );
        expect(service.currentState.activeOfferId, isNull);
        verify(() => inAppPurchase.completePurchase(purchase)).called(1);
        await service.dispose();
        expect(purchaseController.hasListener, isFalse);
      },
    );

    test(
      'purchaseOffer retries failed launches and persists the plan',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        when(() => inAppPurchase.isAvailable()).thenAnswer((_) async => true);
        when(() => inAppPurchase.queryProductDetails(any())).thenAnswer(
          (_) async => ProductDetailsResponse(
            productDetails: _androidCatalogDetails(),
            notFoundIDs: const [],
          ),
        );
        final purchase = _purchase(
          MonetizationProductIds.androidPro,
          PurchaseStatus.purchased,
        );
        when(
          () => inAppPurchase.completePurchase(purchase),
        ).thenAnswer((_) async {});

        final diagnostics = RecordingDiagnosticsLogger();
        final service = buildService(android: true, diagnostics: diagnostics);

        await service.initialize();
        final annualOfferId = service.currentState.offers
            .firstWhere(
              (offer) =>
                  offer.billingPeriod == MonetizationBillingPeriod.annual,
            )
            .id;
        when(
          () => inAppPurchase.buyNonConsumable(
            purchaseParam: any(named: 'purchaseParam'),
          ),
        ).thenThrow(StateError('Store launch failed'));
        await expectLater(
          service.purchaseOffer(annualOfferId),
          throwsStateError,
        );
        expect(service.currentState.isLoading, isFalse);
        when(
          () => inAppPurchase.buyNonConsumable(
            purchaseParam: any(named: 'purchaseParam'),
          ),
        ).thenAnswer((_) async => false);
        expect(
          (await service.purchaseOffer(annualOfferId)).message,
          'Could not start the purchase flow.',
        );
        expect(service.currentState.isLoading, isFalse);
        when(
          () => inAppPurchase.buyNonConsumable(
            purchaseParam: any(named: 'purchaseParam'),
          ),
        ).thenAnswer(
          (_) async => throw PlatformException(
            code: 'ERROR',
            message: 'Billing activity unavailable',
          ),
        );
        final launchFailure = await service.purchaseOffer(annualOfferId);
        expect(launchFailure.success, isFalse);
        expect(launchFailure.cancelled, isFalse);
        expect(launchFailure.message, 'Could not start the purchase flow.');
        expect(service.currentState.isLoading, isFalse);
        expect(service.currentState.lastError, launchFailure.message);
        expect(service.currentState.isProUnlocked, isFalse);
        final diagnostic = diagnostics.events.singleWhere(
          (entry) => entry.message == 'purchase_launch_failed',
        );
        expect(diagnostic.category, 'billing');
        expect(diagnostic.fields, isEmpty);
        when(
          () => inAppPurchase.buyNonConsumable(
            purchaseParam: any(named: 'purchaseParam'),
          ),
        ).thenAnswer((_) async => true);
        final resultFuture = service.purchaseOffer(annualOfferId);
        await Future<void>.delayed(Duration.zero);
        purchaseController.add([purchase]);

        final result = await resultFuture;

        expect(result.success, isTrue);
        expect(service.currentState.activeOfferId, annualOfferId);
        expect(
          await settings.getString(SettingKeys.monetizationActiveOfferId),
          annualOfferId,
        );
      },
    );

    test(
      'purchaseOffer refuses recurring plans when lifetime is already active',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        await settings.setBool(
          SettingKeys.monetizationProUnlocked,
          value: true,
        );
        await settings.setString(
          SettingKeys.monetizationActiveProductId,
          MonetizationProductIds.androidProLifetime,
        );

        when(() => inAppPurchase.isAvailable()).thenAnswer((_) async => true);
        when(() => inAppPurchase.queryProductDetails(any())).thenAnswer(
          (_) async => ProductDetailsResponse(
            productDetails: _androidCatalogDetails(),
            notFoundIDs: const [],
          ),
        );
        when(androidPlatformAddition.queryPastPurchases).thenAnswer(
          (_) async => QueryPurchaseDetailsResponse(
            pastPurchases: [
              _androidPastLifetimePurchase(purchaseTimeMillis: 1712732400000),
            ],
          ),
        );

        final service = buildService(android: true);

        await service.initialize();
        final offerId = service.currentState.offers.first.id;

        final result = await service.purchaseOffer(offerId);

        expect(result.success, isFalse);
        expect(result.cancelled, isFalse);
        expect(result.message, contains('Lifetime is already active'));
        verifyNever(
          () => inAppPurchase.buyNonConsumable(
            purchaseParam: any(named: 'purchaseParam'),
          ),
        );
      },
    );

    test(
      'Android stale checkout recovery honors lifetime before retrying a subscription',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        when(() => inAppPurchase.isAvailable()).thenAnswer((_) async => true);
        when(() => inAppPurchase.queryProductDetails(any())).thenAnswer(
          (_) async => ProductDetailsResponse(
            productDetails: _androidCatalogDetails(),
            notFoundIDs: const [],
          ),
        );
        var buyCallCount = 0;
        when(
          () => inAppPurchase.buyNonConsumable(
            purchaseParam: any(named: 'purchaseParam'),
          ),
        ).thenAnswer((_) async {
          buyCallCount += 1;
          return true;
        });
        when(androidPlatformAddition.queryPastPurchases).thenAnswer(
          (_) async => QueryPurchaseDetailsResponse(
            pastPurchases: [
              _androidPastLifetimePurchase(purchaseTimeMillis: 1712732400000),
              _androidPastPurchase(purchaseTimeMillis: 1712732401000),
            ],
          ),
        );

        final service = buildService(android: true);

        await service.initialize();
        final monthlyOfferId = service.currentState.offers
            .firstWhere(
              (offer) =>
                  offer.billingPeriod == MonetizationBillingPeriod.monthly,
            )
            .id;
        final annualOfferId = service.currentState.offers
            .firstWhere(
              (offer) =>
                  offer.billingPeriod == MonetizationBillingPeriod.annual,
            )
            .id;

        final firstAttempt = service.purchaseOffer(monthlyOfferId);
        await Future<void>.delayed(Duration.zero);

        final secondResult = await service.purchaseOffer(annualOfferId);
        final firstResult = await firstAttempt;

        expect(firstResult.success, isTrue);
        expect(firstResult.message, contains('Lifetime'));
        expect(secondResult.success, isFalse);
        expect(secondResult.message, contains('Lifetime is already active'));
        expect(service.currentState.isProUnlocked, isTrue);
        expect(service.currentState.isLifetimeUnlocked, isTrue);
        expect(
          service.currentState.activeProductId,
          MonetizationProductIds.androidProLifetime,
        );
        expect(service.currentState.activeOfferId, isNull);
        expect(buyCallCount, 1);
        verify(androidPlatformAddition.queryPastPurchases).called(1);
      },
    );

    test(
      'purchaseOffer lets Android users retry with another plan after dismissing Play checkout',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        when(() => inAppPurchase.isAvailable()).thenAnswer((_) async => true);
        when(() => inAppPurchase.queryProductDetails(any())).thenAnswer(
          (_) async => ProductDetailsResponse(
            productDetails: _androidCatalogDetails(),
            notFoundIDs: const [],
          ),
        );
        var buyCallCount = 0;
        when(
          () => inAppPurchase.buyNonConsumable(
            purchaseParam: any(named: 'purchaseParam'),
          ),
        ).thenAnswer((_) async {
          buyCallCount += 1;
          return true;
        });
        when(androidPlatformAddition.queryPastPurchases).thenAnswer(
          (_) async => QueryPurchaseDetailsResponse(pastPurchases: const []),
        );

        final purchase = _purchase(
          MonetizationProductIds.androidPro,
          PurchaseStatus.purchased,
        );
        when(
          () => inAppPurchase.completePurchase(purchase),
        ).thenAnswer((_) async {});

        final service = buildService(android: true);

        await service.initialize();
        final monthlyOfferId = service.currentState.offers
            .firstWhere(
              (offer) =>
                  offer.billingPeriod == MonetizationBillingPeriod.monthly,
            )
            .id;
        final annualOfferId = service.currentState.offers
            .firstWhere(
              (offer) =>
                  offer.billingPeriod == MonetizationBillingPeriod.annual,
            )
            .id;

        final firstAttempt = service.purchaseOffer(monthlyOfferId);
        await Future<void>.delayed(Duration.zero);

        final secondAttempt = service.purchaseOffer(annualOfferId);
        await Future<void>.delayed(Duration.zero);

        final firstResult = await firstAttempt;
        purchaseController.add([purchase]);
        final secondResult = await secondAttempt;

        expect(firstResult.success, isFalse);
        expect(firstResult.cancelled, isTrue);
        expect(secondResult.success, isTrue);
        expect(service.currentState.activeOfferId, annualOfferId);
        expect(buyCallCount, 2);
        verify(androidPlatformAddition.queryPastPurchases).called(1);
      },
    );

    test(
      'restorePurchases refuses to start while another purchase is in progress',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        when(() => inAppPurchase.isAvailable()).thenAnswer((_) async => true);
        when(() => inAppPurchase.queryProductDetails(any())).thenAnswer(
          (_) async => ProductDetailsResponse(
            productDetails: _androidCatalogDetails(),
            notFoundIDs: const [],
          ),
        );
        final buyStartedCompleter = Completer<bool>();
        when(
          () => inAppPurchase.buyNonConsumable(
            purchaseParam: any(named: 'purchaseParam'),
          ),
        ).thenAnswer((_) => buyStartedCompleter.future);

        final service = buildService(android: true);

        await service.initialize();
        final purchaseFuture = service.purchaseOffer(
          service.currentState.defaultOffer!.id,
        );
        await Future<void>.delayed(Duration.zero);

        final restoreResult = await service.restorePurchases();

        expect(restoreResult.success, isFalse);
        expect(
          restoreResult.message,
          'Another purchase or restore is already in progress.',
        );

        buyStartedCompleter.complete(false);
        await purchaseFuture;
      },
    );

    test(
      'initialization clears cached Android entitlement when Play has no active subscription',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        await settings.setBool(
          SettingKeys.monetizationProUnlocked,
          value: true,
        );
        await settings.setString(
          SettingKeys.monetizationActiveProductId,
          MonetizationProductIds.androidPro,
        );

        when(() => inAppPurchase.isAvailable()).thenAnswer((_) async => true);
        when(() => inAppPurchase.queryProductDetails(any())).thenAnswer(
          (_) async => ProductDetailsResponse(
            productDetails: _androidCatalogDetails(),
            notFoundIDs: const [],
          ),
        );
        when(androidPlatformAddition.queryPastPurchases).thenAnswer(
          (_) async => QueryPurchaseDetailsResponse(pastPurchases: []),
        );

        final service = buildService(android: true);

        await service.initialize();

        expect(service.currentState.isProUnlocked, isFalse);
        expect(
          await settings.getBool(SettingKeys.monetizationProUnlocked),
          isFalse,
        );
      },
    );

    test(
      'restorePurchases uses active Google Play subscriptions on Android',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        when(() => inAppPurchase.isAvailable()).thenAnswer((_) async => true);
        when(() => inAppPurchase.queryProductDetails(any())).thenAnswer(
          (_) async => ProductDetailsResponse(
            productDetails: _androidCatalogDetails(),
            notFoundIDs: const [],
          ),
        );
        when(androidPlatformAddition.queryPastPurchases).thenAnswer(
          (_) async => QueryPurchaseDetailsResponse(
            pastPurchases: [
              _androidPastPurchase(purchaseTimeMillis: 1712732400000),
            ],
          ),
        );

        final service = buildService(android: true);

        final result = await service.restorePurchases();

        expect(result.success, isTrue);
        expect(service.currentState.isProUnlocked, isTrue);
        expect(
          await settings.getBool(SettingKeys.monetizationProUnlocked),
          isTrue,
        );
      },
    );

    test('throwing restore preserves cached Pro and permits retry', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final updatedAt = DateTime.utc(2026, 4, 10);
      await settings.setBool(SettingKeys.monetizationProUnlocked, value: true);
      final cachedStrings = {
        SettingKeys.monetizationActiveProductId:
            MonetizationProductIds.iosMonthlyProd,
        SettingKeys.monetizationActiveOfferId: 'monthly-offer',
        SettingKeys.monetizationEntitlementUpdatedAt: updatedAt
            .toIso8601String(),
      };
      for (final entry in cachedStrings.entries) {
        await settings.setString(entry.key, entry.value);
      }
      when(
        () => inAppPurchase.restorePurchases(),
      ).thenThrow(Exception('offline'));
      final service = buildService(
        restoreEmptyResultGracePeriod: Duration.zero,
      );

      for (var attempt = 0; attempt < 2; attempt++) {
        final result = await service.restorePurchases();
        await Future<void>.delayed(Duration.zero);

        expect(result.success, isFalse);
        expect(result.message, 'Could not restore purchases. Try again.');
        expect(service.currentState.lastError, result.message);
        expect(service.currentState.isLoading, isFalse);
        expect(service.currentState.isProUnlocked, isTrue);
        expect(
          service.currentState.activeProductId,
          MonetizationProductIds.iosMonthlyProd,
        );
        expect(service.currentState.activeOfferId, 'monthly-offer');
        expect(service.currentState.entitlementUpdatedAt, updatedAt.toLocal());
        expect(
          await settings.getBool(SettingKeys.monetizationProUnlocked),
          isTrue,
        );
        for (final entry in cachedStrings.entries) {
          expect(await settings.getString(entry.key), entry.value);
        }
      }
      verify(() => inAppPurchase.restorePurchases()).called(2);
    });

    for (final productId in [
      MonetizationProductIds.iosMonthlyProd,
      MonetizationProductIds.iosProLifetimeProd,
      null,
    ]) {
      test(
        'restore during entitlement clearing: ${productId ?? 'duplicate empty callbacks'}',
        () async {
          debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
          addTearDown(() => debugDefaultTargetPlatformOverride = null);
          final delayedSettings = _DelayedEntitlementSettings(database);
          final purchase = MockPurchaseDetails();
          if (productId != null) {
            await settings.setBool(
              SettingKeys.monetizationProUnlocked,
              value: true,
            );
            await settings.setString(
              SettingKeys.monetizationActiveProductId,
              MonetizationProductIds.iosMonthlyProd,
            );
            when(() => purchase.productID).thenReturn(productId);
            when(() => purchase.status).thenReturn(PurchaseStatus.restored);
            when(() => purchase.pendingCompletePurchase).thenReturn(true);
            when(() => purchase.transactionDate).thenReturn('1712732400000');
            when(
              () => inAppPurchase.completePurchase(purchase),
            ).thenAnswer((_) async {});
          }
          when(() => inAppPurchase.restorePurchases()).thenAnswer((_) async {
            purchaseController.add(const []);
          });
          final service = buildService(store: delayedSettings);

          final restore = service.restorePurchases();
          await delayedSettings.clearStarted.future;
          if (productId == null) {
            purchaseController
              ..add(const [])
              ..add(const []);
          } else {
            purchaseController.add([purchase]);
          }
          await Future<void>.delayed(Duration.zero);
          if (productId == null) {
            expect(delayedSettings.clearCount, 1);
          } else {
            verifyNever(() => inAppPurchase.completePurchase(purchase));
          }
          delayedSettings.allowClear.complete();

          final result = await restore;
          if (productId == null) {
            await Future<void>.delayed(Duration.zero);
            expect(result.success, isFalse);
            expect(result.message, contains('No active'));
            expect(service.currentState.isLoading, isFalse);
            expect(service.currentState.isProUnlocked, isFalse);
            expect(delayedSettings.clearCount, 1);
            return;
          }
          expect(result.success, isTrue);
          expect(service.currentState.isProUnlocked, isTrue);
          expect(service.currentState.isLoading, isFalse);
          expect(service.currentState.activeProductId, productId);
          expect(
            await settings.getBool(SettingKeys.monetizationProUnlocked),
            isTrue,
          );
          expect(
            await settings.getString(SettingKeys.monetizationActiveProductId),
            productId,
          );
          expect(
            await settings.getString(SettingKeys.monetizationActiveOfferId),
            service.currentState.activeOfferId,
          );
          expect(
            await settings.getString(
              SettingKeys.monetizationEntitlementUpdatedAt,
            ),
            DateTime.fromMillisecondsSinceEpoch(
              1712732400000,
              isUtc: true,
            ).toIso8601String(),
          );
          verify(() => inAppPurchase.completePurchase(purchase)).called(1);
        },
      );
    }

    test('restore timeout clears a stale cached store entitlement', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await settings.setBool(SettingKeys.monetizationProUnlocked, value: true);
      await settings.setString(
        SettingKeys.monetizationActiveProductId,
        MonetizationProductIds.androidPro,
      );

      when(() => inAppPurchase.restorePurchases()).thenAnswer((_) async {});

      final service = buildService(restoreTimeout: Duration.zero);

      final result = await service.restorePurchases();

      expect(result.success, isFalse);
      expect(service.currentState.isProUnlocked, isFalse);
      expect(
        await settings.getBool(SettingKeys.monetizationProUnlocked),
        isFalse,
      );
      expect(
        await settings.getString(SettingKeys.monetizationActiveProductId),
        isNull,
      );
    });

    test(
      'restore timeout clears loading when a purchase update was observed',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final purchase = _purchase(
          MonetizationProductIds.androidPro,
          PurchaseStatus.restored,
        );
        when(
          () => inAppPurchase.completePurchase(purchase),
        ).thenAnswer((_) => Completer<void>().future);
        when(() => inAppPurchase.restorePurchases()).thenAnswer((_) async {});

        final service = buildService(
          android: true,
          restoreTimeout: const Duration(milliseconds: 10),
        );

        await service.initialize();
        unawaited(
          Future<void>(() async {
            await Future<void>.delayed(const Duration(milliseconds: 1));
            purchaseController.add([purchase]);
          }),
        );

        final result = await service.restorePurchases();

        expect(result.success, isFalse);
        expect(service.currentState.isLoading, isFalse);
      },
    );

    test('restore without StoreKit purchases finalizes via the grace period '
        'instead of blocking on the restore timeout', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await settings.setBool(SettingKeys.monetizationProUnlocked, value: true);
      await settings.setString(
        SettingKeys.monetizationActiveProductId,
        MonetizationProductIds.iosMonthlyProd,
      );
      // StoreKit2 emits nothing on the purchase stream when there is
      // nothing to restore, so the restore must resolve on its own.
      when(() => inAppPurchase.restorePurchases()).thenAnswer((_) async {});

      final service = buildService(
        restoreTimeout: const Duration(seconds: 30),
        restoreEmptyResultGracePeriod: const Duration(milliseconds: 20),
      );

      // The outer timeout guards the test: without the grace finalization
      // this would block for the full 30s restore timeout.
      final result = await service.restorePurchases().timeout(
        const Duration(seconds: 5),
      );

      expect(result.success, isFalse);
      expect(result.message, contains('No active'));
      expect(service.currentState.isProUnlocked, isFalse);
      expect(service.currentState.isLoading, isFalse);
      expect(
        await settings.getBool(SettingKeys.monetizationProUnlocked),
        isFalse,
      );
      expect(
        await settings.getString(SettingKeys.monetizationActiveProductId),
        isNull,
      );
    });

    test('restore finalizes immediately when StoreKit reports an empty '
        'purchase list', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await settings.setBool(SettingKeys.monetizationProUnlocked, value: true);
      await settings.setString(
        SettingKeys.monetizationActiveProductId,
        MonetizationProductIds.iosMonthlyProd,
      );
      when(() => inAppPurchase.restorePurchases()).thenAnswer((_) async {
        // StoreKit1 emits an empty list when nothing can be restored.
        purchaseController.add(const <PurchaseDetails>[]);
      });

      final service = buildService(
        restoreTimeout: const Duration(seconds: 30),
        // A long grace period proves the empty-list path resolves without
        // waiting for either the grace period or the restore timeout.
        restoreEmptyResultGracePeriod: const Duration(seconds: 30),
      );

      final result = await service.restorePurchases().timeout(
        const Duration(seconds: 5),
      );

      expect(result.success, isFalse);
      expect(result.message, contains('No active'));
      expect(service.currentState.isProUnlocked, isFalse);
      expect(
        await settings.getBool(SettingKeys.monetizationProUnlocked),
        isFalse,
      );
    });

    test('restore applies a restored StoreKit subscription and keeps the '
        'entitlement', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final purchase = _purchase(
        MonetizationProductIds.iosMonthlyProd,
        PurchaseStatus.restored,
      );
      when(
        () => inAppPurchase.completePurchase(purchase),
      ).thenAnswer((_) async {});
      when(() => inAppPurchase.restorePurchases()).thenAnswer((_) async {
        purchaseController.add([purchase]);
      });

      final service = buildService(
        restoreTimeout: const Duration(seconds: 30),
        // Long enough that the observed purchase resolves the restore
        // before the empty-result finalization could ever run.
        restoreEmptyResultGracePeriod: const Duration(seconds: 5),
      );

      final result = await service.restorePurchases().timeout(
        const Duration(seconds: 5),
      );

      expect(result.success, isTrue);
      expect(service.currentState.isProUnlocked, isTrue);
      expect(
        service.currentState.activeProductId,
        MonetizationProductIds.iosMonthlyProd,
      );
      expect(
        await settings.getBool(SettingKeys.monetizationProUnlocked),
        isTrue,
      );
    });

    test(
      'purchase finalization failure resolves the pending purchase',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        when(() => inAppPurchase.isAvailable()).thenAnswer((_) async => true);
        when(() => inAppPurchase.queryProductDetails(any())).thenAnswer(
          (_) async => ProductDetailsResponse(
            productDetails: _androidCatalogDetails(),
            notFoundIDs: const [],
          ),
        );
        when(
          () => inAppPurchase.buyNonConsumable(
            purchaseParam: any(named: 'purchaseParam'),
          ),
        ).thenAnswer((_) async => true);

        final purchase = _purchase(
          MonetizationProductIds.androidPro,
          PurchaseStatus.purchased,
        );
        when(
          () => inAppPurchase.completePurchase(purchase),
        ).thenThrow(Exception('billing finalize failed'));

        final service = buildService(android: true);

        await service.initialize();
        final resultFuture = service.purchaseOffer(
          service.currentState.defaultOffer!.id,
        );
        await Future<void>.delayed(Duration.zero);
        purchaseController.add([purchase]);

        final result = await resultFuture;

        expect(result.success, isFalse);
        expect(result.message, 'Could not finalize purchase. Try again.');
        expect(service.currentState.isLoading, isFalse);
        expect(
          service.currentState.lastError,
          'Could not finalize purchase. Try again.',
        );
      },
    );
  });
}

final _usdPriceLocale = SKPriceLocaleWrapper(
  currencySymbol: r'$',
  currencyCode: 'USD',
  countryCode: 'US',
);

SubscriptionOfferDetailsWrapper _subscriptionOfferDetails({
  required String basePlanId,
  required String offerIdToken,
  required List<PricingPhaseWrapper> pricingPhases,
  String? offerId,
}) => SubscriptionOfferDetailsWrapper(
  basePlanId: basePlanId,
  offerId: offerId,
  offerTags: const [],
  offerIdToken: offerIdToken,
  pricingPhases: pricingPhases,
);

PricingPhaseWrapper _pricingPhase({
  required String formattedPrice,
  required int priceAmountMicros,
  required String billingPeriod,
  required RecurrenceMode recurrenceMode,
}) => PricingPhaseWrapper(
  billingCycleCount: 1,
  billingPeriod: billingPeriod,
  formattedPrice: formattedPrice,
  priceAmountMicros: priceAmountMicros,
  priceCurrencyCode: 'USD',
  recurrenceMode: recurrenceMode,
);

List<ProductDetails> _androidCatalogDetails() => [
  ...GooglePlayProductDetails.fromProductDetails(
    ProductDetailsWrapper(
      description: 'MonkeySSH Pro subscription',
      name: 'MonkeySSH Pro',
      productId: MonetizationProductIds.androidPro,
      productType: ProductType.subs,
      title: 'MonkeySSH Pro',
      subscriptionOfferDetails: [
        _subscriptionOfferDetails(
          basePlanId: 'monthly',
          offerIdToken: 'monthly-base-token',
          pricingPhases: [
            _pricingPhase(
              formattedPrice: r'$5.00',
              priceAmountMicros: 5000000,
              billingPeriod: 'P1M',
              recurrenceMode: RecurrenceMode.infiniteRecurring,
            ),
          ],
        ),
        _subscriptionOfferDetails(
          basePlanId: 'annual',
          offerIdToken: 'annual-base-token',
          pricingPhases: [
            _pricingPhase(
              formattedPrice: r'$50.00',
              priceAmountMicros: 50000000,
              billingPeriod: 'P1Y',
              recurrenceMode: RecurrenceMode.infiniteRecurring,
            ),
          ],
        ),
      ],
    ),
  ),
];

GooglePlayPurchaseDetails _androidPastPurchase({
  required int purchaseTimeMillis,
}) => GooglePlayPurchaseDetails(
  purchaseID: 'order-$purchaseTimeMillis',
  productID: MonetizationProductIds.androidPro,
  verificationData: PurchaseVerificationData(
    localVerificationData: 'local-verification-data',
    serverVerificationData: 'server-verification-data',
    source: 'google_play',
  ),
  transactionDate: purchaseTimeMillis.toString(),
  billingClientPurchase: PurchaseWrapper(
    orderId: 'order-$purchaseTimeMillis',
    packageName: 'xyz.depollsoft.monkeyssh',
    purchaseTime: purchaseTimeMillis,
    purchaseToken: 'token-$purchaseTimeMillis',
    signature: 'signature',
    products: const [MonetizationProductIds.androidPro],
    isAutoRenewing: true,
    originalJson: '{}',
    isAcknowledged: true,
    purchaseState: PurchaseStateWrapper.purchased,
  ),
  status: PurchaseStatus.restored,
);

GooglePlayPurchaseDetails _androidPastLifetimePurchase({
  required int purchaseTimeMillis,
}) => GooglePlayPurchaseDetails(
  purchaseID: 'lifetime-$purchaseTimeMillis',
  productID: MonetizationProductIds.androidProLifetime,
  verificationData: PurchaseVerificationData(
    localVerificationData: 'local-verification-data',
    serverVerificationData: 'server-verification-data',
    source: 'google_play',
  ),
  transactionDate: purchaseTimeMillis.toString(),
  billingClientPurchase: PurchaseWrapper(
    orderId: 'lifetime-$purchaseTimeMillis',
    packageName: 'xyz.depollsoft.monkeyssh',
    purchaseTime: purchaseTimeMillis,
    purchaseToken: 'token-$purchaseTimeMillis',
    signature: 'signature',
    products: const [MonetizationProductIds.androidProLifetime],
    isAutoRenewing: false,
    originalJson: '{}',
    isAcknowledged: true,
    purchaseState: PurchaseStateWrapper.purchased,
  ),
  status: PurchaseStatus.restored,
);

MockPurchaseDetails _purchase(String productId, PurchaseStatus status) {
  final purchase = MockPurchaseDetails();
  when(() => purchase.productID).thenReturn(productId);
  when(() => purchase.status).thenReturn(status);
  when(() => purchase.pendingCompletePurchase).thenReturn(true);
  when(() => purchase.transactionDate).thenReturn('1712732400000');
  return purchase;
}

// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/presentation/screens/upgrade_screen.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/link.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class _MockMonetizationService extends Mock implements MonetizationService {}

class _FakeUrlLauncher extends UrlLauncherPlatform {
  Future<bool> Function() launchResult = () async => true;
  final launchedUrls = <String>[];
  int canLaunchCalls = 0;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async {
    canLaunchCalls++;
    return false;
  }

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) {
    expect(options.mode, PreferredLaunchMode.externalApplication);
    launchedUrls.add(url);
    return launchResult();
  }
}

Future<MonetizationActionResult> _cancelledPurchaseResult(Invocation _) =>
    Future.value(
      const MonetizationActionResult.cancelled('Purchase cancelled.'),
    );

Future<MonetizationActionResult> _restoredPurchaseResult(Invocation _) =>
    Future.value(const MonetizationActionResult.success('Restored purchases.'));

void _stubRestorePurchases(_MockMonetizationService service) {
  // ignore: unnecessary_lambdas
  when(() => service.restorePurchases()).thenAnswer(_restoredPurchaseResult);
}

void main() {
  group('external links', () {
    late _FakeUrlLauncher launcher;

    setUp(() {
      final previousLauncher = UrlLauncherPlatform.instance;
      launcher = _FakeUrlLauncher();
      UrlLauncherPlatform.instance = launcher;
      addTearDown(() {
        UrlLauncherPlatform.instance = previousLauncher;
      });
    });

    Future<void> showUpgrade(WidgetTester tester) async {
      final service = _MockMonetizationService();
      const state = MonetizationState(
        billingAvailability: MonetizationBillingAvailability.available,
        entitlements: MonetizationEntitlements.free(),
        offers: [],
        debugUnlockAvailable: false,
        debugUnlocked: false,
      );
      when(() => service.currentState).thenReturn(state);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            monetizationServiceProvider.overrideWithValue(service),
            monetizationStateProvider.overrideWith(
              (ref) => Stream.value(state),
            ),
          ],
          child: const MaterialApp(home: UpgradeScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }

    for (final link in [
      (button: 'Privacy Policy', label: 'the privacy policy'),
      (button: 'Terms of Use (EULA)', label: 'the Terms of Use'),
      (
        button: 'Manage subscription',
        label: 'the subscription management page',
      ),
    ]) {
      for (final throwsException in [false, true]) {
        testWidgets(
          '${link.button} reports ${throwsException ? 'an exception' : 'a refused launch'}',
          (tester) async {
            launcher.launchResult = () async {
              if (throwsException) {
                throw PlatformException(code: 'ACTIVITY_NOT_FOUND');
              }
              return false;
            };
            await showUpgrade(tester);
            await tester.scrollUntilVisible(find.text(link.button), 300);
            await tester.tap(find.text(link.button));
            await tester.pumpAndSettle();

            expect(launcher.launchedUrls, hasLength(1));
            expect(launcher.canLaunchCalls, 0);
            expect(find.text('Could not open ${link.label}.'), findsOneWidget);
            expect(tester.takeException(), isNull);
          },
          variant: TargetPlatformVariant.only(TargetPlatform.android),
        );
      }

      testWidgets(
        '${link.button} handles a launch failure after disposal',
        (tester) async {
          final launch = Completer<bool>();
          launcher.launchResult = () => launch.future;
          await showUpgrade(tester);
          await tester.scrollUntilVisible(find.text(link.button), 300);
          await tester.tap(find.text(link.button));
          await tester.pumpWidget(const SizedBox.shrink());
          launch.completeError(PlatformException(code: 'ACTIVITY_NOT_FOUND'));
          await tester.pump();

          expect(launcher.launchedUrls, hasLength(1));
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.android),
      );
    }

    testWidgets(
      'management launches when the visibility query would return false',
      (tester) async {
        await showUpgrade(tester);
        await tester.scrollUntilVisible(find.text('Manage subscription'), 300);
        await tester.tap(find.text('Manage subscription'));
        await tester.pumpAndSettle();

        expect(launcher.launchedUrls, [
          'https://play.google.com/store/account/subscriptions',
        ]);
        expect(launcher.canLaunchCalls, 0);
        expect(find.byType(SnackBar), findsNothing);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  });

  testWidgets('feature-triggered paywall leads with the blocked action', (
    tester,
  ) async {
    final service = _MockMonetizationService();
    const state = MonetizationState(
      billingAvailability: MonetizationBillingAvailability.available,
      entitlements: MonetizationEntitlements.free(),
      offers: [],
      debugUnlockAvailable: false,
      debugUnlocked: false,
    );

    when(() => service.currentState).thenReturn(state);
    _stubRestorePurchases(service);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          monetizationServiceProvider.overrideWithValue(service),
          monetizationStateProvider.overrideWith((ref) => Stream.value(state)),
        ],
        child: const MaterialApp(
          home: UpgradeScreen(
            feature: MonetizationFeature.autoConnectAutomation,
            blockedAction: 'Run this auto-connect workflow',
            blockedOutcome:
                'Unlock Pro to run saved commands or snippets automatically.',
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Run this auto-connect workflow'), findsOneWidget);
    expect(
      find.text('Unlock Pro to run saved commands or snippets automatically.'),
      findsOneWidget,
    );
    expect(
      find.text('Auto-connect automation is part of MonkeySSH Pro'),
      findsNothing,
    );
  });

  testWidgets('shows subscription legal details and policy links', (
    tester,
  ) async {
    final service = _MockMonetizationService();
    const state = MonetizationState(
      billingAvailability: MonetizationBillingAvailability.available,
      entitlements: MonetizationEntitlements.free(),
      offers: [
        MonetizationOffer(
          id: 'monthly',
          productId: 'monkeyssh_pro_monthly',
          billingPeriod: MonetizationBillingPeriod.monthly,
          planLabel: 'Monthly',
          priceLabel: r'$5.00',
          displayPriceLabel: r'$5.00 / month',
          rawPrice: 5,
          currencyCode: 'USD',
          currencySymbol: r'$',
        ),
      ],
      debugUnlockAvailable: false,
      debugUnlocked: false,
    );

    when(() => service.currentState).thenReturn(state);
    when(
      () => service.purchaseOffer(any()),
    ).thenAnswer(_cancelledPurchaseResult);
    _stubRestorePurchases(service);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          monetizationServiceProvider.overrideWithValue(service),
          monetizationStateProvider.overrideWith((ref) => Stream.value(state)),
        ],
        child: const MaterialApp(home: UpgradeScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('subscription details'), findsOneWidget);
    expect(find.textContaining('auto-renewable'), findsOneWidget);
    expect(find.textContaining('renew every month'), findsOneWidget);
    expect(find.text('Privacy Policy'), findsOneWidget);
    expect(find.text('Terms of Use (EULA)'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('Parallel native chats'), 300);
    await tester.pumpAndSettle();
    expect(find.text('Parallel native chats'), findsOneWidget);
    expect(find.text('Recent terminal sessions'), findsOneWidget);
    expect(find.textContaining('fork active sessions'), findsOneWidget);
  });

  testWidgets('plan cards stay legible in dark mode', (tester) async {
    final service = _MockMonetizationService();
    const state = MonetizationState(
      billingAvailability: MonetizationBillingAvailability.available,
      entitlements: MonetizationEntitlements.pro(),
      offers: [
        MonetizationOffer(
          id: 'monthly',
          productId: 'monkeyssh_pro_monthly',
          billingPeriod: MonetizationBillingPeriod.monthly,
          planLabel: 'Monthly',
          priceLabel: r'$5.00',
          displayPriceLabel: r'$5.00 / month',
          rawPrice: 5,
          currencyCode: 'USD',
          currencySymbol: r'$',
        ),
        MonetizationOffer(
          id: 'annual',
          productId: 'monkeyssh_pro_annual',
          billingPeriod: MonetizationBillingPeriod.annual,
          planLabel: 'Annual',
          priceLabel: r'$50.00',
          displayPriceLabel: r'$50.00 / year',
          rawPrice: 50,
          currencyCode: 'USD',
          currencySymbol: r'$',
        ),
      ],
      debugUnlockAvailable: false,
      debugUnlocked: false,
      activeProductId: 'monkeyssh_pro_monthly',
      activeOfferId: 'monthly',
    );

    when(() => service.currentState).thenReturn(state);
    when(
      () => service.purchaseOffer(any()),
    ).thenAnswer(_cancelledPurchaseResult);
    _stubRestorePurchases(service);

    final darkTheme = ThemeData.dark(useMaterial3: true);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          monetizationServiceProvider.overrideWithValue(service),
          monetizationStateProvider.overrideWith((ref) => Stream.value(state)),
        ],
        child: MaterialApp(
          theme: ThemeData.light(useMaterial3: true),
          darkTheme: darkTheme,
          themeMode: ThemeMode.dark,
          home: const UpgradeScreen(),
        ),
      ),
    );
    await tester.pump();
    final annualSavingsFinder = find.text(
      'Annual is the best value - save about 17% compared with paying monthly.',
    );
    await tester.scrollUntilVisible(annualSavingsFinder, 300);
    await tester.pumpAndSettle();
    final annualSavingsBanner = tester.widget<Text>(annualSavingsFinder);
    await tester.scrollUntilVisible(find.text('Monthly'), 300);
    await tester.pumpAndSettle();

    final monthlyCardFinder = find.ancestor(
      of: find.text('Monthly'),
      matching: find.byType(Card),
    );
    final monthlyCard = tester.widget<Card>(monthlyCardFinder);
    final monthlyTitle = tester.widget<Text>(find.text('Monthly').first);
    final monthlyShape = monthlyCard.shape! as RoundedRectangleBorder;
    final annualCard = tester.widget<Card>(
      find.ancestor(of: find.text('Annual'), matching: find.byType(Card)),
    );
    final annualShape = annualCard.shape! as RoundedRectangleBorder;
    final currentPill = tester.widget<Text>(find.text('Current'));
    final currentAction = tester.widget<Text>(find.text('Manage current plan'));
    final bestValuePill = tester.widget<Text>(
      find.text('Best value - Save 17%'),
    );
    final annualAction = tester.widget<Text>(find.text('Switch to Annual'));

    expect(find.byType(RadioListTile<String>), findsNothing);
    expect(
      find.descendant(
        of: monthlyCardFinder,
        matching: find.byType(FilledButton),
      ),
      findsNothing,
    );
    expect(monthlyTitle.style?.color, equals(darkTheme.colorScheme.onSurface));
    expect(monthlyShape.side.color, equals(darkTheme.colorScheme.primary));
    expect(monthlyShape.side.width, 3);
    expect(annualShape.side.color, equals(darkTheme.colorScheme.outline));
    expect(annualShape.side.width, 1);
    expect(find.text('Current'), findsOneWidget);
    expect(
      currentPill.style?.color,
      equals(darkTheme.colorScheme.onPrimaryContainer),
    );
    expect(
      currentAction.style?.color,
      equals(darkTheme.colorScheme.onPrimaryContainer),
    );
    expect(
      annualSavingsBanner.style?.color,
      equals(darkTheme.colorScheme.onSecondaryContainer),
    );
    expect(
      bestValuePill.style?.color,
      equals(darkTheme.colorScheme.onSecondaryContainer),
    );
    expect(annualAction.style?.color, equals(darkTheme.colorScheme.onSurface));
  });

  testWidgets('shows switch action for a different plan when subscribed', (
    tester,
  ) async {
    final service = _MockMonetizationService();
    const state = MonetizationState(
      billingAvailability: MonetizationBillingAvailability.available,
      entitlements: MonetizationEntitlements.pro(),
      offers: [
        MonetizationOffer(
          id: 'monthly',
          productId: 'monkeyssh_pro',
          billingPeriod: MonetizationBillingPeriod.monthly,
          planLabel: 'Monthly',
          priceLabel: r'$4.99',
          displayPriceLabel: r'$4.99 / month',
          rawPrice: 4.99,
          currencyCode: 'USD',
          currencySymbol: r'$',
        ),
        MonetizationOffer(
          id: 'annual',
          productId: 'monkeyssh_pro',
          billingPeriod: MonetizationBillingPeriod.annual,
          planLabel: 'Annual',
          priceLabel: r'$49.99',
          displayPriceLabel: r'$49.99 / year',
          rawPrice: 49.99,
          currencyCode: 'USD',
          currencySymbol: r'$',
        ),
      ],
      debugUnlockAvailable: false,
      debugUnlocked: false,
      activeProductId: 'monkeyssh_pro',
      activeOfferId: 'monthly',
    );

    when(() => service.currentState).thenReturn(state);
    when(
      () => service.purchaseOffer(any()),
    ).thenAnswer(_cancelledPurchaseResult);
    _stubRestorePurchases(service);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          monetizationServiceProvider.overrideWithValue(service),
          monetizationStateProvider.overrideWith((ref) => Stream.value(state)),
        ],
        child: const MaterialApp(home: UpgradeScreen()),
      ),
    );
    await tester.pump();
    await tester.scrollUntilVisible(find.text('Manage current plan'), 300);
    await tester.pumpAndSettle();

    expect(find.text('Manage current plan'), findsOneWidget);
    expect(find.text('Switch to Annual'), findsOneWidget);
  });

  testWidgets('highlights annual savings and best value copy', (tester) async {
    final service = _MockMonetizationService();
    const state = MonetizationState(
      billingAvailability: MonetizationBillingAvailability.available,
      entitlements: MonetizationEntitlements.free(),
      offers: [
        MonetizationOffer(
          id: 'monthly',
          productId: 'monkeyssh_pro',
          billingPeriod: MonetizationBillingPeriod.monthly,
          planLabel: 'Monthly',
          priceLabel: r'$4.99',
          displayPriceLabel: r'$4.99 / month',
          rawPrice: 4.99,
          currencyCode: 'USD',
          currencySymbol: r'$',
        ),
        MonetizationOffer(
          id: 'annual',
          productId: 'monkeyssh_pro',
          billingPeriod: MonetizationBillingPeriod.annual,
          planLabel: 'Annual',
          priceLabel: r'$49.99',
          displayPriceLabel: r'$49.99 / year',
          rawPrice: 49.99,
          currencyCode: 'USD',
          currencySymbol: r'$',
        ),
      ],
      debugUnlockAvailable: false,
      debugUnlocked: false,
    );

    when(() => service.currentState).thenReturn(state);
    when(
      () => service.purchaseOffer(any()),
    ).thenAnswer(_cancelledPurchaseResult);
    _stubRestorePurchases(service);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          monetizationServiceProvider.overrideWithValue(service),
          monetizationStateProvider.overrideWith((ref) => Stream.value(state)),
        ],
        child: const MaterialApp(home: UpgradeScreen()),
      ),
    );
    await tester.pump();
    final annualSavingsFinder = find.text(
      'Annual is the best value - save about 17% compared with paying monthly.',
    );
    await tester.scrollUntilVisible(annualSavingsFinder, 300);
    await tester.pumpAndSettle();
    final annualSavingsBanner = tester.widget<Text>(annualSavingsFinder);
    await tester.scrollUntilVisible(find.text('Best value - Save 17%'), 300);
    await tester.pumpAndSettle();

    expect(find.text('Best value - Save 17%'), findsOneWidget);
    final bestValuePill = tester.widget<Text>(
      find.text('Best value - Save 17%'),
    );
    final theme = ThemeData.light(useMaterial3: true);
    expect(
      annualSavingsBanner.style?.color,
      equals(theme.colorScheme.onSecondaryContainer),
    );
    expect(
      bestValuePill.style?.color,
      equals(theme.colorScheme.onSecondaryContainer),
    );
  });

  testWidgets('shared trial copy mentions monthly and annual plans', (
    tester,
  ) async {
    final service = _MockMonetizationService();
    const trialLabel = '2 weeks free trial for eligible new customers';
    const state = MonetizationState(
      billingAvailability: MonetizationBillingAvailability.available,
      entitlements: MonetizationEntitlements.free(),
      offers: [
        MonetizationOffer(
          id: 'monthly',
          productId: 'monkeyssh_pro',
          billingPeriod: MonetizationBillingPeriod.monthly,
          planLabel: 'Monthly',
          priceLabel: r'$4.99',
          displayPriceLabel: r'$4.99 / month',
          rawPrice: 4.99,
          currencyCode: 'USD',
          currencySymbol: r'$',
          introductoryOfferLabel: trialLabel,
        ),
        MonetizationOffer(
          id: 'annual',
          productId: 'monkeyssh_pro',
          billingPeriod: MonetizationBillingPeriod.annual,
          planLabel: 'Annual',
          priceLabel: r'$49.99',
          displayPriceLabel: r'$49.99 / year',
          rawPrice: 49.99,
          currencyCode: 'USD',
          currencySymbol: r'$',
          introductoryOfferLabel: trialLabel,
        ),
      ],
      debugUnlockAvailable: false,
      debugUnlocked: false,
    );

    when(() => service.currentState).thenReturn(state);
    when(
      () => service.purchaseOffer(any()),
    ).thenAnswer(_cancelledPurchaseResult);
    _stubRestorePurchases(service);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          monetizationServiceProvider.overrideWithValue(service),
          monetizationStateProvider.overrideWith((ref) => Stream.value(state)),
        ],
        child: const MaterialApp(home: UpgradeScreen()),
      ),
    );
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('shared-intro-offer-label')),
      300,
    );
    await tester.pumpAndSettle();

    expect(find.textContaining(trialLabel), findsWidgets);
    final sharedIntroText = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('shared-intro-offer-label')),
        matching: find.textContaining(trialLabel),
      ),
    );
    expect(sharedIntroText.data, contains('monthly and annual'));
  });

  testWidgets('shows inline store progress while processing loaded plans', (
    tester,
  ) async {
    final service = _MockMonetizationService();
    const state = MonetizationState(
      billingAvailability: MonetizationBillingAvailability.available,
      entitlements: MonetizationEntitlements.free(),
      offers: [
        MonetizationOffer(
          id: 'monthly',
          productId: 'monkeyssh_pro',
          billingPeriod: MonetizationBillingPeriod.monthly,
          planLabel: 'Monthly',
          priceLabel: r'$4.99',
          displayPriceLabel: r'$4.99 / month',
          rawPrice: 4.99,
          currencyCode: 'USD',
          currencySymbol: r'$',
        ),
      ],
      debugUnlockAvailable: false,
      debugUnlocked: false,
      isLoading: true,
    );

    when(() => service.currentState).thenReturn(state);
    when(
      () => service.purchaseOffer(any()),
    ).thenAnswer(_cancelledPurchaseResult);
    _stubRestorePurchases(service);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          monetizationServiceProvider.overrideWithValue(service),
          monetizationStateProvider.overrideWith((ref) => Stream.value(state)),
        ],
        child: const MaterialApp(home: UpgradeScreen()),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('store-progress-banner')), findsOneWidget);
    expect(find.textContaining('Processing your request with'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  for (final result in [
    const MonetizationActionResult.cancelled('Purchase cancelled.'),
    const MonetizationActionResult.failure(
      'Could not start the purchase flow.',
    ),
    const MonetizationActionResult.success('Purchased Pro.'),
  ]) {
    for (final disposeBeforeCompletion in [false, true]) {
      testWidgets(
        'purchase result with disposed=$disposeBeforeCompletion: ${result.message}',
        (tester) async {
          final service = _MockMonetizationService();
          final purchase = Completer<MonetizationActionResult>();
          const state = MonetizationState(
            billingAvailability: MonetizationBillingAvailability.available,
            entitlements: MonetizationEntitlements.free(),
            offers: [
              MonetizationOffer(
                id: 'monthly',
                productId: 'monkeyssh_pro_monthly',
                billingPeriod: MonetizationBillingPeriod.monthly,
                planLabel: 'Monthly',
                priceLabel: r'$5.00',
                displayPriceLabel: r'$5.00 / month',
                rawPrice: 5,
                currencyCode: 'USD',
                currencySymbol: r'$',
              ),
            ],
            debugUnlockAvailable: false,
            debugUnlocked: false,
          );
          when(() => service.currentState).thenReturn(state);
          when(
            () => service.purchaseOffer('monthly'),
          ).thenAnswer((_) => purchase.future);
          _stubRestorePurchases(service);

          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                monetizationServiceProvider.overrideWithValue(service),
                monetizationStateProvider.overrideWith(
                  (ref) => Stream.value(state),
                ),
              ],
              child: const MaterialApp(home: UpgradeScreen()),
            ),
          );
          await tester.pump();
          await tester.scrollUntilVisible(find.text('Subscribe monthly'), 300);
          await tester.tap(find.text('Subscribe monthly'));
          await tester.pump();

          if (disposeBeforeCompletion) {
            await tester.pumpWidget(const SizedBox.shrink());
          }
          purchase.complete(result);
          await tester.pump();

          if (!disposeBeforeCompletion) {
            expect(find.text(result.message), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'shows lifetime ownership info and hides recurring plan actions',
    (tester) async {
      final service = _MockMonetizationService();
      final state = MonetizationState(
        billingAvailability: MonetizationBillingAvailability.available,
        entitlements: const MonetizationEntitlements.pro(),
        offers: const [
          MonetizationOffer(
            id: 'monthly',
            productId: 'monkeyssh_pro_monthly',
            billingPeriod: MonetizationBillingPeriod.monthly,
            planLabel: 'Monthly',
            priceLabel: r'$5.00',
            displayPriceLabel: r'$5.00 / month',
            rawPrice: 5,
            currencyCode: 'USD',
            currencySymbol: r'$',
          ),
        ],
        debugUnlockAvailable: false,
        debugUnlocked: false,
        activeProductId: MonetizationProductIds.iosProLifetimeProd,
        entitlementUpdatedAt: DateTime(2026, 4, 10),
      );

      when(() => service.currentState).thenReturn(state);
      when(
        () => service.purchaseOffer(any()),
      ).thenAnswer(_cancelledPurchaseResult);
      _stubRestorePurchases(service);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            monetizationServiceProvider.overrideWithValue(service),
            monetizationStateProvider.overrideWith(
              (ref) => Stream.value(state),
            ),
          ],
          child: const MaterialApp(home: UpgradeScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('lifetime-status-banner')),
        find.byType(ListView),
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('lifetime-status-banner')),
        findsOneWidget,
      );
      await tester.fling(find.byType(ListView), const Offset(0, -1200), 1000);
      await tester.pumpAndSettle();
      expect(find.text('MonkeySSH Pro Lifetime'), findsOneWidget);
      expect(
        find.textContaining('Unlocked with a one-time purchase on'),
        findsOneWidget,
      );
      expect(find.text('choose a plan'), findsNothing);
      expect(find.text('Monthly'), findsNothing);
      expect(find.textContaining('cancel future renewals'), findsWidgets);
      expect(find.text('Subscribe monthly'), findsNothing);
      expect(find.text('Switch to Monthly'), findsNothing);
      expect(find.text('Subscribe lifetime'), findsNothing);
      expect(find.text('Switch to Lifetime'), findsNothing);
    },
  );
}

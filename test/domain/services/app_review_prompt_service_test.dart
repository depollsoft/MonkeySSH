// ignore_for_file: public_member_api_docs

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/services/app_review_prompt_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/telemetry_service.dart';

import '../../helpers/recording_diagnostics_logger.dart';

void main() {
  late AppDatabase db;
  late SettingsService settings;
  late RecordingDiagnosticsLogger logger;
  late _FakeAnalyticsClient analytics;
  late _FakeReviewClient client;
  late DateTime now;
  late bool appActive;

  AppReviewPromptService createService({bool isSupportedPlatform = true}) =>
      AppReviewPromptService(
        settingsService: settings,
        diagnosticsLogger: logger,
        telemetryService: TelemetryService(
          status: TelemetryServiceStatus.ready,
          collectionEnabled: true,
          diagnosticsLogger: logger,
          analyticsClient: analytics,
        ),
        client: client,
        now: () => now,
        isAppActive: () => appActive,
        isSupportedPlatform: isSupportedPlatform,
      );

  Future<void> connectOnDays(AppReviewPromptService service, int days) async {
    for (var i = 0; i < days; i++) {
      await service.recordSuccessfulConnection();
      now = now.add(const Duration(days: 1));
    }
  }

  Future<void> becomeEligible(AppReviewPromptService service) async {
    final firstConnection = now;
    await connectOnDays(service, AppReviewPromptService.requiredConnectionDays);
    final eligibleAt = firstConnection.add(
      AppReviewPromptService.minimumTimeSinceFirstConnection,
    );
    if (now.isBefore(eligibleAt)) {
      now = eligibleAt;
    }
  }

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    settings = SettingsService(db);
    logger = RecordingDiagnosticsLogger();
    analytics = _FakeAnalyticsClient();
    client = _FakeReviewClient();
    now = DateTime(2026, 10, 1, 9);
    appActive = true;
  });

  tearDown(() async {
    await db.close();
  });

  test('counts each connection day once', () async {
    final service = createService();
    final start = now;

    await service.recordSuccessfulConnection();
    now = now.add(const Duration(hours: 10));
    await service.recordSuccessfulConnection();
    for (
      var day = 1;
      day < AppReviewPromptService.requiredConnectionDays - 1;
      day++
    ) {
      now = start.add(Duration(days: day));
      await service.recordSuccessfulConnection();
      await service.recordSuccessfulConnection();
    }

    now = start.add(const Duration(days: 30));
    expect(await service.maybeRequestReview(), isFalse);
    expect(client.requestCount, 0);

    await service.recordSuccessfulConnection();

    expect(await service.maybeRequestReview(), isTrue);
    expect(client.requestCount, 1);
  });

  test('waits a week after the first connection', () async {
    final service = createService();
    final start = now;
    await connectOnDays(service, AppReviewPromptService.requiredConnectionDays);

    now = start
        .add(AppReviewPromptService.minimumTimeSinceFirstConnection)
        .subtract(const Duration(minutes: 1));
    expect(await service.maybeRequestReview(), isFalse);

    now = now.add(const Duration(minutes: 1));
    expect(await service.maybeRequestReview(), isTrue);
  });

  test('asks again only after the minimum interval', () async {
    final service = createService();
    await becomeEligible(service);

    expect(await service.maybeRequestReview(), isTrue);
    now = now.add(
      AppReviewPromptService.minimumRequestInterval - const Duration(hours: 1),
    );
    expect(await service.maybeRequestReview(), isFalse);
    expect(client.requestCount, 1);

    now = now.add(const Duration(hours: 1));
    expect(await service.maybeRequestReview(), isTrue);
    expect(client.requestCount, 2);
  });

  test('asks at most twice in any 365 days', () async {
    final service = createService();
    await becomeEligible(service);
    final firstRequest = now;

    expect(await service.maybeRequestReview(), isTrue);
    now = firstRequest.add(AppReviewPromptService.minimumRequestInterval);
    expect(await service.maybeRequestReview(), isTrue);
    now = firstRequest.add(const Duration(days: 365));
    expect(await service.maybeRequestReview(), isFalse);
    now = firstRequest.add(const Duration(days: 366));
    expect(await service.maybeRequestReview(), isTrue);
    expect(client.requestCount, 3);
  });

  test(
    'does not spend the window while the app is in the background',
    () async {
      final service = createService();
      await becomeEligible(service);
      appActive = false;

      expect(await service.maybeRequestReview(), isFalse);
      expect(client.requestCount, 0);

      appActive = true;
      expect(await service.maybeRequestReview(), isTrue);
      expect(client.requestCount, 1);
    },
  );

  test('releases only its own claim when backgrounded mid-request', () async {
    final service = createService();
    await becomeEligible(service);
    final firstRequest = now;
    expect(await service.maybeRequestReview(), isTrue);

    now = firstRequest.add(AppReviewPromptService.minimumRequestInterval);
    appActive = false;
    expect(await service.maybeRequestReview(), isFalse);
    expect(
      (await settings.getJson(
        SettingKeys.appReviewPrompt,
      ))?['lastRequestedAtMs'],
      firstRequest.millisecondsSinceEpoch,
    );

    appActive = true;
    expect(await service.maybeRequestReview(), isTrue);
    expect(client.requestCount, 2);
  });

  test('keeps the request window across service instances', () async {
    await becomeEligible(createService());
    expect(await createService().maybeRequestReview(), isTrue);

    expect(await createService().maybeRequestReview(), isFalse);
    expect(client.requestCount, 1);
  });

  test('requests once when two disconnects race', () async {
    final service = createService();
    await becomeEligible(service);

    final results = await Future.wait([
      service.maybeRequestReview(),
      service.maybeRequestReview(),
    ]);

    expect(results.where((requested) => requested), hasLength(1));
    expect(client.requestCount, 1);
  });

  test('does not spend the window when the store is unavailable', () async {
    final service = createService();
    await becomeEligible(service);
    client.available = false;

    expect(await service.maybeRequestReview(), isFalse);
    expect(client.requestCount, 0);

    client.available = true;
    expect(await service.maybeRequestReview(), isTrue);
    expect(client.requestCount, 1);
  });

  test('absorbs a failed request without asking again', () async {
    final service = createService();
    await becomeEligible(service);
    client.requestError = Exception('review flow failed');

    expect(await service.maybeRequestReview(), isFalse);
    expect(
      logger.events.map((event) => event.message),
      contains('review_request_failed'),
    );

    client.requestError = null;
    expect(await service.maybeRequestReview(), isFalse);
    expect(client.requestCount, 1);
  });

  test('does nothing on unsupported platforms', () async {
    final service = createService(isSupportedPlatform: false);
    await becomeEligible(service);

    expect(await service.maybeRequestReview(), isFalse);
    expect(client.requestCount, 0);
    expect(await settings.getJson(SettingKeys.appReviewPrompt), isNull);
  });

  test('records a bucketed telemetry event when requesting', () async {
    final service = createService();
    await becomeEligible(service);

    expect(await service.maybeRequestReview(), isTrue);

    final event = analytics.events.single;
    expect(event.name, 'review_prompt_requested');
    expect(event.parameters, {'connection_days_bucket': '2_5'});
    final requested = logger.events.singleWhere(
      (event) => event.message == 'review_requested',
    );
    expect(requested.category, 'app_review');
    expect(requested.fields, {'connectionDays': 5});
  });

  test('needs a few minutes on a live connection before asking', () {
    expect(
      createService().isQualifyingConnectedTime(
        AppReviewPromptService.minimumConnectedTime -
            const Duration(seconds: 1),
      ),
      isFalse,
    );
    expect(
      createService().isQualifyingConnectedTime(
        AppReviewPromptService.minimumConnectedTime,
      ),
      isTrue,
    );
    expect(
      createService(isSupportedPlatform: false)
          .isQualifyingConnectedTime(const Duration(hours: 1)),
      isFalse,
    );
  });

  test('ignores malformed stored state', () async {
    await settings.setJson(SettingKeys.appReviewPrompt, {
      'connectionDays': 'many',
      'lastRequestedAtMs': 'yesterday',
    });
    final service = createService();

    expect(await service.maybeRequestReview(), isFalse);
    await becomeEligible(service);
    expect(await service.maybeRequestReview(), isTrue);
  });
}

class _FakeReviewClient implements AppReviewClient {
  bool available = true;
  Exception? requestError;
  int requestCount = 0;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<void> requestReview() async {
    requestCount += 1;
    // Yield so concurrent callers can interleave with the request.
    await Future<void>.delayed(Duration.zero);
    if (requestError case final error?) {
      throw error;
    }
  }
}

class _FakeAnalyticsClient implements TelemetryAnalyticsClient {
  final events = <({String name, Map<String, Object> parameters})>[];

  @override
  Future<void> logEvent({
    required String name,
    required Map<String, Object> parameters,
  }) async {
    events.add((name: name, parameters: parameters));
  }

  @override
  Future<void> resetAnalyticsData() async {}

  @override
  Future<void> setCollectionEnabled({required bool enabled}) async {}
}

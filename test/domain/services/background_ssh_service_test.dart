// ignore_for_file: public_member_api_docs

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/background_ssh_service.dart';

const _backgroundSshChannel = MethodChannel(
  'xyz.depollsoft.monkeyssh/ssh_service',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BackgroundSshService', () {
    late List<MethodCall> methodCalls;
    var batteryOptimizationIgnored = false;
    var openedBatterySettings = false;
    Exception? failure;

    setUp(() {
      methodCalls = <MethodCall>[];
      batteryOptimizationIgnored = false;
      openedBatterySettings = false;
      failure = null;
      BackgroundSshService.debugIsAndroidPlatformOverride = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_backgroundSshChannel, (call) async {
            methodCalls.add(call);
            if (failure case final error?) throw error;
            return switch (call.method) {
              'isBatteryOptimizationIgnored' => batteryOptimizationIgnored,
              'requestDisableBatteryOptimization' => openedBatterySettings,
              _ => null,
            };
          });
    });

    tearDown(() {
      BackgroundSshService.debugIsAndroidPlatformOverride = null;
      BackgroundSshService.debugIsSupportedPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_backgroundSshChannel, null);
    });

    test(
      'status dispatch preserves arguments, gating, and channel failures',
      () async {
        for (final supported in [false, true]) {
          BackgroundSshService.debugIsSupportedPlatformOverride = supported;
          for (failure in [
            null,
            PlatformException(code: 'failed'),
            MissingPluginException(),
          ]) {
            methodCalls.clear();
            await BackgroundSshService.updateStatus(
              connectionCount: 3,
              connectedCount: 2,
            );
            await BackgroundSshService.setForegroundState(isForeground: false);
            await BackgroundSshService.stop();
            expect(methodCalls, hasLength(supported ? 3 : 0));
            if (!supported) continue;
            expect(methodCalls.map((call) => call.method), [
              'updateStatus',
              'setForegroundState',
              'stopService',
            ]);
            expect(methodCalls.map((call) => call.arguments), [
              {'connectionCount': 3, 'connectedCount': 2},
              {'isForeground': false},
              null,
            ]);
          }
        }
      },
    );

    test('isBatteryOptimizationIgnored queries the native channel', () async {
      batteryOptimizationIgnored = true;

      final result = await BackgroundSshService.isBatteryOptimizationIgnored();

      expect(result, isTrue);
      expect(methodCalls, hasLength(1));
      expect(methodCalls.single.method, 'isBatteryOptimizationIgnored');
    });

    test(
      'isBatteryOptimizationIgnored returns null when the channel fails',
      () async {
        failure = PlatformException(code: 'failed');

        final result =
            await BackgroundSshService.isBatteryOptimizationIgnored();

        expect(result, isNull);
        expect(methodCalls, hasLength(1));
        expect(methodCalls.single.method, 'isBatteryOptimizationIgnored');
      },
    );

    test(
      'requestDisableBatteryOptimization opens the native settings flow',
      () async {
        openedBatterySettings = true;

        final result =
            await BackgroundSshService.requestDisableBatteryOptimization();

        expect(result, isTrue);
        expect(methodCalls, hasLength(1));
        expect(methodCalls.single.method, 'requestDisableBatteryOptimization');
      },
    );

    test('unsupported platforms skip the native channel', () async {
      BackgroundSshService.debugIsAndroidPlatformOverride = false;

      final isIgnored =
          await BackgroundSshService.isBatteryOptimizationIgnored();
      final opened =
          await BackgroundSshService.requestDisableBatteryOptimization();

      expect(isIgnored, isTrue);
      expect(opened, isFalse);
      expect(methodCalls, isEmpty);
    });
  });
}

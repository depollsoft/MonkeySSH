import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/socks_browser_proxy_service.dart';

const _channel = MethodChannel(SocksBrowserProxyService.channelName);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;

  void handle(Future<Object?> Function(MethodCall call)? handler) {
    calls = [];
    messenger.setMockMethodCallHandler(
      _channel,
      handler == null
          ? null
          : (call) {
              calls.add(call);
              return handler(call);
            },
    );
  }

  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  group('support', () {
    for (final (platform, nativeSupport, expected) in [
      (TargetPlatform.iOS, true, SocksBrowserRoutingSupport.supported),
      (TargetPlatform.iOS, false, SocksBrowserRoutingSupport.requiresNewerIos),
      (
        TargetPlatform.android,
        false,
        SocksBrowserRoutingSupport.requiresNewerWebView,
      ),
    ]) {
      test(
        '${platform.name} native=$nativeSupport → ${expected.name}',
        () async {
          handle((_) async => nativeSupport);
          final service = SocksBrowserProxyService(platform: platform);

          expect(await service.support(), expected);
          expect(expected.isSupported, nativeSupport);
          expect(expected.unavailableReason == null, nativeSupport);
        },
      );
    }

    test('is unavailable without a native bridge', () async {
      handle(null);
      final service = SocksBrowserProxyService(platform: TargetPlatform.iOS);
      expect(await service.support(), SocksBrowserRoutingSupport.unavailable);

      final desktop = SocksBrowserProxyService(platform: TargetPlatform.macOS);
      handle((_) async => true);
      expect(await desktop.support(), SocksBrowserRoutingSupport.unavailable);
      expect(calls, isEmpty);
    });
  });

  test('routes while held and clears only after the last release', () {
    fakeAsync((async) {
      handle((_) async => null);
      final service = SocksBrowserProxyService(
        platform: TargetPlatform.android,
        clearDelay: const Duration(seconds: 1),
      );

      unawaited(service.hold(41080));
      async.flushMicrotasks();
      expect(calls.single.method, 'apply');
      expect(calls.single.arguments, {'port': 41080});
      expect(service.routedPort, 41080);

      unawaited(service.reroute(41081));
      async.flushMicrotasks();
      expect(calls.last.arguments, {'port': 41081});

      service.release();
      async.elapse(const Duration(milliseconds: 500));
      expect(calls.map((call) => call.method), isNot(contains('clear')));

      // Re-opening the browser before the delay keeps the proxy in place.
      unawaited(service.hold(41081));
      async.elapse(const Duration(seconds: 2));
      expect(calls.map((call) => call.method), isNot(contains('clear')));

      service.release();
      async.elapse(const Duration(seconds: 2));
      expect(calls.last.method, 'clear');
      expect(service.routedPort, isNull);
    });
  });

  test('a direct browser clears a released proxy immediately', () async {
    handle((_) async => null);
    final service = SocksBrowserProxyService(
      platform: TargetPlatform.iOS,
      clearDelay: const Duration(hours: 1),
    );

    await service.clearBeforeDirectBrowsing();
    expect(calls, isEmpty);

    await service.hold(41080);
    await service.clearBeforeDirectBrowsing();
    expect(calls.map((call) => call.method), ['apply']);

    service.release();
    await service.clearBeforeDirectBrowsing();
    expect(calls.map((call) => call.method), ['apply', 'clear']);
  });

  test('a refused proxy fails and is still cleared on release', () async {
    handle((call) async {
      if (call.method == 'apply') {
        throw PlatformException(code: 'apply_failed');
      }
      return null;
    });
    final service = SocksBrowserProxyService(
      platform: TargetPlatform.android,
      clearDelay: Duration.zero,
    );

    await expectLater(
      service.hold(41080),
      throwsA(
        isA<SocksBrowserProxyException>().having(
          (error) => error.code,
          'code',
          'apply_failed',
        ),
      ),
    );
    expect(service.routedPort, isNull);
    await expectLater(
      service.reroute(0),
      throwsA(isA<SocksBrowserProxyException>()),
    );

    service.release();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(calls.last.method, 'clear');
  });
}

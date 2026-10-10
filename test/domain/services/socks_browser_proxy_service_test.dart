import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/socks_browser_proxy_service.dart';

const _channel = MethodChannel(SocksBrowserProxyService.channelName);
const _sinkPort = 9;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<String> calls;

  void handle(Future<Object?> Function(MethodCall call)? handler) {
    calls = [];
    messenger.setMockMethodCallHandler(
      _channel,
      handler == null
          ? null
          : (call) {
              calls.add(
                call.method == 'apply'
                    ? 'apply:${(call.arguments as Map)['port']}'
                    : call.method,
              );
              return handler(call);
            },
    );
  }

  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  SocksBrowserProxyService service({
    TargetPlatform platform = TargetPlatform.android,
  }) => SocksBrowserProxyService(
    platform: platform,
    sinkPort: () async => _sinkPort,
  );

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
          expect(await service(platform: platform).support(), expected);
          expect(expected.isSupported, nativeSupport);
          expect(expected.unavailableReason == null, nativeSupport);
        },
      );
    }

    test('is unavailable without a native bridge', () async {
      handle(null);
      expect(
        await service(platform: TargetPlatform.iOS).support(),
        SocksBrowserRoutingSupport.unavailable,
      );

      handle((_) async => true);
      expect(
        await service(platform: TargetPlatform.macOS).support(),
        SocksBrowserRoutingSupport.unavailable,
      );
      expect(calls, isEmpty);
    });
  });

  test(
    'never clears on release: the last release points at the sink',
    () async {
      handle((_) async => null);
      final proxy = service();

      await proxy.hold(41080);
      expect(proxy.routedPort, 41080);
      await proxy.reroute(41081);
      await proxy.hold(41081);
      await proxy.release();
      expect(calls, ['apply:41080', 'apply:41081']);

      await proxy.release();
      expect(calls, ['apply:41080', 'apply:41081', 'apply:$_sinkPort']);
      expect(proxy.routedPort, isNull);
      expect(proxy.isHeld, isFalse);
    },
  );

  test('block points a held proxy at the sink until it is re-routed', () async {
    handle((_) async => null);
    final proxy = service();

    await proxy.hold(41080);
    await proxy.block();
    expect(proxy.routedPort, isNull);
    await proxy.reroute(41090);
    expect(calls, ['apply:41080', 'apply:$_sinkPort', 'apply:41090']);
    expect(proxy.routedPort, 41090);
  });

  test('Android sinks on a port no app can bind', () async {
    handle((_) async => null);
    final proxy = SocksBrowserProxyService(platform: TargetPlatform.android);

    await proxy.hold(41080);
    await proxy.release();
    expect(calls.last, 'apply:${SocksBrowserProxyService.androidSinkPort}');
  });

  test('iOS sinks on a listener this app holds and that refuses all', () async {
    handle((_) async => null);
    final proxy = SocksBrowserProxyService(platform: TargetPlatform.iOS);

    await proxy.hold(41080);
    await proxy.block();
    final sinkPort = int.parse(calls.last.split(':').last);
    expect(sinkPort, isNot(41080));
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, sinkPort);
    addTearDown(socket.destroy);
    await expectLater(socket.isEmpty, completion(isTrue));
  });

  test(
    'a direct browser clears once per isolate, then only after use',
    () async {
      handle((_) async => null);
      final proxy = service();

      // Process state may predate this isolate, so the first clear always runs.
      await proxy.clearBeforeDirectBrowsing();
      await proxy.clearBeforeDirectBrowsing();
      expect(calls, ['clear']);

      await proxy.hold(41080);
      await expectLater(
        proxy.clearBeforeDirectBrowsing(),
        throwsA(isA<SocksBrowserProxyException>()),
      );
      await proxy.release();
      await proxy.clearBeforeDirectBrowsing();
      expect(calls, ['clear', 'apply:41080', 'apply:$_sinkPort', 'clear']);
    },
  );

  test('a failed clear is reported, not treated as success', () async {
    handle((call) async {
      if (call.method == 'clear') {
        throw PlatformException(code: 'clear_failed');
      }
      return null;
    });
    final proxy = service();

    await expectLater(
      proxy.clearBeforeDirectBrowsing(),
      throwsA(
        isA<SocksBrowserProxyException>().having(
          (error) => error.code,
          'code',
          'clear_failed',
        ),
      ),
    );
    // Still unresolved, so the next attempt tries again.
    await expectLater(
      proxy.clearBeforeDirectBrowsing(),
      throwsA(isA<SocksBrowserProxyException>()),
    );
    expect(calls, ['clear', 'clear']);
  });

  test('a refused proxy fails and the release still sinks it', () async {
    handle((call) async {
      if (call.method == 'apply' && (call.arguments as Map)['port'] == 41080) {
        throw PlatformException(code: 'apply_failed');
      }
      return null;
    });
    final proxy = service();

    await expectLater(
      proxy.hold(41080),
      throwsA(
        isA<SocksBrowserProxyException>().having(
          (error) => error.code,
          'code',
          'apply_failed',
        ),
      ),
    );
    expect(proxy.routedPort, isNull);
    await expectLater(
      proxy.reroute(0),
      throwsA(isA<SocksBrowserProxyException>()),
    );

    await proxy.release();
    expect(calls.last, 'apply:$_sinkPort');
  });
}

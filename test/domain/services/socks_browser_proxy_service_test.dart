import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/socks_browser_proxy_service.dart';

const _channel = MethodChannel(SocksBrowserProxyService.channelName);
const _sinkPort = 9;
// Saved forward ids of two SOCKS rules.
const _office = 7;
const _lab = 8;

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

      await proxy.hold(41080, owner: _office);
      expect(proxy.routedPort, 41080);
      await proxy.reroute(41081);
      await proxy.hold(41081, owner: _office);
      await proxy.release();
      expect(calls, ['apply:41080', 'apply:41081']);

      await proxy.release();
      expect(calls, ['apply:41080', 'apply:41081', 'apply:$_sinkPort']);
      expect(proxy.routedPort, isNull);
      expect(proxy.isHeld, isFalse);
    },
  );

  test('a release behind another browser waits for its queued apply', () async {
    final gate = Completer<void>();
    handle((call) async {
      if (call.method == 'apply' && (call.arguments as Map)['port'] == 41090) {
        await gate.future;
      }
      return null;
    });
    final proxy = service();

    // Two browsers on one forward; it moves, and one re-routes.
    await proxy.hold(41080, owner: _office);
    await proxy.hold(41080, owner: _office);
    final second = proxy.reroute(41090);
    bool? released;
    unawaited(proxy.release().then((sunk) => released = sunk));
    await pumpEventQueue();
    // Until the proxy has moved, the first browser must not free its port.
    expect(released, isNull);

    gate.complete();
    await second;
    await pumpEventQueue();
    expect(released, isTrue);
    expect(calls, ['apply:41080', 'apply:41090']);
  });

  test('a hold for another forward is refused while one is held', () async {
    handle((_) async => null);
    final proxy = service();

    await proxy.hold(41080, owner: _office);
    // Taking the shared proxy would send the open browser's pages, with its
    // host's cookies, through the other forward's host.
    await expectLater(
      proxy.hold(41090, owner: _lab),
      throwsA(
        isA<SocksBrowserProxyException>().having(
          (error) => error.code,
          'code',
          'held_elsewhere',
        ),
      ),
    );
    expect(calls, ['apply:41080']);
    expect(proxy.routedPort, 41080);

    // The refused hold was not counted, so one release frees the proxy.
    expect(await proxy.release(), isTrue);
    expect(proxy.isHeld, isFalse);
    await proxy.hold(41090, owner: _lab);
    expect(calls, ['apply:41080', 'apply:$_sinkPort', 'apply:41090']);
  });

  test('a port reused by another forward does not share the hold', () async {
    handle((_) async => null);
    final proxy = service();

    await proxy.hold(41080, owner: _office);
    // The office forward stops; its browser stays open and keeps its hold.
    expect(await proxy.block(), isTrue);
    // The lab forward binds the freed port number.
    await expectLater(
      proxy.hold(41080, owner: _lab),
      throwsA(
        isA<SocksBrowserProxyException>().having(
          (error) => error.code,
          'code',
          'held_elsewhere',
        ),
      ),
    );
    expect(calls, ['apply:41080', 'apply:$_sinkPort']);
  });

  test('a release sinks its port before a newer hold is applied', () async {
    final gate = Completer<void>();
    handle((call) async {
      if (call.method == 'apply' && (call.arguments as Map)['port'] == 41080) {
        await gate.future;
      }
      return null;
    });
    final proxy = service();

    final first = proxy.hold(41080, owner: _office);
    // The office browser closes while its apply is still pending, and a lab
    // browser takes the proxy right after.
    final released = proxy.release();
    final second = proxy.hold(41090, owner: _lab);
    gate.complete();
    await first;
    // The office forward may stop only once the proxy has left its port,
    // whether or not the lab apply then lands.
    expect(await released, isTrue);
    await second;
    expect(calls, ['apply:41080', 'apply:$_sinkPort', 'apply:41090']);
  });

  test('a release after a failed re-route sinks the unknown target', () async {
    handle((call) async {
      if (call.method == 'apply' && (call.arguments as Map)['port'] == 41090) {
        throw PlatformException(code: 'apply_failed');
      }
      return null;
    });
    final proxy = service();

    await proxy.hold(41080, owner: _office);
    await proxy.hold(41080, owner: _office);
    await expectLater(
      proxy.reroute(41090),
      throwsA(isA<SocksBrowserProxyException>()),
    );
    // The other browser still holds, but the native proxy may still target
    // 41080, so it must move before that port is freed.
    expect(await proxy.release(), isTrue);
    expect(calls, ['apply:41080', 'apply:41090', 'apply:$_sinkPort']);
  });

  test('block points a held proxy at the sink until it is re-routed', () async {
    handle((_) async => null);
    final proxy = service();

    await proxy.hold(41080, owner: _office);
    await proxy.block();
    expect(proxy.routedPort, isNull);
    await proxy.reroute(41090);
    expect(calls, ['apply:41080', 'apply:$_sinkPort', 'apply:41090']);
    expect(proxy.routedPort, 41090);
  });

  test('Android sinks on a port no app can bind', () async {
    handle((_) async => null);
    final proxy = SocksBrowserProxyService(platform: TargetPlatform.android);

    await proxy.hold(41080, owner: _office);
    await proxy.release();
    expect(calls.last, 'apply:${SocksBrowserProxyService.androidSinkPort}');
  });

  test('iOS sinks on a listener this app holds and that refuses all', () async {
    handle((_) async => null);
    final proxy = SocksBrowserProxyService(platform: TargetPlatform.iOS);

    await proxy.hold(41080, owner: _office);
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
      proxy
        ..endDirectBrowsing()
        ..endDirectBrowsing();

      await proxy.hold(41080, owner: _office);
      await expectLater(
        proxy.clearBeforeDirectBrowsing(),
        throwsA(isA<SocksBrowserProxyException>()),
      );
      await proxy.release();
      await proxy.clearBeforeDirectBrowsing();
      expect(calls, ['clear', 'apply:41080', 'apply:$_sinkPort', 'clear']);
    },
  );

  test('an open direct browser keeps an Android SOCKS hold out', () async {
    handle((_) async => null);
    final proxy = service();

    await proxy.clearBeforeDirectBrowsing();
    // The process-wide override would route the direct browser's pages too.
    await expectLater(
      proxy.hold(41080, owner: _office),
      throwsA(
        isA<SocksBrowserProxyException>().having(
          (error) => error.code,
          'code',
          'held_elsewhere',
        ),
      ),
    );
    expect(proxy.isHeld, isFalse);

    proxy.endDirectBrowsing();
    await proxy.hold(41080, owner: _office);
    expect(calls, ['clear', 'apply:41080']);
  });

  test('a hold made while a direct clear is in flight is refused', () async {
    final gate = Completer<void>();
    handle((call) async {
      if (call.method == 'clear') {
        await gate.future;
      }
      return null;
    });
    final proxy = service();

    final clear = proxy.clearBeforeDirectBrowsing();
    await pumpEventQueue();
    // The clear is awaiting the platform; a SOCKS browser opens now.
    await expectLater(
      proxy.hold(41080, owner: _office),
      throwsA(isA<SocksBrowserProxyException>()),
    );
    gate.complete();
    await clear;
    await pumpEventQueue();
    expect(calls, ['clear']);
    expect(proxy.isHeld, isFalse);
  });

  test('a failed clear does not count a direct browser', () async {
    handle((call) async {
      if (call.method == 'clear') {
        throw PlatformException(code: 'clear_failed');
      }
      return null;
    });
    final proxy = service();

    await expectLater(
      proxy.clearBeforeDirectBrowsing(),
      throwsA(isA<SocksBrowserProxyException>()),
    );
    await proxy.hold(41080, owner: _office);
    expect(proxy.routedPort, 41080);
  });

  test(
    'iOS routes SOCKS stores only, so a direct browser does not block',
    () async {
      handle((_) async => null);
      final proxy = service(platform: TargetPlatform.iOS);

      await proxy.clearBeforeDirectBrowsing();
      await proxy.hold(41080, owner: _office);
      expect(calls, ['clear', 'apply:41080']);
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
      proxy.hold(41080, owner: _office),
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

  test('reports when the sink could not be applied', () async {
    handle((call) async {
      if (call.method == 'apply' &&
          (call.arguments as Map)['port'] == _sinkPort) {
        throw PlatformException(code: 'apply_failed');
      }
      return null;
    });
    final proxy = service();

    await proxy.hold(41080, owner: _office);
    expect(await proxy.block(), isFalse);
    await proxy.reroute(41080);
    // The caller keeps the forward listening while the proxy targets it.
    expect(await proxy.release(), isFalse);
  });

  group('iOS sink', () {
    test('a lost sink is replaced and the proxy moved off it', () async {
      handle((_) async => null);
      final sinks = <_FakeSink>[];
      final proxy = SocksBrowserProxyService(
        platform: TargetPlatform.iOS,
        bindSink: () async {
          final sink = _FakeSink(50000 + sinks.length);
          sinks.add(sink);
          return sink;
        },
      );

      await proxy.hold(41080, owner: _office);
      expect(await proxy.release(), isTrue);
      expect(calls.last, 'apply:50000');

      // iOS reclaims the listener while the app is suspended; an error event
      // must not escape as an uncaught error.
      sinks.single.connections.addError(const SocketException('reclaimed'));
      await pumpEventQueue();
      expect(sinks, hasLength(2));
      expect(calls.last, 'apply:50001');
    });

    test('a sink lost while its apply is pending is still replaced', () async {
      final gate = Completer<void>();
      handle((call) async {
        if (call.method == 'apply' &&
            (call.arguments as Map)['port'] == 50020) {
          await gate.future;
        }
        return null;
      });
      final sinks = <_FakeSink>[];
      final proxy = SocksBrowserProxyService(
        platform: TargetPlatform.iOS,
        bindSink: () async {
          final sink = _FakeSink(50020 + sinks.length);
          sinks.add(sink);
          return sink;
        },
      );

      await proxy.hold(41080, owner: _office);
      final released = proxy.release();
      await pumpEventQueue();
      expect(calls.last, 'apply:50020');

      // The listener closes before the apply that points at it returns.
      await sinks.single.connections.close();
      await pumpEventQueue();
      gate.complete();
      expect(await released, isTrue);
      await pumpEventQueue();
      expect(sinks, hasLength(2));
      expect(calls.last, 'apply:50021');
    });

    test('a failed bind is retried on the next block', () async {
      handle((_) async => null);
      var attempts = 0;
      final proxy = SocksBrowserProxyService(
        platform: TargetPlatform.iOS,
        bindSink: () async {
          attempts++;
          if (attempts == 1) {
            throw const SocketException('too many open files');
          }
          return _FakeSink(50010);
        },
      );

      await proxy.hold(41080, owner: _office);
      expect(await proxy.block(), isFalse);
      expect(calls, ['apply:41080']);
      expect(await proxy.block(), isTrue);
      expect(calls, ['apply:41080', 'apply:50010']);
    });
  });
}

/// A sink listener whose accept stream the test can fail, like iOS
/// reclaiming it.
class _FakeSink extends Stream<Socket> implements ServerSocket {
  _FakeSink(this.port);

  // Ended by the test, or left open when the test finishes.
  // ignore: close_sinks
  final connections = StreamController<Socket>();

  @override
  final int port;

  @override
  InternetAddress get address => InternetAddress.loopbackIPv4;

  @override
  StreamSubscription<Socket> listen(
    void Function(Socket event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => connections.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  Future<ServerSocket> close() async => this;
}

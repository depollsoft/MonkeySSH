import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'diagnostics_log_service.dart';
import 'serial_task_queue.dart';

/// Whether the in-app browser can route its traffic through a SOCKS forward.
enum SocksBrowserRoutingSupport {
  /// Native proxy configuration is available.
  supported,

  /// WKWebView only accepts proxy configurations from iOS 17.
  requiresNewerIos,

  /// The installed Android System WebView cannot override its proxy.
  requiresNewerWebView,

  /// This platform has no native proxy bridge for the in-app browser.
  unavailable,
}

/// User-facing text for [SocksBrowserRoutingSupport].
extension SocksBrowserRoutingSupportText on SocksBrowserRoutingSupport {
  /// Whether SOCKS browsing is available.
  bool get isSupported => this == SocksBrowserRoutingSupport.supported;

  /// Why the browser option is hidden, or null when it is available.
  String? get unavailableReason => switch (this) {
    SocksBrowserRoutingSupport.supported => null,
    SocksBrowserRoutingSupport.requiresNewerIos =>
      'In-app browsing through SOCKS needs iOS 17 or later.',
    SocksBrowserRoutingSupport.requiresNewerWebView =>
      'In-app browsing through SOCKS needs a newer Android System WebView.',
    SocksBrowserRoutingSupport.unavailable =>
      'In-app browsing through SOCKS isn’t available on this device.',
  };
}

/// Thrown when the platform could not route the browser through the proxy.
class SocksBrowserProxyException implements Exception {
  /// Creates an exception with a short, data-free [code].
  const SocksBrowserProxyException(this.code);

  /// Short failure code, safe to log.
  final String code;

  @override
  String toString() => 'SocksBrowserProxyException($code)';
}

/// Routes the in-app browser's web views through a loopback SOCKS5 listener.
///
/// `webview_flutter` exposes no proxy settings, so a small platform channel
/// sets them natively: `proxyConfigurations` on the default
/// `WKWebsiteDataStore` on iOS 17+, and a process-wide `ProxyController`
/// override on Android. Neither configuration falls back to a direct
/// connection.
///
/// Once applied, the proxy is never simply removed while web content may
/// still be alive. When the forward drops ([block]) or the SOCKS browser
/// closes ([release]) it is pointed at a sink that refuses every connection,
/// so a page that keeps polling fails instead of going direct. Only a browser
/// that must not use the proxy clears it, through [clearBeforeDirectBrowsing].
class SocksBrowserProxyService {
  /// Creates the service. [channel], [platform], [sinkPort] and [bindSink]
  /// are injectable for tests.
  SocksBrowserProxyService({
    MethodChannel? channel,
    TargetPlatform? platform,
    Future<int> Function()? sinkPort,
    Future<ServerSocket> Function()? bindSink,
  }) : _channel = channel ?? const MethodChannel(channelName),
       _platform = platform,
       _sinkPortOverride = sinkPort,
       _bindSink =
           bindSink ??
           (() => ServerSocket.bind(InternetAddress.loopbackIPv4, 0));

  /// Name of the native method channel.
  static const channelName = 'xyz.depollsoft.monkeyssh/socks_browser_proxy';

  /// Android's sink: unprivileged apps cannot bind ports below 1024, so
  /// nothing on the device can listen here and every connection is refused.
  static const androidSinkPort = 1;

  final MethodChannel _channel;
  final TargetPlatform? _platform;
  final Future<int> Function()? _sinkPortOverride;
  final Future<ServerSocket> Function() _bindSink;
  final _queue = SerialTaskQueue();
  Future<SocksBrowserRoutingSupport>? _support;
  Future<int>? _sinkPort;
  int? _appliedPort;
  int? _routedPort;
  // The native override is process state that can outlive this isolate (hot
  // restart, engine re-creation), so a direct browser clears it once per
  // isolate even when this service never applied it.
  var _mayBeApplied = true;
  var _holders = 0;

  /// Loopback port of the forward the browser routes through, or null while
  /// the proxy is unset or pointed at the sink.
  int? get routedPort => _routedPort;

  /// Whether a SOCKS browser currently holds the proxy.
  bool get isHeld => _holders > 0;

  /// Reports whether this device can route the browser through SOCKS.
  Future<SocksBrowserRoutingSupport> support() => _support ??= _loadSupport();

  TargetPlatform get _targetPlatform => _platform ?? defaultTargetPlatform;

  Future<SocksBrowserRoutingSupport> _loadSupport() async {
    final platform = _targetPlatform;
    if (kIsWeb ||
        (platform != TargetPlatform.iOS &&
            platform != TargetPlatform.android)) {
      return SocksBrowserRoutingSupport.unavailable;
    }
    try {
      final supported = await _channel.invokeMethod<bool>('isSupported');
      if (supported ?? false) {
        return SocksBrowserRoutingSupport.supported;
      }
    } on MissingPluginException {
      return SocksBrowserRoutingSupport.unavailable;
    } on PlatformException catch (error) {
      _log('support_check_failed', code: error.code);
      return SocksBrowserRoutingSupport.unavailable;
    }
    return platform == TargetPlatform.iOS
        ? SocksBrowserRoutingSupport.requiresNewerIos
        : SocksBrowserRoutingSupport.requiresNewerWebView;
  }

  /// Takes a hold on the proxy and routes the browser through [port].
  ///
  /// Throws [SocksBrowserProxyException] when the platform refuses; the
  /// caller must not load pages then. Balance every call with [release].
  Future<void> hold(int port) {
    _holders++;
    return _route(port);
  }

  /// Re-routes a held proxy through [port] after the forward moved.
  Future<void> reroute(int port) {
    if (_holders == 0) {
      return Future<void>.error(const SocksBrowserProxyException('not_held'));
    }
    return _route(port);
  }

  Future<void> _route(int port) {
    if (port < 1 || port > 65535) {
      return Future<void>.error(
        const SocksBrowserProxyException('invalid_port'),
      );
    }
    return _queue.run(() async {
      await _applyUnlocked(port);
      _routedPort = port;
    });
  }

  /// Points a held proxy at the sink because the forward stopped.
  ///
  /// Its listener port is free again and any app could bind it, so the
  /// browser must not keep sending traffic there. Returns whether the proxy
  /// now targets the sink; on false it still targets the previous port.
  Future<bool> block() => _queue.run(_blockUnlocked);

  /// Drops a hold taken by [hold]. The last release points the proxy at the
  /// sink instead of clearing it, because the closed browser's web view can
  /// outlive its widget and keep issuing requests.
  ///
  /// Returns false when the last release could not reach the sink. The proxy
  /// then still targets the forward's port, so the caller must keep that
  /// forward listening rather than free the port for another app.
  Future<bool> release() {
    if (_holders == 0) {
      return Future<bool>.value(true);
    }
    _holders--;
    if (_holders > 0) {
      return Future<bool>.value(true);
    }
    return _queue.run(() async => _holders > 0 || await _blockUnlocked());
  }

  Future<bool> _blockUnlocked() async {
    _routedPort = null;
    try {
      await _applyUnlocked(await _currentSinkPort());
      return true;
    } on SocksBrowserProxyException {
      // Logged by the apply; the previous target stays in place.
      return false;
    } on SocketException catch (error) {
      _log('sink_failed', code: error.runtimeType.toString());
      return false;
    }
  }

  /// The sink port, binding a new sink when there is none yet or the last
  /// one was lost. A failed bind is not cached, so the next block retries.
  Future<int> _currentSinkPort() async {
    final pending = _sinkPort ??= _loadSinkPort();
    try {
      return await pending;
    } on Object {
      if (identical(_sinkPort, pending)) {
        _sinkPort = null;
      }
      rethrow;
    }
  }

  Future<void> _applyUnlocked(int port) async {
    if (_appliedPort == port) {
      return;
    }
    _appliedPort = null;
    _mayBeApplied = true;
    try {
      await _channel.invokeMethod<void>('apply', {'port': port});
    } on MissingPluginException {
      _log('apply_failed', code: 'missing_plugin');
      throw const SocksBrowserProxyException('unavailable');
    } on PlatformException catch (error) {
      _log('apply_failed', code: error.code);
      throw SocksBrowserProxyException(error.code);
    }
    _appliedPort = port;
  }

  Future<int> _loadSinkPort() async {
    final override = _sinkPortOverride;
    if (override != null) {
      return override();
    }
    if (_targetPlatform == TargetPlatform.android) {
      return androidSinkPort;
    }
    // iOS lets apps bind low ports, so hold a loopback port that refuses
    // every client. While this app owns it, no other app can listen there.
    final sink = await _bindSink();
    final port = sink.port;
    var lost = false;
    void sinkLost() {
      if (lost) return;
      lost = true;
      _handleSinkLost(port);
    }

    sink.listen(
      (socket) => socket.destroy(),
      // iOS can reclaim a suspended app's listener. Handling the error keeps
      // it from surfacing as an uncaught (fatal) error.
      onError: (Object _, StackTrace _) => sinkLost(),
      onDone: sinkLost,
    );
    return port;
  }

  /// Replaces a sink listener that closed, moving the proxy to a new sink if
  /// it was pointed at the lost one: its port is free for any app to bind.
  void _handleSinkLost(int port) {
    _log('sink_lost', code: 'listener_closed');
    _sinkPort = null;
    if (_appliedPort != port) {
      return;
    }
    _appliedPort = null;
    unawaited(
      _queue.run(() async {
        // A forward routed meanwhile replaced the sink; leave it.
        if (_routedPort == null && _appliedPort == null) {
          await _blockUnlocked();
        }
      }),
    );
  }

  /// Removes the proxy before a browser that must load pages directly.
  ///
  /// Throws [SocksBrowserProxyException] while a SOCKS browser holds the
  /// proxy or when the platform could not remove it; the caller must not
  /// load pages then.
  Future<void> clearBeforeDirectBrowsing() => _queue.run(() async {
    if (_holders > 0) {
      throw const SocksBrowserProxyException('held');
    }
    if (!_mayBeApplied) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('clear');
    } on MissingPluginException {
      // No native bridge here, so nothing was ever applied.
    } on PlatformException catch (error) {
      _log('clear_failed', code: error.code);
      throw SocksBrowserProxyException(error.code);
    }
    _mayBeApplied = false;
    _appliedPort = null;
    _routedPort = null;
  });

  void _log(String event, {required String code}) {
    DiagnosticsLogService.instance.warning(
      'browser.socks',
      event,
      fields: {'code': code},
    );
  }
}

/// App-wide SOCKS browser proxy bridge.
final socksBrowserProxyServiceProvider = Provider<SocksBrowserProxyService>(
  (ref) => SocksBrowserProxyService(),
);

/// Whether this device can route the in-app browser through SOCKS.
final socksBrowserRoutingSupportProvider =
    FutureProvider<SocksBrowserRoutingSupport>(
      (ref) => ref.watch(socksBrowserProxyServiceProvider).support(),
    );

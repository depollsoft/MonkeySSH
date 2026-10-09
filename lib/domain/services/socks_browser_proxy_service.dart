import 'dart:async';

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
/// connection, so while it stays applied a dropped forward makes pages fail
/// instead of loading over the device's own network.
///
/// The configuration stays applied until [release], then clears after a short
/// delay so a closing web view cannot issue a last request directly. A
/// browser that must not use the proxy awaits [clearBeforeDirectBrowsing].
class SocksBrowserProxyService {
  /// Creates the service. [channel] and [platform] are injectable for tests.
  SocksBrowserProxyService({
    MethodChannel? channel,
    TargetPlatform? platform,
    this.clearDelay = const Duration(milliseconds: 750),
  }) : _channel = channel ?? const MethodChannel(channelName),
       _platform = platform;

  /// Name of the native method channel.
  static const channelName = 'xyz.depollsoft.monkeyssh/socks_browser_proxy';

  /// How long a released proxy stays applied before it is cleared.
  final Duration clearDelay;

  final MethodChannel _channel;
  final TargetPlatform? _platform;
  final _queue = SerialTaskQueue();
  Future<SocksBrowserRoutingSupport>? _support;
  Timer? _clearTimer;
  int? _routedPort;
  // Set from the first apply attempt until a clear succeeds, so a failed or
  // partial apply is still cleared.
  var _mayBeApplied = false;
  var _holders = 0;

  /// Loopback port the browser currently routes through, or null.
  int? get routedPort => _routedPort;

  /// Whether a SOCKS browser currently holds the proxy.
  bool get isHeld => _holders > 0;

  /// Reports whether this device can route the browser through SOCKS.
  Future<SocksBrowserRoutingSupport> support() => _support ??= _loadSupport();

  Future<SocksBrowserRoutingSupport> _loadSupport() async {
    final platform = _platform ?? defaultTargetPlatform;
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
    _clearTimer?.cancel();
    _clearTimer = null;
    return _apply(port);
  }

  /// Re-routes a held proxy through [port] after the forward moved.
  Future<void> reroute(int port) {
    if (_holders == 0) {
      return Future<void>.error(const SocksBrowserProxyException('not_held'));
    }
    return _apply(port);
  }

  Future<void> _apply(int port) {
    if (port < 1 || port > 65535) {
      return Future<void>.error(
        const SocksBrowserProxyException('invalid_port'),
      );
    }
    return _queue.run(() async {
      if (_routedPort == port) {
        return;
      }
      _routedPort = null;
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
      _routedPort = port;
    });
  }

  /// Drops a hold taken by [hold]; the last release clears the proxy after
  /// [clearDelay].
  void release() {
    if (_holders == 0) {
      return;
    }
    _holders--;
    if (_holders > 0) {
      return;
    }
    _clearTimer?.cancel();
    _clearTimer = Timer(clearDelay, () {
      _clearTimer = null;
      if (_holders == 0) {
        unawaited(_clear());
      }
    });
  }

  /// Clears a released proxy now so a direct browser does not use it.
  ///
  /// Does nothing while a SOCKS browser still holds the proxy.
  Future<void> clearBeforeDirectBrowsing() async {
    if (_holders > 0) {
      return;
    }
    _clearTimer?.cancel();
    _clearTimer = null;
    await _clear();
  }

  Future<void> _clear() => _queue.run(() async {
    if (!_mayBeApplied || _holders > 0) {
      return;
    }
    _routedPort = null;
    try {
      await _channel.invokeMethod<void>('clear');
      _mayBeApplied = false;
    } on MissingPluginException {
      _mayBeApplied = false;
    } on PlatformException catch (error) {
      _log('clear_failed', code: error.code);
    }
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

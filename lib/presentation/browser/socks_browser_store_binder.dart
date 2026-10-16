import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../../domain/services/socks_browser_proxy_service.dart';
import '../../domain/services/socks_browser_store_service.dart';

/// Puts a SOCKS browser's web view in its host's own website data store.
///
/// See [SocksBrowserStoreService] for why each host has one. Every step
/// throws [SocksBrowserProxyException] when the store could not be set, and
/// the browser then loads nothing in that web view.
class SocksBrowserStoreBinder {
  /// Creates a binder over [stores].
  const SocksBrowserStoreBinder(this._stores);

  final SocksBrowserStoreService _stores;

  /// The store id for [hostId]'s browser; see
  /// [SocksBrowserStoreService.openHostStore].
  Future<String> openHostStore(int hostId) => _stores.openHostStore(hostId);

  /// Creation parameters for a web view whose data lives in [storeId]'s
  /// store.
  ///
  /// WebKit fixes a web view's store when it creates it, so on iOS the store
  /// goes on the configuration here, before the controller exists.
  Future<PlatformWebViewControllerCreationParams> creationParams(
    String storeId,
  ) async {
    final platform = WebViewPlatform.instance;
    if (platform is WebKitWebViewPlatform) {
      final params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
      );
      await _stores.bindConfiguration(
        storeId,
        params.webViewConfigurationIdentifier,
      );
      return params;
    }
    if (platform is AndroidWebViewPlatform) {
      return const PlatformWebViewControllerCreationParams();
    }
    throw const SocksBrowserProxyException('unsupported_webview');
  }

  /// Sets (Android) or confirms (iOS) the store of [controller]'s web view.
  /// Call it straight after creating the controller: an Android profile can
  /// only be set before the web view is used.
  Future<void> attach(String storeId, WebViewController controller) =>
      switch (controller.platform) {
        final WebKitWebViewController webKit => _stores.attachWebView(
          storeId,
          webKit.webViewIdentifier,
        ),
        final AndroidWebViewController android => _stores.attachWebView(
          storeId,
          android.webViewIdentifier,
        ),
        _ => Future<void>.error(
          const SocksBrowserProxyException('unsupported_webview'),
        ),
      };
}

/// Binds SOCKS browser web views to their host's store.
final socksBrowserStoreBinderProvider = Provider<SocksBrowserStoreBinder>(
  (ref) => SocksBrowserStoreBinder(ref.watch(socksBrowserStoreServiceProvider)),
);

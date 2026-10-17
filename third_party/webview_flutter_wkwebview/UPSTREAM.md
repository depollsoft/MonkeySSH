# Upstream source

This package is vendored from `webview_flutter_wkwebview` **3.26.1** on pub.dev
(flutter/packages, BSD licensed; see `LICENSE`). Only `lib/`, the darwin
sources, the podspec, `pubspec.yaml`, `LICENSE`, `AUTHORS`, `README.md` and
`CHANGELOG.md` are kept; the upstream tests, example app and pigeon sources
live in the upstream repository. `analysis_options.yaml` is ours and only sets
the formatter's page width; with it, `dart format` changes nothing but one
blank line in `lib/src/webkit_ssl_auth_error.dart`.

## Patch

MonkeySSH's SOCKS browser keeps each saved host's website data in its own
`WKWebsiteDataStore(forIdentifier:)` (iOS 17). A `WKWebView` copies its
configuration when it is created, so the store has to be set on the
configuration first, and the plugin creates that configuration internally. The
patch adds two read-only accessors and changes no existing behaviour:

- `lib/src/webkit_webview_controller.dart`:
  `WebKitWebViewControllerCreationParams.webViewConfigurationIdentifier`, the
  instance-manager identifier of the parameters' `WKWebViewConfiguration`.
- `darwin/.../WebViewFlutterWKWebViewExternalAPI.swift`:
  `FWFWebViewFlutterWKWebViewExternalAPI.webViewConfiguration(forIdentifier:withPluginRegistrar:)`,
  which returns the native configuration for that identifier (iOS only, like
  the existing `webView(forIdentifier:withPluginRegistrar:)`).

`ios/Runner/SocksBrowserProxyChannel.swift` uses them. Replace this directory
with the published package if upstream gains a way to choose a web view's data
store, and move that code to it.

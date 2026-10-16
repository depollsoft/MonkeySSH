import Flutter
import Network
import WebKit
import webview_flutter_wkwebview

/// Routes the in-app SOCKS browser through a loopback SOCKS5 forward, and
/// keeps each saved host's pages in a website data store of its own.
///
/// Pages reached through SOCKS keep their real origins, so each host's
/// browser uses `WKWebsiteDataStore(forIdentifier:)` with a random id the
/// app saves per host (iOS 17+, like `proxyConfigurations`). The loopback
/// browser keeps the default store. Every identified data store in this app
/// belongs to SOCKS browsing: the app deletes the ones no saved host names.
///
/// `webview_flutter` exposes neither proxy settings nor the data store, so
/// the browser binds the store to the web view's configuration through a
/// patched `webview_flutter_wkwebview` (see third_party), and this channel
/// sets `proxyConfigurations` on every live SOCKS store. The configuration
/// never fails over to a direct connection: when the forward drops, loads
/// fail instead of leaving over the device's own network.
@MainActor
final class SocksBrowserProxyChannel {
  private static let channelName = "xyz.depollsoft.monkeyssh/socks_browser_proxy"

  private let channel: FlutterMethodChannel
  private let registrar: FlutterPluginRegistrar
  /// The forward (or sink) port the browser routes through, or nil after a
  /// loopback browser cleared the proxy.
  private var proxyPort: NWEndpoint.Port?
  /// SOCKS stores that web views may still use. Weak, because WebKit only
  /// deletes a store once nothing holds it.
  private let liveStores = NSHashTable<WKWebsiteDataStore>.weakObjects()

  private init(channel: FlutterMethodChannel, registrar: FlutterPluginRegistrar) {
    self.channel = channel
    self.registrar = registrar
  }

  static func register(with registrar: FlutterPluginRegistrar) -> SocksBrowserProxyChannel {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    let handler = SocksBrowserProxyChannel(channel: channel, registrar: registrar)
    // Flutter delivers platform channel calls on the main thread.
    channel.setMethodCallHandler { call, result in
      handler.handle(call, result: result)
    }
    return handler
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "isSupported" {
      if #available(iOS 17.0, *) {
        result(true)
      } else {
        result(false)
      }
      return
    }
    guard #available(iOS 17.0, *) else {
      switch call.method {
      case "clear", "deleteDataStore":
        result(nil)
      case "listDataStores":
        result([String]())
      default:
        result(
          FlutterError(
            code: "unsupported",
            message: "Web view proxies need iOS 17 or later",
            details: nil
          )
        )
      }
      return
    }
    switch call.method {
    case "apply":
      apply(call, result: result)
    case "clear":
      // Only the default store: SOCKS stores keep the sink their browser
      // left, since their web views may outlive the browser.
      proxyPort = nil
      WKWebsiteDataStore.default().proxyConfigurations = []
      result(nil)
    case "bindDataStore":
      bindDataStore(call, result: result)
    case "attachDataStore":
      attachDataStore(call, result: result)
    case "deleteDataStore":
      deleteDataStore(call, result: result)
    case "listDataStores":
      WKWebsiteDataStore.fetchAllDataStoreIdentifiers { identifiers in
        result(identifiers.map { $0.uuidString.lowercased() })
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  @available(iOS 17.0, *)
  private func proxyConfiguration(port: NWEndpoint.Port) -> ProxyConfiguration {
    var configuration = ProxyConfiguration(
      socksv5Proxy: .hostPort(host: .ipv4(.loopback), port: port)
    )
    configuration.allowFailover = false
    return configuration
  }

  @available(iOS 17.0, *)
  private func apply(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let arguments = call.arguments as? [String: Any],
      let port = arguments["port"] as? Int,
      (1...65535).contains(port),
      let endpointPort = NWEndpoint.Port(rawValue: UInt16(port))
    else {
      result(
        FlutterError(code: "invalid_port", message: "SOCKS port is out of range", details: nil)
      )
      return
    }
    proxyPort = endpointPort
    let configuration = proxyConfiguration(port: endpointPort)
    for store in liveStores.allObjects {
      store.proxyConfigurations = [configuration]
    }
    result(nil)
  }

  private static func storeIdentifier(_ call: FlutterMethodCall) -> UUID? {
    guard
      let arguments = call.arguments as? [String: Any],
      let store = arguments["store"] as? String,
      let identifier = UUID(uuidString: store),
      identifier.uuidString.lowercased() == store
    else {
      return nil
    }
    return identifier
  }

  private static func invalidStore() -> FlutterError {
    FlutterError(code: "invalid_store", message: "Store id is invalid", details: nil)
  }

  /// Gives the configuration a SOCKS browser's web view is about to be
  /// created with the store of its host, already pointed at the proxy.
  @available(iOS 17.0, *)
  private func bindDataStore(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let identifier = Self.storeIdentifier(call),
      let configurationId = (call.arguments as? [String: Any])?["configuration"] as? Int
    else {
      result(Self.invalidStore())
      return
    }
    guard let port = proxyPort else {
      // Never hand out a store without the proxy: its pages would go direct.
      result(FlutterError(code: "not_routed", message: "No SOCKS proxy is set", details: nil))
      return
    }
    guard
      let configuration = FWFWebViewFlutterWKWebViewExternalAPI.webViewConfiguration(
        forIdentifier: Int64(configurationId), withPluginRegistrar: registrar)
    else {
      result(
        FlutterError(
          code: "configuration_missing", message: "The web view configuration is gone",
          details: nil)
      )
      return
    }
    let store = WKWebsiteDataStore(forIdentifier: identifier)
    store.proxyConfigurations = [proxyConfiguration(port: port)]
    configuration.websiteDataStore = store
    liveStores.add(store)
    result(nil)
  }

  /// Confirms the web view kept the store [bindDataStore] set, with a proxy.
  @available(iOS 17.0, *)
  private func attachDataStore(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let identifier = Self.storeIdentifier(call),
      let webViewId = (call.arguments as? [String: Any])?["webView"] as? Int
    else {
      result(Self.invalidStore())
      return
    }
    guard
      let webView = FWFWebViewFlutterWKWebViewExternalAPI.webView(
        forIdentifier: Int64(webViewId), withPluginRegistrar: registrar)
    else {
      result(FlutterError(code: "webview_missing", message: "The web view is gone", details: nil))
      return
    }
    let store = webView.configuration.websiteDataStore
    guard store.identifier == identifier, !store.proxyConfigurations.isEmpty else {
      result(
        FlutterError(
          code: "store_mismatch", message: "The web view uses another data store", details: nil)
      )
      return
    }
    result(nil)
  }

  @available(iOS 17.0, *)
  private func deleteDataStore(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let identifier = Self.storeIdentifier(call) else {
      result(Self.invalidStore())
      return
    }
    WKWebsiteDataStore.remove(forIdentifier: identifier) { error in
      if error == nil {
        result(nil)
      } else {
        // Usually a web view still holds it; the app retries later.
        result(FlutterError(code: "delete_failed", message: "Data store not deleted", details: nil))
      }
    }
  }
}

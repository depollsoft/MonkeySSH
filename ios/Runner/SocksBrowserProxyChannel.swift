import Flutter
import Network
import WebKit

/// Routes the in-app browser through a loopback SOCKS5 forward.
///
/// `webview_flutter` creates its web views with the default website data store
/// and exposes no proxy settings, so this sets `proxyConfigurations` on that
/// store (iOS 17+). The configuration never fails over to a direct
/// connection: when the forward drops, loads fail instead of leaving over the
/// device's own network.
@MainActor
final class SocksBrowserProxyChannel {
  private static let channelName = "xyz.depollsoft.monkeyssh/socks_browser_proxy"

  private let channel: FlutterMethodChannel

  private init(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  static func register(with registrar: FlutterPluginRegistrar) -> SocksBrowserProxyChannel {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    let handler = SocksBrowserProxyChannel(channel: channel)
    // Flutter delivers platform channel calls on the main thread.
    channel.setMethodCallHandler { call, result in
      handler.handle(call, result: result)
    }
    return handler
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      if #available(iOS 17.0, *) {
        result(true)
      } else {
        result(false)
      }
    case "apply":
      apply(call, result: result)
    case "clear":
      if #available(iOS 17.0, *) {
        WKWebsiteDataStore.default().proxyConfigurations = []
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

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
    guard #available(iOS 17.0, *) else {
      result(
        FlutterError(
          code: "unsupported",
          message: "Web view proxies need iOS 17 or later",
          details: nil
        )
      )
      return
    }
    var configuration = ProxyConfiguration(
      socksv5Proxy: .hostPort(host: .ipv4(.loopback), port: endpointPort)
    )
    configuration.allowFailover = false
    WKWebsiteDataStore.default().proxyConfigurations = [configuration]
    result(nil)
  }
}

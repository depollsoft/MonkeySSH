import AVFoundation
import CoreLocation
import Flutter
import UIKit

/// Camera, microphone and when-in-use location permissions for the
/// `xyz.depollsoft.monkeyssh/permissions` channel (`AppPermissionService` in
/// Dart).
///
/// iOS shows each prompt once, so `.denied` always reads as permanently denied:
/// only the app's Settings page can change it.
final class AppPermissionsPlugin: NSObject, FlutterPlugin, CLLocationManagerDelegate {
  private static let channelName = "xyz.depollsoft.monkeyssh/permissions"

  private enum Status: String {
    case granted
    case denied
    case permanentlyDenied
    case restricted
  }

  private var locationManager: CLLocationManager?
  /// Callers waiting on the one when-in-use prompt in flight.
  private var pendingLocationResults: [FlutterResult] = []

  /// Registers the channel on `registry` under its own plugin key.
  static func register(in registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "AppPermissionsPlugin") else {
      NSLog("Failed to configure the permissions channel.")
      return
    }
    register(with: registrar)
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(AppPermissionsPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "request":
      switch call.arguments as? String {
      case "camera":
        requestCapture(.video, usageKey: "NSCameraUsageDescription", result: result)
      case "microphone":
        requestCapture(.audio, usageKey: "NSMicrophoneUsageDescription", result: result)
      case "locationWhenInUse":
        requestLocationWhenInUse(result: result)
      default:
        result(
          FlutterError(
            code: "invalid_args",
            message: "Unknown permission",
            details: call.arguments
          )
        )
      }
    case "openAppSettings":
      openAppSettings(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Camera and microphone

  private func requestCapture(
    _ mediaType: AVMediaType,
    usageKey: String,
    result: @escaping FlutterResult
  ) {
    let status = AVCaptureDevice.authorizationStatus(for: mediaType)
    // Asking without the Info.plist purpose string terminates the app, and a
    // backgrounded app cannot show the prompt.
    guard status == .notDetermined, canPrompt(usageKey: usageKey) else {
      result(Self.status(for: status).rawValue)
      return
    }
    AVCaptureDevice.requestAccess(for: mediaType) { granted in
      DispatchQueue.main.async {
        result((granted ? Status.granted : Status.permanentlyDenied).rawValue)
      }
    }
  }

  private static func status(for status: AVAuthorizationStatus) -> Status {
    switch status {
    case .authorized:
      return .granted
    case .denied:
      return .permanentlyDenied
    case .restricted:
      return .restricted
    case .notDetermined:
      return .denied
    @unknown default:
      return .denied
    }
  }

  // MARK: - Location

  private func requestLocationWhenInUse(result: @escaping FlutterResult) {
    let manager = locationManager ?? makeLocationManager()
    let status = manager.authorizationStatus
    guard
      status == .notDetermined,
      canPrompt(usageKey: "NSLocationWhenInUseUsageDescription")
    else {
      result(Self.status(for: status).rawValue)
      return
    }
    pendingLocationResults.append(result)
    if pendingLocationResults.count == 1 {
      manager.requestWhenInUseAuthorization()
    }
  }

  private func makeLocationManager() -> CLLocationManager {
    let manager = CLLocationManager()
    manager.delegate = self
    locationManager = manager
    return manager
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    // The manager reports .notDetermined once on creation, before the prompt
    // is answered; only a decided status settles the waiting callers.
    let status = manager.authorizationStatus
    guard status != .notDetermined, !pendingLocationResults.isEmpty else {
      return
    }
    let results = pendingLocationResults
    pendingLocationResults.removeAll()
    let value = Self.status(for: status).rawValue
    for result in results {
      result(value)
    }
  }

  private static func status(for status: CLAuthorizationStatus) -> Status {
    switch status {
    case .authorizedWhenInUse, .authorizedAlways:
      return .granted
    case .denied:
      // Also reported while Location Services are off device-wide.
      return .permanentlyDenied
    case .restricted:
      return .restricted
    case .notDetermined:
      return .denied
    @unknown default:
      return .denied
    }
  }

  // MARK: - Shared

  private func canPrompt(usageKey: String) -> Bool {
    guard Bundle.main.object(forInfoDictionaryKey: usageKey) != nil else {
      NSLog("Missing %@ in Info.plist; not prompting.", usageKey)
      return false
    }
    return UIApplication.shared.applicationState != .background
  }

  private func openAppSettings(result: @escaping FlutterResult) {
    guard let url = URL(string: UIApplication.openSettingsURLString) else {
      result(false)
      return
    }
    UIApplication.shared.open(url, options: [:]) { success in
      result(success)
    }
  }
}

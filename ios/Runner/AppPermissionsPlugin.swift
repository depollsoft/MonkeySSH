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
    case approximate
    case denied
    case permanentlyDenied
    case restricted
  }

  private lazy var locationManager: CLLocationManager = {
    let manager = CLLocationManager()
    manager.delegate = self
    return manager
  }()

  private lazy var locationPrompt = LocationPromptQueue(
    decidedStatus: { [weak self] in self?.decidedLocationStatus() },
    requestAuthorization: { [weak self] in
      self?.locationManager.requestWhenInUseAuthorization()
    },
    schedule: { delay, work in
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
  )

  override init() {
    super.init()
    let center = NotificationCenter.default
    center.addObserver(
      self,
      selector: #selector(appWillResignActive),
      name: UIApplication.willResignActiveNotification,
      object: nil
    )
    center.addObserver(
      self,
      selector: #selector(appDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
  }

  /// Registers the channel on `registry` under its own plugin key. Pass the
  /// registry `GeneratedPluginRegistrant` uses: under the UIScene lifecycle the
  /// app delegate has no engine at launch and returns no registrar.
  static func register(in registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "AppPermissionsPlugin") else {
      NSLog("Failed to configure the permissions channel.")
      assertionFailure("No registrar for AppPermissionsPlugin")
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
    if let status = decidedLocationStatus() {
      result(status)
      return
    }
    guard canPrompt(usageKey: "NSLocationWhenInUseUsageDescription") else {
      result(Status.denied.rawValue)
      return
    }
    locationPrompt.enqueue { result($0) }
  }

  /// The wire status once the user has decided, or nil while undetermined.
  private func decidedLocationStatus() -> String? {
    switch locationManager.authorizationStatus {
    case .notDetermined:
      return nil
    case .authorizedWhenInUse, .authorizedAlways:
      // Reading the Wi-Fi SSID needs precise location.
      return locationManager.accuracyAuthorization == .reducedAccuracy
        ? Status.approximate.rawValue : Status.granted.rawValue
    case .denied:
      // Also reported while Location Services are off device-wide.
      return Status.permanentlyDenied.rawValue
    case .restricted:
      return Status.restricted.rawValue
    @unknown default:
      return Status.denied.rawValue
    }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    locationPrompt.authorizationDidChange()
  }

  @objc private func appWillResignActive() {
    locationPrompt.appWillResignActive()
  }

  @objc private func appDidBecomeActive() {
    locationPrompt.appDidBecomeActive()
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

/// Callers waiting on the when-in-use location prompt. Kept apart from
/// `CLLocationManager` and `UIApplication` so RunnerTests can drive it.
///
/// A decided status settles every waiting caller. The alert can also close
/// without a decision (home swipe, incoming call), and then the status stays
/// `.notDetermined` and no delegate callback arrives. The alert takes focus
/// from the app, so once the app has been active for a full second with the
/// status still undecided, the waiting callers read as denied and the next
/// request prompts again. Losing focus within that second (another system
/// alert, or iOS showing the location alert again) cancels the check.
final class LocationPromptQueue {
  typealias Reply = (String) -> Void

  /// How long after the app becomes active a decision may still arrive.
  static let decisionGrace: TimeInterval = 1

  private let decidedStatus: () -> String?
  private let requestAuthorization: () -> Void
  private let schedule: (TimeInterval, @escaping () -> Void) -> Void

  private var waiting: [Reply] = []
  /// Bumped on every prompt and every loss of focus, so a scheduled check
  /// stands down unless the app stayed active throughout.
  private var promptGeneration = 0
  /// Whether the app resigned active while callers were waiting, which the
  /// alert causes.
  private var promptTookFocus = false

  init(
    decidedStatus: @escaping () -> String?,
    requestAuthorization: @escaping () -> Void,
    schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void
  ) {
    self.decidedStatus = decidedStatus
    self.requestAuthorization = requestAuthorization
    self.schedule = schedule
  }

  var isWaiting: Bool { !waiting.isEmpty }

  /// Queues `reply` and asks for authorization. Asking again does nothing
  /// while the alert is up, and brings it back after one closed unanswered.
  func enqueue(_ reply: @escaping Reply) {
    waiting.append(reply)
    promptGeneration += 1
    requestAuthorization()
  }

  func authorizationDidChange() {
    // The manager reports .notDetermined once when it is created; only a
    // decided status settles the waiting callers.
    guard !waiting.isEmpty, let status = decidedStatus() else {
      return
    }
    settle(with: status)
  }

  func appWillResignActive() {
    if !waiting.isEmpty {
      promptTookFocus = true
      promptGeneration += 1
    }
  }

  func appDidBecomeActive() {
    guard promptTookFocus, !waiting.isEmpty else {
      return
    }
    promptTookFocus = false
    let generation = promptGeneration
    schedule(Self.decisionGrace) { [weak self] in
      guard let self, generation == self.promptGeneration, !self.waiting.isEmpty else {
        return
      }
      self.settle(with: self.decidedStatus() ?? "denied")
    }
  }

  private func settle(with status: String) {
    let replies = waiting
    waiting.removeAll()
    promptTookFocus = false
    for reply in replies {
      reply(status)
    }
  }
}

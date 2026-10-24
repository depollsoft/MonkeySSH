import Flutter
import UIKit

// The window scene's root view controller (Main.storyboard).
//
// On iPhone Duo it reports two things UIKit describes outside the engine's
// display features, over xyz.depollsoft.monkeyssh/display_features
// (PlatformDisplayFeaturesController in Dart):
// - The fold, a division reserved region of the view.
// - The vertical bar: the strip down one edge that holds the status bar and,
//   in native apps, the navigation and tab bar items.
// Both APIs exist only from the iOS 27.1 SDK on, so builds with an older SDK
// compile the reader out and report neither.
class MainFlutterViewController: FlutterViewController {
  private let displayFeaturesChannelName = "xyz.depollsoft.monkeyssh/display_features"
  private var displayFeaturesChannel: FlutterMethodChannel?
  private var reportedDisplayState: [String: Any] = [:]
  // The raw value of the hinge's latest known UIHinge.Status; nil until the
  // hinge reports one. Stored raw because a stored property cannot be gated
  // on the iOS 27.1 availability of the type.
  private var hingeStatus: Int?

  override func viewDidLoad() {
    super.viewDidLoad()
    let channel = FlutterMethodChannel(
      name: displayFeaturesChannelName,
      binaryMessenger: binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "getDisplayState", let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      let state = self.displayState()
      self.reportedDisplayState = state
      result(state)
    }
    displayFeaturesChannel = channel
    observeHinge()
  }

  // Opening, closing, and rotating the device resize the view, and the status
  // cluster grows while a Live Activity shows in it; a layout pass follows
  // each one.
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    reportDisplayStateIfChanged()
  }

  private func reportDisplayStateIfChanged() {
    let state = displayState()
    guard !(state as NSDictionary).isEqual(to: reportedDisplayState) else {
      return
    }
    reportedDisplayState = state
    displayFeaturesChannel?.invokeMethod("onDisplayStateChanged", arguments: state)
  }

  // Folding the device part way activates the division region without
  // resizing the view, so hinge changes trigger a report too.
  private func observeHinge() {
    #if canImport(UIKit, _version: 9127.0.85)
      if #available(iOS 27.1, *) {
        view.addInteraction(
          UIHingeInteraction { [weak self] _, update in
            guard let self else { return }
            self.hingeStatus = update.hinge.flatMap {
              $0.status == .unknown ? nil : $0.status.rawValue
            }
            self.reportDisplayStateIfChanged()
            // The division region can settle after the hinge update.
            DispatchQueue.main.async { [weak self] in
              self?.reportDisplayStateIfChanged()
            }
          }
        )
      }
    #endif
  }

  // Geometry is in the view's coordinate space, which matches Flutter's
  // logical pixels because the view fills the window.
  private func displayState() -> [String: Any] {
    #if canImport(UIKit, _version: 9127.0.85)
      if #available(iOS 27.1, *), isViewLoaded {
        var state: [String: Any] = ["features": folds()]
        if let verticalBar = verticalBar() {
          state["verticalBar"] = verticalBar
        }
        return state
      }
    #endif
    return ["features": [[String: Any]]()]
  }

  #if canImport(UIKit, _version: 9127.0.85)
    // Each fold, with UIKit's margins for interactive content included in its
    // frame. A fold divides content only while the device is part way open;
    // opened flat it is a crease that content may cross.
    @available(iOS 27.1, *)
    private func folds() -> [[String: Any]] {
      let partlyOpen = hingeStatus.map { $0 == UIHinge.Status.partiallyOpen.rawValue }
      return view.reservedRegions(kind: .division, options: .includeInactive).map { region in
        let halfOpened = region.isActive && (partlyOpen ?? true)
        return rectPayload(region.frame).merging(
          ["type": "fold", "state": halfOpened ? "halfOpened" : "flat"]
        ) { current, _ in current }
      }
    }

    // The column where a native app's bar items would sit: the bar region
    // UIKit lays out for a 44 pt control, which starts below the status
    // cluster (taller while a Live Activity shows) and ends above the home
    // indicator. Nil when the system shows no vertical bar.
    @available(iOS 27.1, *)
    private func verticalBar() -> [String: Any]? {
      let isRightToLeft = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
      let edge: UIRectEdge
      switch traitCollection.verticalBarEdge {
      case .leading:
        edge = isRightToLeft ? .right : .left
      case .trailing:
        edge = isRightToLeft ? .left : .right
      default:
        return nil
      }
      let safeArea = view.safeAreaInsets
      guard (edge == .right ? safeArea.right : safeArea.left) > 0 else {
        return nil
      }
      let insets = view.edgeInsets(for: .bar(onEdge: edge, extent: 44))
      let column = view.bounds.inset(by: insets)
      guard column.width > 0, column.height > 0 else {
        return nil
      }
      return rectPayload(column).merging(
        ["edge": edge == .right ? "right" : "left"]
      ) { current, _ in current }
    }
  #endif

  private func rectPayload(_ rect: CGRect) -> [String: Any] {
    [
      "left": Double(rect.minX),
      "top": Double(rect.minY),
      "width": Double(rect.width),
      "height": Double(rect.height),
    ]
  }
}

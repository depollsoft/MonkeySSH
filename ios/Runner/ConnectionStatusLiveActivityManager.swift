import ActivityKit
import Foundation

@available(iOS 16.1, *)
@MainActor
final class ConnectionStatusLiveActivityManager {
  static let shared = ConnectionStatusLiveActivityManager(reconcile: reconcileActivities)

  private var latestStatus: ConnectionStatusAttributes.ContentState?
  private var isForeground = true
  private var isDirty = false
  private(set) var reconciliationTask: Task<Void, Never>?
  private let reconcile: @MainActor (ConnectionStatusAttributes.ContentState?, Bool) async -> Void

  init(
    reconcile: @escaping @MainActor (ConnectionStatusAttributes.ContentState?, Bool) async -> Void
  ) {
    self.reconcile = reconcile
  }

  func updateStatus(
    connectionCount: Int,
    connectedCount: Int
  ) {
    latestStatus = ConnectionStatusAttributes.ContentState(
      connectionCount: connectionCount,
      connectedCount: connectedCount
    )
    refreshPresentation()
  }

  func setForegroundState(isForeground: Bool) {
    self.isForeground = isForeground
    refreshPresentation()
  }

  func stop() {
    latestStatus = nil
    refreshPresentation()
  }

  private func refreshPresentation() {
    isDirty = true
    guard reconciliationTask == nil else { return }

    reconciliationTask = Task {
      // Calls made during an ActivityKit await only change the desired state.
      // Finish that operation before reconciling the newest state.
      while isDirty {
        isDirty = false
        let status = latestStatus.flatMap { $0.connectionCount > 0 ? $0 : nil }
        await reconcile(status, isForeground)
      }
      reconciliationTask = nil
    }
  }

  private static func reconcileActivities(
    status: ConnectionStatusAttributes.ContentState?,
    canStartNewActivity: Bool
  ) async {
    guard let status else {
      for activity in Activity<ConnectionStatusAttributes>.activities {
        await activity.end(using: nil, dismissalPolicy: .immediate)
      }
      return
    }
    guard ActivityAuthorizationInfo().areActivitiesEnabled else {
      NSLog("Skipping SSH live activity because Live Activities are disabled.")
      return
    }

    if let activity = Activity<ConnectionStatusAttributes>.activities.first {
      await activity.update(using: status)
      return
    }

    guard canStartNewActivity else {
      NSLog(
        "Skipping SSH live activity request because the app is not foregrounded."
      )
      return
    }

    do {
      _ = try Activity.request(
        attributes: ConnectionStatusAttributes(),
        contentState: status,
        pushType: nil
      )
    } catch {
      NSLog("Failed to start SSH live activity: %@", error.localizedDescription)
    }
  }
}

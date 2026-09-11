import XCTest
@testable import Runner

@available(iOS 16.1, *)
@MainActor
final class RunnerTests: XCTestCase {
  func testUpdateThenStopBeforeWorkerStartsDoesNotCreateActivity() async {
    var statuses: [ConnectionStatusAttributes.ContentState?] = []
    let manager = ConnectionStatusLiveActivityManager { status, _ in
      statuses.append(status)
    }

    manager.updateStatus(connectionCount: 1, connectedCount: 1)
    manager.stop()
    await manager.reconciliationTask?.value

    XCTAssertEqual(statuses.count, 1)
    XCTAssertNil(statuses[0])
  }

  func testStopDuringUpdateEndsActivityAfterUpdateFinishes() async {
    let activity = SuspendedActivity()
    let manager = ConnectionStatusLiveActivityManager(reconcile: activity.reconcile)

    manager.updateStatus(connectionCount: 1, connectedCount: 1)
    await fulfillment(of: [activity.started], timeout: 1)
    manager.stop()
    activity.resume()
    await manager.reconciliationTask?.value

    XCTAssertEqual(activity.requests.count, 2)
    XCTAssertNil(activity.requests.last?.status)
    XCTAssertNil(activity.status)
    XCTAssertEqual(activity.maximumConcurrentOperations, 1)
  }

  func testUpdateDuringStopCreatesActivityAfterStopFinishes() async {
    let activity = SuspendedActivity()
    let manager = ConnectionStatusLiveActivityManager(reconcile: activity.reconcile)

    manager.stop()
    await fulfillment(of: [activity.started], timeout: 1)
    manager.updateStatus(connectionCount: 2, connectedCount: 1)
    activity.resume()
    await manager.reconciliationTask?.value

    XCTAssertEqual(activity.requests.count, 2)
    XCTAssertNil(activity.requests[0].status)
    XCTAssertEqual(activity.status?.connectionCount, 2)
    XCTAssertEqual(activity.status?.connectedCount, 1)
    XCTAssertEqual(activity.maximumConcurrentOperations, 1)
  }

  func testForegroundChangeDuringUpdateIsReconciled() async {
    let activity = SuspendedActivity()
    let manager = ConnectionStatusLiveActivityManager(reconcile: activity.reconcile)

    manager.updateStatus(connectionCount: 1, connectedCount: 1)
    await fulfillment(of: [activity.started], timeout: 1)
    manager.setForegroundState(isForeground: false)
    activity.resume()
    await manager.reconciliationTask?.value

    XCTAssertEqual(activity.requests.map { $0.canStartNewActivity }, [true, false])
    XCTAssertEqual(activity.status?.connectionCount, 1)
    XCTAssertEqual(activity.maximumConcurrentOperations, 1)
  }

  func testRepeatedUpdatesDuringOperationReconcileOnlyLatestStatus() async {
    let activity = SuspendedActivity()
    let manager = ConnectionStatusLiveActivityManager(reconcile: activity.reconcile)

    manager.updateStatus(connectionCount: 1, connectedCount: 1)
    await fulfillment(of: [activity.started], timeout: 1)
    manager.updateStatus(connectionCount: 2, connectedCount: 1)
    manager.updateStatus(connectionCount: 3, connectedCount: 2)
    manager.updateStatus(connectionCount: 4, connectedCount: 3)
    activity.resume()
    await manager.reconciliationTask?.value

    XCTAssertEqual(activity.requests.compactMap { $0.status?.connectionCount }, [1, 4])
    XCTAssertEqual(activity.status?.connectedCount, 3)
    XCTAssertEqual(activity.maximumConcurrentOperations, 1)

    // A clean worker must allow a later change to start reconciliation again.
    manager.updateStatus(connectionCount: 0, connectedCount: 0)
    await manager.reconciliationTask?.value
    XCTAssertEqual(activity.requests.count, 3)
    XCTAssertNil(activity.status)
  }

  func testBackgroundStateBeforeWorkerStartsPreventsCreation() async {
    let activity = SuspendedActivity()
    let manager = ConnectionStatusLiveActivityManager(reconcile: activity.reconcile)

    manager.updateStatus(connectionCount: 1, connectedCount: 1)
    manager.setForegroundState(isForeground: false)
    await fulfillment(of: [activity.started], timeout: 1)
    activity.resume()
    await manager.reconciliationTask?.value

    XCTAssertEqual(activity.requests.map { $0.canStartNewActivity }, [false])
    XCTAssertNil(activity.status)

    manager.setForegroundState(isForeground: true)
    await manager.reconciliationTask?.value
    XCTAssertEqual(activity.status?.connectionCount, 1)
  }
}

@available(iOS 16.1, *)
@MainActor
private final class SuspendedActivity {
  struct Request {
    let status: ConnectionStatusAttributes.ContentState?
    let canStartNewActivity: Bool
  }

  let started = XCTestExpectation(description: "First reconciliation suspended")
  private(set) var requests: [Request] = []
  private(set) var status: ConnectionStatusAttributes.ContentState?
  private(set) var maximumConcurrentOperations = 0
  private var concurrentOperations = 0
  private var continuation: CheckedContinuation<Void, Never>?

  func reconcile(
    status: ConnectionStatusAttributes.ContentState?,
    canStartNewActivity: Bool
  ) async {
    concurrentOperations += 1
    maximumConcurrentOperations = max(maximumConcurrentOperations, concurrentOperations)
    defer { concurrentOperations -= 1 }
    requests.append(Request(status: status, canStartNewActivity: canStartNewActivity))
    if requests.count == 1 {
      await withCheckedContinuation { continuation in
        self.continuation = continuation
        started.fulfill()
      }
    }
    if status == nil || self.status != nil || canStartNewActivity {
      self.status = status
    }
  }

  func resume() {
    continuation?.resume()
    continuation = nil
  }
}

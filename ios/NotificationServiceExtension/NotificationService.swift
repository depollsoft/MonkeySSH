import Foundation
import UserNotifications

/// Replaces the generic text of a MonkeySSH push ("Agent finished") with the
/// decrypted details ("Claude Code finished", "build-box · main").
///
/// The push carries the encrypted payload in `userInfo["p"]`; the device key
/// and host labels come from the keychain item the app shares
/// (`PushNotificationContextKeychain`). Anything missing or invalid delivers
/// the notification unchanged, and `userInfo` is never modified because the
/// app routes taps from it.
final class NotificationService: UNNotificationServiceExtension {
  private let lock = NSLock()
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var originalContent: UNNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    lock.lock()
    self.contentHandler = contentHandler
    originalContent = request.content
    lock.unlock()

    deliver(Self.decryptedContent(for: request.content) ?? request.content)
  }

  override func serviceExtensionTimeWillExpire() {
    lock.lock()
    let original = originalContent
    lock.unlock()
    if let original {
      deliver(original)
    }
  }

  /// Calls the content handler at most once.
  private func deliver(_ content: UNNotificationContent) {
    lock.lock()
    let handler = contentHandler
    contentHandler = nil
    lock.unlock()
    handler?(content)
  }

  private static func decryptedContent(
    for content: UNNotificationContent
  ) -> UNNotificationContent? {
    guard
      let payload = content.userInfo["p"] as? String,
      let accessGroup = PushNotificationContextKeychain.accessGroup(),
      let stored = PushNotificationContextKeychain.read(accessGroup: accessGroup),
      let context = PushNotificationContext(json: stored),
      let presentation = PushNotificationPresentation.make(
        payload: payload,
        context: context,
        originalBody: content.body
      ),
      let updated = content.mutableCopy() as? UNMutableNotificationContent
    else {
      return nil
    }
    updated.title = presentation.title
    updated.body = presentation.body
    updated.threadIdentifier = presentation.threadIdentifier
    return updated
  }
}

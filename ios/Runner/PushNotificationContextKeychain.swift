import Foundation
import Security

/// The keychain item the app writes and the notification service extension
/// reads: the push device key and the host labels, as JSON
/// (`PushNotificationContext`). Compiled into both targets.
///
/// It lives in the shared access group `<AppIdentifierPrefix><app bundle id>.push`,
/// which both targets list in `keychain-access-groups`. Each target names it in
/// Info.plist (`MonkeySSHPushKeychainGroup`) because the extension's own bundle
/// id differs from the app's.
enum PushNotificationContextKeychain {
  static let service = "xyz.depollsoft.monkeyssh.push"
  static let account = "notification-context-v1"
  static let accessGroupInfoKey = "MonkeySSHPushKeychainGroup"

  /// The shared access group, or nil when the build did not resolve it. An
  /// unsigned build expands `$(AppIdentifierPrefix)` to nothing, which leaves
  /// a group without the 10-character team prefix.
  static func accessGroup(in bundle: Bundle = .main) -> String? {
    guard let group = bundle.object(forInfoDictionaryKey: accessGroupInfoKey) as? String else {
      return nil
    }
    let parts = group.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    guard
      parts.count == 2,
      parts[0].count == 10,
      parts[0].unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) || ("0"..."9").contains($0) }),
      parts[1].hasSuffix(".push")
    else {
      return nil
    }
    return group
  }

  static func read(accessGroup: String) -> Data? {
    var query = itemQuery(accessGroup: accessGroup)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
      return nil
    }
    return result as? Data
  }

  /// Stores [data], replacing any earlier value.
  static func write(_ data: Data, accessGroup: String) -> OSStatus {
    let query = itemQuery(accessGroup: accessGroup)
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    guard status == errSecItemNotFound else {
      return status
    }
    return SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
  }

  /// Removes the item. Succeeds when there is none.
  static func delete(accessGroup: String) -> OSStatus {
    let status = SecItemDelete(itemQuery(accessGroup: accessGroup) as CFDictionary)
    return status == errSecItemNotFound ? errSecSuccess : status
  }

  private static func itemQuery(accessGroup: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrAccessGroup as String: accessGroup,
    ]
  }
}

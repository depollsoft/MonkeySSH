import CryptoKit
import Flutter
import Foundation
import LocalAuthentication
import Security

/// Non-exportable P-256 SSH keys held in the Secure Enclave.
///
/// The private key is created inside the Secure Enclave and stays there; the
/// app keeps only the keychain application tag (the alias) and the public
/// key. Nothing here logs key material, signatures, aliases, or signed data.
final class HardwareKeyPlugin: NSObject, FlutterPlugin {
  private static let channelName = "xyz.depollsoft.monkeyssh/hardware_keys"
  /// Every alias the app creates starts with this; nothing else is touched.
  private static let aliasPrefix = "xyz.depollsoft.monkeyssh.sshkey."

  /// A sign request from the moment the channel receives it, so a cancel
  /// that arrives while it waits in [queue] is not lost.
  private final class PendingSign {
    let context = LAContext()
    var cancelled = false
  }

  /// Serial: one Secure Enclave operation, and so one prompt, at a time.
  private let queue = DispatchQueue(
    label: "xyz.depollsoft.monkeyssh.hardware-keys",
    qos: .userInitiated
  )
  private let lock = NSLock()
  private var pendingSigns: [String: PendingSign] = [:]

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(HardwareKeyPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "getCapabilities":
      result(capabilities())
    case "generateKey":
      guard let alias = arguments["alias"] as? String, Self.isAppAlias(alias) else {
        result(Self.error("invalid_args"))
        return
      }
      let requireUserPresence = arguments["requireUserPresence"] as? Bool ?? false
      run(result) { try self.generateKey(alias: alias, requireUserPresence: requireUserPresence) }
    case "sign":
      guard
        let alias = arguments["alias"] as? String,
        Self.isAppAlias(alias),
        let data = arguments["data"] as? FlutterStandardTypedData,
        let requestId = arguments["requestId"] as? String
      else {
        result(Self.error("invalid_args"))
        return
      }
      let pending = PendingSign()
      pending.context.localizedReason =
        arguments["reason"] as? String ?? "Sign in with your SSH key"
      lock.lock()
      pendingSigns[requestId] = pending
      lock.unlock()
      run(result) {
        defer {
          self.lock.lock()
          self.pendingSigns.removeValue(forKey: requestId)
          self.lock.unlock()
        }
        return FlutterStandardTypedData(
          bytes: try self.sign(alias: alias, data: data.data, pending: pending)
        )
      }
    case "cancelSign":
      if let requestId = arguments["requestId"] as? String {
        lock.lock()
        let pending = pendingSigns[requestId]
        pending?.cancelled = true
        lock.unlock()
        // Dismisses a prompt that is showing; a queued request sees
        // `cancelled` before it can show one.
        pending?.context.invalidate()
      }
      result(nil)
    case "deleteKey":
      guard let alias = arguments["alias"] as? String, Self.isAppAlias(alias) else {
        result(Self.error("invalid_args"))
        return
      }
      run(result) {
        try self.deleteKey(alias: alias)
        return nil
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Operations

  private func capabilities() -> [String: Any] {
    #if targetEnvironment(simulator)
      return ["available": false, "reason": "simulator"]
    #else
      guard SecureEnclave.isAvailable else {
        return ["available": false, "reason": "noSecureHardware"]
      }
      // Per-use confirmation falls back to the passcode, so a passcode is
      // all it needs.
      let userPresence = LAContext().canEvaluatePolicy(
        .deviceOwnerAuthentication,
        error: nil
      )
      return [
        "available": true,
        "backing": "secureEnclave",
        "userPresenceAvailable": userPresence,
        // .userPresence accepts the passcode as well as Face ID / Touch ID.
        "userPresenceAllowsPasscode": true,
      ]
    #endif
  }

  private func generateKey(alias: String, requireUserPresence: Bool) throws -> [String: Any] {
    #if targetEnvironment(simulator)
      throw HardwareKeyError.unavailable
    #else
      guard SecureEnclave.isAvailable else { throw HardwareKeyError.unavailable }
      if requireUserPresence
        && !LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
      {
        throw HardwareKeyError.userPresenceUnavailable
      }
      var flags: SecAccessControlCreateFlags = [.privateKeyUsage]
      if requireUserPresence {
        flags.insert(.userPresence)
      }
      // ThisDeviceOnly keeps the key out of backups; after-first-unlock lets
      // a key without per-use confirmation reconnect while the screen is
      // locked, matching the app's other keychain items.
      guard
        let access = SecAccessControlCreateWithFlags(
          kCFAllocatorDefault,
          kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
          flags,
          nil
        )
      else {
        throw HardwareKeyError.failed
      }
      let attributes: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeySizeInBits as String: 256,
        kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
        kSecPrivateKeyAttrs as String: [
          kSecAttrIsPermanent as String: true,
          kSecAttrApplicationTag as String: Self.tag(alias),
          kSecAttrAccessControl as String: access,
        ],
      ]
      var error: Unmanaged<CFError>?
      guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
        throw Self.mapError(error?.takeRetainedValue())
      }
      guard
        let publicKey = SecKeyCopyPublicKey(privateKey),
        let point = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
        point.count == 65,
        point.first == 0x04
      else {
        try? deleteKey(alias: alias)
        throw HardwareKeyError.failed
      }
      return [
        "publicKey": FlutterStandardTypedData(bytes: point),
        "backing": "secureEnclave",
      ]
    #endif
  }

  private func sign(alias: String, data: Data, pending: PendingSign) throws -> Data {
    try throwIfCancelled(pending)
    let query: [String: Any] = [
      kSecClass as String: kSecClassKey,
      kSecAttrApplicationTag as String: Self.tag(alias),
      kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
      kSecReturnRef as String: true,
      kSecUseAuthenticationContext as String: pending.context,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let item else {
      throw Self.mapStatus(status)
    }
    // SecItemCopyMatching with kSecReturnRef on kSecClassKey yields a SecKey.
    let privateKey = item as! SecKey  // swiftlint:disable:this force_cast
    let algorithm = SecKeyAlgorithm.ecdsaSignatureMessageX962SHA256
    guard SecKeyIsAlgorithmSupported(privateKey, .sign, algorithm) else {
      throw HardwareKeyError.failed
    }
    try throwIfCancelled(pending)
    var error: Unmanaged<CFError>?
    guard
      let signature = SecKeyCreateSignature(
        privateKey,
        algorithm,
        data as CFData,
        &error
      ) as Data?
    else {
      throw Self.mapError(error?.takeRetainedValue())
    }
    return signature
  }

  private func throwIfCancelled(_ pending: PendingSign) throws {
    lock.lock()
    let cancelled = pending.cancelled
    lock.unlock()
    if cancelled {
      throw HardwareKeyError.cancelled
    }
  }

  private func deleteKey(alias: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassKey,
      kSecAttrApplicationTag as String: Self.tag(alias),
      kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw Self.mapStatus(status)
    }
  }

  // MARK: - Helpers

  private func run(_ result: @escaping FlutterResult, _ operation: @escaping () throws -> Any?) {
    queue.async {
      let reply: Any?
      do {
        reply = try operation()
      } catch let error as HardwareKeyError {
        reply = Self.error(error.code)
      } catch {
        reply = Self.error("failed")
      }
      DispatchQueue.main.async { result(reply) }
    }
  }

  private static func isAppAlias(_ alias: String) -> Bool {
    alias.hasPrefix(aliasPrefix) && alias.count > aliasPrefix.count
  }

  private static func tag(_ alias: String) -> Data {
    Data(alias.utf8)
  }

  /// Carries only a code: platform messages can include details that must
  /// not reach Dart logs.
  private static func error(_ code: String) -> FlutterError {
    FlutterError(code: code, message: nil, details: nil)
  }

  private static func mapStatus(_ status: OSStatus) -> HardwareKeyError {
    switch status {
    case errSecItemNotFound:
      return .keyNotFound
    case errSecUserCanceled:
      return .cancelled
    case errSecAuthFailed:
      return .authFailed
    case errSecInteractionNotAllowed:
      return .interactionRequired
    default:
      return .failed
    }
  }

  private static func mapError(_ error: CFError?) -> HardwareKeyError {
    guard let error else { return .failed }
    let nsError = error as Error as NSError
    if nsError.domain == LAErrorDomain {
      switch LAError.Code(rawValue: nsError.code) {
      case .userCancel, .appCancel, .systemCancel, .userFallback, .invalidContext:
        return .cancelled
      case .authenticationFailed, .biometryLockout:
        return .authFailed
      case .notInteractive:
        return .interactionRequired
      case .passcodeNotSet, .biometryNotEnrolled, .biometryNotAvailable:
        return .userPresenceUnavailable
      default:
        return .failed
      }
    }
    if nsError.domain == NSOSStatusErrorDomain {
      return mapStatus(OSStatus(truncatingIfNeeded: nsError.code))
    }
    return .failed
  }
}

private enum HardwareKeyError: Error {
  case cancelled
  case authFailed
  case interactionRequired
  case keyNotFound
  case userPresenceUnavailable
  case unavailable
  case failed

  var code: String {
    switch self {
    case .cancelled: return "cancelled"
    case .authFailed: return "auth_failed"
    case .interactionRequired: return "interaction_required"
    case .keyNotFound: return "key_not_found"
    case .userPresenceUnavailable: return "user_presence_unavailable"
    case .unavailable: return "unavailable"
    case .failed: return "failed"
    }
  }
}

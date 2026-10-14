import CryptoKit
import Foundation

// Decrypts a MonkeyMux push payload and builds the notification text the
// service extension shows. Foundation and CryptoKit only, so
// scripts/test_ios_push_notification_content.sh can compile it with swiftc
// against the shared vectors. The wire format is docs/push-notifications.md
// ("Payload"); the Dart app builds the same strings on Android.

/// The text a decrypted push replaces the generic notification text with.
struct PushNotificationPresentation: Equatable {
  let title: String
  let body: String
  /// The host reference, so a host's notifications group together.
  let threadIdentifier: String

  /// Opens [payload] with the device key in [context] and builds the text.
  /// Returns nil when anything fails, and the caller then delivers the
  /// notification unchanged.
  static func make(
    payload: String,
    context: PushNotificationContext,
    originalBody: String
  ) -> PushNotificationPresentation? {
    guard
      let plaintext = PushPayloadCipher.open(payload: payload, seed: context.seed),
      let event = PushPayloadEvent(plaintext: plaintext)
    else {
      return nil
    }
    return PushNotificationPresentation(
      title: PushNotificationText.title(kind: event.kind, agent: event.agent),
      body: PushNotificationText.body(
        kind: event.kind,
        hostLabel: context.hosts[event.hostRef],
        sessionId: event.sessionId,
        originalBody: originalBody
      ),
      threadIdentifier: event.hostRef
    )
  }
}

/// What the app shares with the extension through the keychain:
/// `{"v":1,"seed":"<base64url X25519 private key>","hosts":{"<hostRef>":"<label>"}}`.
struct PushNotificationContext {
  let seed: Data
  let hosts: [String: String]

  init(seed: Data, hosts: [String: String]) {
    self.seed = seed
    self.hosts = hosts
  }

  /// Parses the stored JSON. Unknown fields are ignored; anything else
  /// malformed returns nil.
  init?(json: Data) {
    guard
      let object = try? JSONSerialization.jsonObject(with: json),
      let root = object as? [String: Any],
      PushJSON.integer(root["v"]) == 1,
      let encodedSeed = root["seed"] as? String,
      let seed = PushBase64URL.decode(encodedSeed),
      seed.count == PushPayloadCipher.keyBytes
    else {
      return nil
    }
    var hosts: [String: String] = [:]
    if let entries = root["hosts"] as? [String: Any] {
      for (hostRef, label) in entries {
        if let label = label as? String {
          hosts[hostRef] = label
        }
      }
    }
    self.init(seed: seed, hosts: hosts)
  }
}

enum PushEventKind: String {
  case permission
  case input
  case finished
  case alert
  case test
}

/// A decrypted payload. Mirrors the checks of Dart's `PushEvent.tryParse`.
struct PushPayloadEvent {
  let hostRef: String
  let kind: PushEventKind
  /// The MonkeyMux session, nil when absent or blank.
  let sessionId: String?
  let agent: String?

  init?(plaintext: Data) {
    guard
      let object = try? JSONSerialization.jsonObject(with: plaintext),
      let root = object as? [String: Any],
      PushJSON.integer(root["v"]) == 1,
      let hostRef = root["hostRef"] as? String,
      !hostRef.isEmpty,
      let kindName = root["kind"] as? String,
      let kind = PushEventKind(rawValue: kindName),
      let ts = PushJSON.integer(root["ts"]),
      ts >= 0,
      ts <= 1 << 40
    else {
      return nil
    }
    self.hostRef = hostRef
    self.kind = kind
    if let session = root["sessionId"] as? String,
      !session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      sessionId = session
    } else {
      sessionId = nil
    }
    agent = root["agent"] as? String
  }
}

enum PushNotificationText {
  static let testBody = "Push notifications are working."

  private static let agentLabels: [String: String] = [
    "claude": "Claude Code",
    "codex": "Codex",
    "copilot": "Copilot",
    "opencode": "OpenCode",
    "antigravity": "Antigravity",
    "cursor-agent": "Cursor Agent",
    "pi": "Pi",
    "hermes": "Hermes",
    "openclaw": "OpenClaw",
    "grok": "Grok",
    "muse": "Muse Code",
  ]

  /// The display name for a payload's `agent`, nil for unknown agents.
  static func agentLabel(_ agent: String?) -> String? {
    agent.flatMap { agentLabels[$0] }
  }

  static func title(kind: PushEventKind, agent: String?) -> String {
    let label = agentLabel(agent)
    switch kind {
    case .permission:
      return label.map { "\($0) needs approval" } ?? "Approval needed"
    case .input:
      return label.map { "\($0) has a question" } ?? "Input needed"
    case .finished:
      return label.map { "\($0) finished" } ?? "Agent finished"
    case .alert:
      return "Terminal alert"
    case .test:
      return "MonkeySSH"
    }
  }

  /// "<host> · <session>" when the app shared a label for the host, the
  /// original generic body otherwise. A session named after its host (the
  /// default) is not repeated. Dart's `pushNotificationText` matches this.
  static func body(
    kind: PushEventKind,
    hostLabel: String?,
    sessionId: String?,
    originalBody: String
  ) -> String {
    if kind == .test {
      return testBody
    }
    let label = hostLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !label.isEmpty else {
      return originalBody
    }
    let session = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !session.isEmpty, session != label else {
      return label
    }
    return "\(label) \u{00B7} \(session)"
  }
}

/// X25519 + HKDF-SHA256 + AES-256-GCM, as docs/push-notifications.md pins it.
enum PushPayloadCipher {
  static let keyBytes = 32
  static let nonceBytes = 12
  static let tagBytes = 16
  static let info = Data("monkeyssh-push-v1".utf8)

  /// Returns the plaintext, or nil when the payload is malformed or does not
  /// authenticate under this device key.
  static func open(payload: String, seed: Data) -> Data? {
    guard
      seed.count == keyBytes,
      let sealed = PushBase64URL.decode(payload),
      sealed.count > keyBytes + nonceBytes + tagBytes
    else {
      return nil
    }
    let bytes = [UInt8](sealed)
    let ephemeralPublic = Data(bytes[0..<keyBytes])
    let nonce = Data(bytes[keyBytes..<(keyBytes + nonceBytes)])
    let ciphertext = Data(bytes[(keyBytes + nonceBytes)..<(bytes.count - tagBytes)])
    let tag = Data(bytes[(bytes.count - tagBytes)...])
    do {
      let device = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: seed)
      guard let key = payloadKey(device: device, ephemeralPublic: ephemeralPublic) else {
        return nil
      }
      let box = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: nonce),
        ciphertext: ciphertext,
        tag: tag
      )
      return try AES.GCM.open(box, using: key)
    } catch {
      return nil
    }
  }

  /// The AES key both sides derive. Nil for an all-zero shared secret (a
  /// low-order ephemeral key).
  static func payloadKey(
    device: Curve25519.KeyAgreement.PrivateKey,
    ephemeralPublic: Data
  ) -> SymmetricKey? {
    guard
      let ephemeral = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralPublic),
      let shared = try? device.sharedSecretFromKeyAgreement(with: ephemeral)
    else {
      return nil
    }
    let isZero = shared.withUnsafeBytes { raw in raw.allSatisfy { $0 == 0 } }
    if isZero {
      return nil
    }
    return shared.hkdfDerivedSymmetricKey(
      using: SHA256.self,
      salt: ephemeralPublic + device.publicKey.rawRepresentation,
      sharedInfo: info,
      outputByteCount: keyBytes
    )
  }
}

enum PushBase64URL {
  /// Decodes base64url with or without padding. Rejects the standard
  /// alphabet's `+` and `/`, whitespace and anything else.
  static func decode(_ value: String) -> Data? {
    var body = Substring(value)
    while body.hasSuffix("=") {
      body = body.dropLast()
    }
    let padding = value.count - body.count
    guard
      padding <= 2,
      padding == 0 || value.count % 4 == 0,
      body.count % 4 != 1,
      body.unicodeScalars.allSatisfy(isAlphabet)
    else {
      return nil
    }
    var standard = body
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
    return Data(base64Encoded: standard)
  }

  private static func isAlphabet(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar {
    case "A"..."Z", "a"..."z", "0"..."9", "-", "_":
      return true
    default:
      return false
    }
  }
}

enum PushJSON {
  /// A JSON integer, rejecting booleans and fractions that NSNumber would
  /// otherwise convert.
  static func integer(_ value: Any?) -> Int64? {
    guard
      let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID()
    else {
      return nil
    }
    let double = number.doubleValue
    guard double.rounded() == double, abs(double) < 9.0e15 else {
      return nil
    }
    return number.int64Value
  }
}

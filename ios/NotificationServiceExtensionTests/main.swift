import CryptoKit
import Foundation

// Command-line checks for PushNotificationPresentation.swift, run by
// scripts/test_ios_push_notification_content.sh. They prove interop with the
// Go, TypeScript and Dart suites through docs/push-notification-vectors.json,
// whose keys and nonces are SHA-256 of public labels.

var failures = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
  if !condition() {
    failures += 1
    print("FAIL (line \(line)): \(message)")
  }
}

func equal<T: Equatable>(_ actual: T, _ expected: T, _ message: String, line: Int = #line) {
  check(actual == expected, "\(message): expected \(expected), got \(actual)", line: line)
}

func fromLabel(_ label: String, _ size: Int) -> Data {
  Data(SHA256.hash(data: Data(label.utf8))).prefix(size)
}

func hexDigest<D: ContiguousBytes>(_ value: D) -> String {
  let bytes = value.withUnsafeBytes { Data($0) }
  return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

func encode(_ data: Data) -> String {
  data.base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
}

func seal(_ plaintext: String, to device: Curve25519.KeyAgreement.PublicKey) -> String {
  let ephemeral = Curve25519.KeyAgreement.PrivateKey()
  let shared = try! ephemeral.sharedSecretFromKeyAgreement(with: device)
  let key = shared.hkdfDerivedSymmetricKey(
    using: SHA256.self,
    salt: ephemeral.publicKey.rawRepresentation + device.rawRepresentation,
    sharedInfo: PushPayloadCipher.info,
    outputByteCount: 32
  )
  let box = try! AES.GCM.seal(Data(plaintext.utf8), using: key)
  return encode(ephemeral.publicKey.rawRepresentation + box.nonce + box.ciphertext + box.tag)
}

guard CommandLine.arguments.count == 2 else {
  print("usage: \(CommandLine.arguments[0]) <docs/push-notification-vectors.json>")
  exit(2)
}
let vectorsData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let vectors = try JSONSerialization.jsonObject(with: vectorsData) as! [String: Any]
let vector = vectors["payload"] as! [String: Any]
func string(_ key: String) -> String { vector[key] as! String }

let deviceSeed = fromLabel(string("deviceLabel"), 32)
let device = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: deviceSeed)
let ephemeralSeed = fromLabel(string("ephemeralLabel"), 32)
let ephemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: ephemeralSeed)
let payload = string("payload")
let plaintext = string("plaintext")

// Key derivation matches the other implementations.
equal(encode(device.publicKey.rawRepresentation), string("devicePublic"), "device public key")
equal(encode(ephemeral.publicKey.rawRepresentation), string("ephemeralPublic"), "ephemeral public key")
equal(
  hexDigest(try ephemeral.sharedSecretFromKeyAgreement(with: device.publicKey)),
  string("sharedDigest"),
  "X25519 shared secret"
)
equal(string("info"), "monkeyssh-push-v1", "HKDF info")
let derived = PushPayloadCipher.payloadKey(
  device: device,
  ephemeralPublic: ephemeral.publicKey.rawRepresentation
)!
equal(hexDigest(derived), string("derivedDigest"), "HKDF output")

// Sealing with the pinned randomness reproduces the pinned payload.
let pinnedNonce = try AES.GCM.Nonce(data: fromLabel(string("nonceLabel"), 12))
let pinnedBox = try AES.GCM.seal(Data(plaintext.utf8), using: derived, nonce: pinnedNonce)
equal(
  encode(ephemeral.publicKey.rawRepresentation + pinnedBox.nonce + pinnedBox.ciphertext + pinnedBox.tag),
  payload,
  "sealed payload"
)

// The device opens the pinned payload, padded or not.
let opened = PushPayloadCipher.open(payload: payload, seed: deviceSeed)
equal(opened.map { String(decoding: $0, as: UTF8.self) }, plaintext, "opened plaintext")
// The pinned payload's length needs no padding; one byte more plaintext does.
let unpadded = seal(plaintext + " ", to: device.publicKey)
let padded = unpadded + String(repeating: "=", count: (4 - unpadded.count % 4) % 4)
check(padded != unpadded, "test payload length needs padding")
equal(
  PushPayloadCipher.open(payload: padded, seed: deviceSeed).map { String(decoding: $0, as: UTF8.self) },
  plaintext + " ",
  "padded payload"
)

for case let rejected as [String: String] in vector["rejected"] as! [Any] {
  check(
    PushPayloadCipher.open(payload: rejected["payload"]!, seed: deviceSeed) == nil,
    "rejected payload opened: \(rejected["reason"]!)"
  )
}
let stranger = Curve25519.KeyAgreement.PrivateKey()
check(
  PushPayloadCipher.open(payload: payload, seed: stranger.rawRepresentation) == nil,
  "another device opened the payload"
)
check(PushPayloadCipher.open(payload: payload, seed: deviceSeed.prefix(31)) == nil, "short seed")
// A low-order ephemeral key gives an all-zero shared secret.
let lowOrder = Data(count: 32)
check(PushPayloadCipher.payloadKey(device: device, ephemeralPublic: lowOrder) == nil, "all-zero shared secret")
check(
  PushPayloadCipher.open(payload: encode(lowOrder + Data(count: 12 + 1 + 16)), seed: deviceSeed) == nil,
  "low-order payload"
)

// Base64url decoding.
equal(PushBase64URL.decode("YQ"), Data("a".utf8), "unpadded")
equal(PushBase64URL.decode("YQ=="), Data("a".utf8), "padded")
equal(PushBase64URL.decode("-_8"), Data([0xFB, 0xFF]), "url alphabet")
check(PushBase64URL.decode("+/8") == nil, "standard alphabet")
check(PushBase64URL.decode("YQ=") == nil, "partial padding")
check(PushBase64URL.decode("abcde") == nil, "impossible length")
check(PushBase64URL.decode("YQ ") == nil, "whitespace")
check(PushBase64URL.decode("Y===") == nil, "too much padding")

// The keychain context.
let contextJSON = """
  {"v":1,"seed":"\(encode(deviceSeed))","hosts":{"Vv2a6mQZbW3x9R1c":"build-box","x":7},"later":true}
  """
let context = PushNotificationContext(json: Data(contextJSON.utf8))!
equal(context.seed, deviceSeed, "context seed")
equal(context.hosts, ["Vv2a6mQZbW3x9R1c": "build-box"], "context hosts")
for invalid in [
  "not json",
  "[]",
  #"{"v":2,"seed":"\#(encode(deviceSeed))","hosts":{}}"#,
  #"{"v":true,"seed":"\#(encode(deviceSeed))","hosts":{}}"#,
  #"{"v":1,"seed":"\#(encode(deviceSeed.prefix(31)))","hosts":{}}"#,
  #"{"v":1,"seed":"not+base64url","hosts":{}}"#,
  #"{"v":1,"hosts":{}}"#,
] {
  check(PushNotificationContext(json: Data(invalid.utf8)) == nil, "context accepted: \(invalid)")
}
equal(
  PushNotificationContext(json: Data(#"{"v":1,"seed":"\#(encode(deviceSeed))"}"#.utf8))?.hosts,
  [:],
  "context without hosts"
)

// A session named after its host (the default) is not repeated, and labels
// are trimmed, exactly as Dart's pushNotificationText does.
equal(
  PushNotificationText.body(
    kind: .finished, hostLabel: "build-box", sessionId: "build-box", originalBody: "generic"),
  "build-box",
  "session named after its host"
)
equal(
  PushNotificationText.body(
    kind: .finished, hostLabel: " build-box ", sessionId: " main ", originalBody: "generic"),
  "build-box \u{00B7} main",
  "trimmed label and session"
)
equal(
  PushNotificationText.body(kind: .finished, hostLabel: "  ", sessionId: "main", originalBody: "generic"),
  "generic",
  "blank label"
)

// The window's title leads, as in Dart's pushNotificationText.
equal(
  PushNotificationText.body(
    kind: .finished, hostLabel: "build-box", sessionId: "main", windowTitle: "Fix login bug",
    originalBody: "generic"),
  "Fix login bug \u{00B7} build-box \u{00B7} main",
  "window title, host and session"
)
equal(
  PushNotificationText.body(
    kind: .finished, hostLabel: "build-box", sessionId: "build-box",
    windowTitle: "Fix login bug", originalBody: "generic"),
  "Fix login bug \u{00B7} build-box",
  "window title with the default session"
)
equal(
  PushNotificationText.body(
    kind: .finished, hostLabel: nil, sessionId: "main", windowTitle: "Fix login bug",
    originalBody: "generic"),
  "Fix login bug",
  "window title on an unknown host"
)
equal(
  PushNotificationText.body(
    kind: .finished, hostLabel: "build-box", sessionId: nil, windowTitle: "build-box",
    originalBody: "generic"),
  "build-box",
  "window title equal to the label"
)
equal(PushPayloadEvent.cleanTitle(" deploy\n\u{1B} prod "), "deploy prod", "title cleaned")
check(PushPayloadEvent.cleanTitle("  ") == nil, "blank title kept")
check(PushPayloadEvent.cleanTitle(String(repeating: "a", count: 65)) == nil, "long title kept")
equal(PushPayloadEvent.cleanTitle(String(repeating: "a", count: 64)), String(repeating: "a", count: 64), "64-character title")

// The pinned vector, end to end.
equal(
  PushNotificationPresentation.make(payload: payload, context: context, originalBody: "generic"),
  PushNotificationPresentation(
    title: "Approval needed",
    body: "build-box \u{00B7} main",
    threadIdentifier: "Vv2a6mQZbW3x9R1c"
  ),
  "pinned vector presentation"
)
check(
  PushNotificationPresentation.make(payload: unpadded, context: context, originalBody: "")
    == PushNotificationPresentation.make(payload: padded, context: context, originalBody: ""),
  "padding changes the presentation"
)
check(
  PushNotificationPresentation.make(
    payload: (vector["rejected"] as! [[String: String]])[0]["payload"]!,
    context: context,
    originalBody: "generic"
  ) == nil,
  "tampered payload presented"
)

func present(_ json: String, hosts: [String: String] = ["h": "Box"]) -> PushNotificationPresentation? {
  PushNotificationPresentation.make(
    payload: seal(json, to: device.publicKey),
    context: PushNotificationContext(seed: deviceSeed, hosts: hosts),
    originalBody: "An agent finished its turn."
  )
}

let titles: [(kind: String, agent: String?, title: String)] = [
  ("permission", "claude", "Claude Code needs approval"),
  ("permission", nil, "Approval needed"),
  ("input", "codex", "Codex has a question"),
  ("input", nil, "Input needed"),
  ("finished", "copilot", "Copilot finished"),
  ("finished", "opencode", "OpenCode finished"),
  ("finished", "antigravity", "Antigravity finished"),
  ("finished", "cursor-agent", "Cursor Agent finished"),
  ("finished", "pi", "Pi finished"),
  ("finished", "hermes", "Hermes finished"),
  ("finished", "openclaw", "OpenClaw finished"),
  ("finished", "grok", "Grok finished"),
  ("finished", "muse", "Muse Code finished"),
  ("finished", "someone-else", "Agent finished"),
  ("finished", "Claude", "Agent finished"),
  ("finished", nil, "Agent finished"),
  ("alert", "claude", "Terminal alert"),
  ("test", "claude", "MonkeySSH"),
]
for entry in titles {
  let agent = entry.agent.map { #","agent":"\#($0)""# } ?? ""
  let json = #"{"v":1,"hostRef":"h","window":"@1","sessionId":"dev","kind":"\#(entry.kind)","ts":1\#(agent)}"#
  equal(present(json)?.title, entry.title, "title for \(entry.kind)/\(entry.agent ?? "-")")
}

equal(
  present(#"{"v":1,"hostRef":"h","sessionId":"dev","kind":"finished","ts":1,"alert":["bell"]}"#),
  PushNotificationPresentation(title: "Agent finished", body: "Box \u{00B7} dev", threadIdentifier: "h"),
  "known host"
)
equal(
  present(#"{"v":1,"hostRef":"h","sessionId":"","kind":"input","ts":1}"#)?.body,
  "Box",
  "empty session"
)
equal(present(#"{"v":1,"hostRef":"h","sessionId":"  ","kind":"input","ts":1}"#)?.body, "Box", "blank session")
equal(present(#"{"v":1,"hostRef":"h","kind":"input","ts":1}"#)?.body, "Box", "missing session")
equal(
  present(#"{"v":1,"hostRef":"other","sessionId":"dev","kind":"finished","ts":1}"#),
  PushNotificationPresentation(
    title: "Agent finished",
    body: "An agent finished its turn.",
    threadIdentifier: "other"
  ),
  "unknown host keeps the original body"
)
equal(
  present(#"{"v":1,"hostRef":"h","sessionId":"dev","kind":"finished","ts":1}"#, hosts: ["h": ""])?.body,
  "An agent finished its turn.",
  "empty label keeps the original body"
)
equal(
  present(#"{"v":1,"hostRef":"h","window":"","sessionId":"","kind":"test","ts":1}"#, hosts: [:]),
  PushNotificationPresentation(
    title: "MonkeySSH",
    body: "Push notifications are working.",
    threadIdentifier: "h"
  ),
  "test push"
)
for malformed in [
  #"{"v":2,"hostRef":"h","kind":"alert","ts":1}"#,
  #"{"v":1,"kind":"alert","ts":1}"#,
  #"{"v":1,"hostRef":"","kind":"alert","ts":1}"#,
  #"{"v":1,"hostRef":"h","kind":"gossip","ts":1}"#,
  #"{"v":1,"hostRef":"h","kind":"alert"}"#,
  #"{"v":1,"hostRef":"h","kind":"alert","ts":true}"#,
  #"{"v":1,"hostRef":"h","kind":"alert","ts":1.5}"#,
  #"{"v":1,"hostRef":"h","kind":"alert","ts":-1}"#,
  #"{"v":1,"hostRef":"h","kind":"alert","ts":1099511627777}"#,
  #"["v",1]"#,
  "not json",
] {
  check(present(malformed) == nil, "malformed payload presented: \(malformed)")
}

if failures > 0 {
  print("\(failures) check(s) failed")
  exit(1)
}
print("Push notification presentation: all checks passed")

# Push notifications for agent events

This is the wire specification for issue #948. When an agent needs the user and
the app is suspended or closed, the host sends an encrypted, content-free event
to a Firebase Function, which delivers it through Firebase Cloud Messaging
(FCM). FCM uses APNs on iOS.

Three components implement it:

| Component | Code | Role |
| --- | --- | --- |
| App | `lib/domain/services/push/` | Opt-in, device key, registration, tap routing |
| Function | `functions/src/` | Issues tickets, opens them, rate limits, sends FCM |
| MonkeyMux | `remote/monkeymux/push_*.go` | Stores registrations, detects events, encrypts, posts |

`docs/push-notification-vectors.json` pins the ticket and payload formats. The
Go, TypeScript and Dart suites all read it, so a change to either format has to
update the file and all three suites together. The file holds no key material:
each suite derives the keys and nonces as SHA-256 of the public labels in the
file, and intermediate secrets are checked by their SHA-256 digests.

## What each party can read

| Party | Sees |
| --- | --- |
| MonkeyMux host | Device id, sealed ticket, device public key, host reference, and whether the app is watching, alive in the background, or neither |
| Function, Google, Apple | Sealed ticket and the FCM token inside it, host IP address, timing, coarse event kind, collapse key, encrypted payload |
| App (device key holder) | Everything in the payload |

The payload never contains prompts, terminal output, file paths, commands,
window names or hostnames. The coarse kind is sent in clear text so the
notification can say something useful without a notification service
extension.

## Encodings

All binary values are base64url without padding (RFC 4648 section 5). Decoders
reject padding, `+`, `/`, whitespace and non-canonical spellings (unused
trailing bits must be zero), so each byte string has exactly one encoding. The
vectors include a non-canonical ticket that every implementation must refuse.

## Identifiers

- **Device id.** 16 random bytes, base64url (22 characters). The function
  assigns it on the first registration. The app sends it back on later
  registrations so it stays stable across token refreshes. Accepted pattern:
  `^[A-Za-z0-9_-]{16,64}$`.
- **Host reference.** Opaque to the host and the function. The app derives it as
  the first 16 characters of `base64url(HMAC-SHA256(hostRefKey, "host:" + hostId))`,
  where `hostRefKey` is 32 random bytes kept in secure storage. Opting out deletes
  the key, so references issued before cannot be resolved again. Accepted
  pattern: `^[A-Za-z0-9_-]{1,64}$`.
- **Collapse key.** Chosen by the host so repeated events for one window replace
  each other on the device: the first 32 hex characters of
  `HMAC-SHA256(hostSalt, deviceId + "\n" + session + "\n" + window)`, where
  `hostSalt` is 32 random bytes kept in the host's registration file. Accepted
  pattern: `^[A-Za-z0-9_-]{1,64}$`.

## Ticket

The function issues a ticket so the host can address a device without ever
seeing its FCM token, and so the function needs no database.

```
ticket    = "v1." keyId "." base64url(nonce || ciphertext || tag)
keyId     = 1*32( ALPHA / DIGIT / "_" / "-" )
nonce     = 12 random bytes
aad       = "v1." keyId            ; ASCII
key       = 32 bytes from the PUSH_TICKET_KEYS secret, selected by keyId
plaintext = JSON {"t": fcmToken, "d": deviceId, "i": issuedAtSeconds, "p": "ios" | "android"}
```

AES-256-GCM with a 16-byte tag. Binding the key id into the AAD means a ticket
cannot be replayed under a different key id. `p` is optional and only used for
platform-specific message fields and the `platform` log field.

A ticket stops opening 90 days after `i`, or when `i` is more than a day in the
future. The app renews its ticket at least weekly, and hosts receive the new one
on their next attach, so only a host nobody has attached to for 90 days loses
its registration.

`PUSH_TICKET_KEYS` is a Secret Manager secret read through `defineSecret`:

```json
{"current": "k2", "keys": {"k1": "<base64url 32 bytes>", "k2": "<base64url 32 bytes>"}}
```

New tickets use `current`. Any listed key id opens a ticket, which allows a
rotation period. Removing a key id revokes every ticket issued under it.

Rotation: add the new key and make it `current`, wait at least 37 days, then
remove the old key. The app renews its ticket at most a week after the key
change, but a host only receives the new ticket on its next attach, and a host
that is not refreshed expires after 30 days anyway (7 + 30). Remove a key at
once only if it is compromised. A host still holding a ticket
under the removed key gets 401, remembers the ticket as refused, and tells the
app on its next attach (see `push_register`); the app then fetches a fresh
ticket. Nothing stays broken until the user toggles push.

## Payload

The host encrypts the event to the device's X25519 public key.

```
ephemeral          = new X25519 key pair (one per message)
shared             = X25519(ephemeral.private, devicePublic)      ; reject all-zero
key                = HKDF-SHA256(ikm = shared,
                                 salt = ephemeral.public || devicePublic,
                                 info = "monkeyssh-push-v1", length = 32)
nonce              = 12 random bytes
payload            = base64url(ephemeral.public || nonce || ciphertext || tag)
```

AES-256-GCM with empty AAD and a 16-byte tag. The plaintext is UTF-8 JSON:

```json
{"v": 1, "hostRef": "Vv2a6mQZbW3x9R1c", "window": "@3", "sessionId": "main", "kind": "permission", "ts": 1760000000}
```

| Field | Meaning |
| --- | --- |
| `v` | Payload version, `1` |
| `hostRef` | The host reference the app registered on this host |
| `window` | MonkeyMux window id such as `@3`, empty for a test |
| `sessionId` | MonkeyMux session name that owns the window, empty for a test |
| `kind` | One of the kinds below |
| `ts` | Event time, Unix seconds |

Decoders ignore unknown fields. The app trusts the decrypted `kind` over the
clear-text one.

## Kinds

| Kind | Host signal | Visible text | Priority |
| --- | --- | --- | --- |
| `permission` | A native agent asked for permission (`session/request_permission`) and the request is still pending | "Approval needed" / "An agent is waiting for your approval." | high |
| `input` | A native agent asked for input (`elicitation/create`) and the request is still pending | "Input needed" / "An agent is waiting for your answer." | high |
| `finished` | A native `session/prompt` turn ended | "Agent finished" / "An agent finished its turn." | normal |
| `alert` | A bell, an OSC 9 text notification, an OSC 777 `notify`, or an OSC 99 notification (not a `p=?` query or `p=close`) in a window. Shell-integration OSC 777 marks such as `precmd` do not count | "Terminal alert" / "A terminal window wants your attention." | normal |
| `test` | `push_test` from the app | "MonkeySSH" / "Push notifications are working." | high |

All signals are generic. There are no per-agent detectors.

## Function API

Region `us-central1`, project `monkeyssh`.

### `registerPushDevice` (callable)

`onCall` with `enforceAppCheck: true` and `consumeAppCheckToken: true`. The app
sends a limited-use App Check token, which the function consumes. The
framework only marks a replayed token (`request.app.alreadyConsumed`), so the
handler rejects it itself: a captured token cannot mint a second ticket. No
Firebase Auth user is required.

Request data:

```json
{"token": "<FCM registration token>", "platform": "ios", "deviceId": "<optional existing id>"}
```

Response data:

```json
{"deviceId": "pX7cQe2LrV0sNw4yJk9aTg", "ticket": "v1.k1...."}
```

Errors use the callable error codes: `invalid-argument` for a bad request,
`unauthenticated` when the App Check token is missing, invalid or already used,
and `internal` when the ticket keys are not configured.

### `pushNotify` (HTTPS)

`POST` only, `Content-Type: application/json`, no `Content-Encoding`, body at
most 4096 bytes. The ticket travels in the body, never in the URL.

```json
{"ticket": "v1.k1....", "kind": "permission", "collapse": "9f2c...", "payload": "<base64url>"}
```

The payload must decode to at least 61 bytes (32 + 12 + 16 + 1) and the field
is capped at 3072 characters.

| Status | Body | Meaning | Host action |
| --- | --- | --- | --- |
| 202 | `{"status":"sent"}` | Accepted by FCM | none |
| 400 | `{"error":"malformed"}` | Bad JSON, kind, collapse key or payload | drop the event |
| 401 | `{"error":"bad_ticket"}` | Ticket does not open: forged, altered, revoked key, or expired | delete the registration and remember the ticket as refused |
| 405 | `{"error":"method"}` | Not a POST | drop the event |
| 410 | `{"error":"unregistered"}` | FCM says the token is gone (`registration-token-not-registered`, `invalid-registration-token`, `installation-id-not-registered`) | delete the registration and remember the ticket as refused |
| 413 | `{"error":"too_large"}` | Body over 4096 bytes | drop the event |
| 415 | `{"error":"encoding"}` | A `Content-Encoding` other than `identity` | drop the event |
| 429 | `{"error":"rate_limited"}` | Over the rate limit; `Retry-After` in seconds | back off that device's budget |
| 5xx | `{"error":"unavailable"}` | FCM or the function failed, including project-side errors such as a missing APNs key or IAM permission | retry twice with backoff, then drop |

The host treats any other 4xx like 400. Project-side FCM errors
(`mismatched-credential`, `third-party-auth-error`, `authentication-error`)
answer 503 and are logged at error level with their FCM code, so a
misconfigured project never makes hosts delete registrations.

**Compressed bodies.** The Functions Framework buffers, inflates and parses a
request before the handler sees it, so a small `Content-Encoding: gzip` body
can expand far past 4 KB before the 415 is returned. `pushNotify` therefore
runs one request per instance (`concurrency: 1`) with 512 MiB and a 15-second
timeout, so such a request can only take down its own instance, and
`maxInstances` bounds the cost. The remaining exposure is availability: a
sustained stream of such requests can keep instances restarting. Putting the
function behind a load balancer with a Cloud Armor rule that rejects
`Content-Encoding`, or moving it to a plain Cloud Run service that checks the
header before reading the body, would close it.

### Rate limits and cost

- In-memory token buckets keyed by a hash of the FCM token and split three
  ways: `permission` and `input`; `finished` and `alert`; and `test`. Each is
  burst 5, refilled at 30 per hour. Routine events and test taps can never use
  up the allowance approval requests need. A send that FCM could not take
  (5xx) refunds its token, so retries are free. Each function instance keeps
  its own buckets, so the real ceiling is that limit times the instance count.
- `maxInstances` in the global options is the hard bound on cost and abuse.
- The owner's Blaze spending cap is the outer bound. A Cloud Billing budget only
  alerts; it does not stop spending, so `maxInstances` is the actual limit.

### FCM message

```json
{
  "token": "<from the ticket>",
  "notification": {"title": "Approval needed", "body": "An agent is waiting for your approval."},
  "data": {"v": "1", "p": "<payload>"},
  "android": {
    "priority": "high",
    "collapseKey": "<collapse>",
    "ttl": "3600s",
    "notification": {"channelId": "agent-attention", "tag": "<collapse>", "icon": "ic_notification_monkey"}
  },
  "apns": {
    "headers": {"apns-priority": "10", "apns-push-type": "alert", "apns-collapse-id": "<collapse>", "apns-expiration": "<now + 3600>"},
    "payload": {"aps": {"mutable-content": 1, "sound": "default", "thread-id": "monkeyssh-agents"}}
  }
}
```

Normal-priority kinds use `"priority": "normal"`, `apns-priority: 5`, no
sound, and the quiet Android channel `agent-updates` (on Android 8 and later
the channel, not the message priority, decides sound and heads-up display). `mutable-content` lets a later notification service extension replace
the text with decrypted details (see Follow-ups).

### Logging

Structured outcome codes only: `outcome`, `kind`, `platform`, and for FCM
failures `fcmCode`, a fixed enum such as `third-party-auth-error` (anything
outside `[a-z0-9-]` is logged as `unknown`). Tickets, tokens, device ids,
collapse keys and payloads are never logged.

Cloud Run request logs record the caller's IP address and are kept for the
`_Default` bucket's 30 days, which is what the privacy policy states. The
owner can go further and stop storing them with a Cloud Logging exclusion:

```sh
gcloud logging sinks update _Default --project=monkeyssh \
  --add-exclusion='name=push-request-logs,filter=resource.type="cloud_run_revision" AND resource.labels.service_name=("pushnotify" OR "registerpushdevice") AND log_id("run.googleapis.com/requests")'
```

The function's own outcome logs carry no IP address and keep the default 30-day
retention.

## MonkeyMux

### Control operations

The helper advertises the `push-v1` capability. Push fields travel in a nested
`push` object on the control message.

```json
{"id": "1", "type": "push_register",   "push": {"deviceId": "...", "ticket": "v1....", "publicKey": "<32 bytes>", "hostRef": "..."}}
{"id": "2", "type": "push_unregister", "push": {"deviceId": "...", "hostRef": "<optional>"}}
{"id": "3", "type": "push_presence",   "clientId": "<attach client id>", "push": {"deviceId": "...", "foreground": false, "local": true, "alerts": true, "bridges": ["<bridge id>"]}}
{"id": "4", "type": "push_test",       "push": {"deviceId": "..."}}
```

- `push_register` answers `push_registered` with `{"push": {"result":
  "registered"}}`. If the function already refused that exact ticket, it answers
  `push_register_rejected` with result `stale_ticket` (after a 401) or
  `token_unregistered` (after a 410) and stores nothing. The app then fetches a
  new ticket, and for `token_unregistered` a new FCM token first.
- `push_unregister` with a `hostRef` removes that one saved host's
  registration; without one it removes every registration of the device. It
  answers `push_unregistered`.
- `push_presence` answers `push_presence_ack`.
- `push_test` answers `push_test_result` with `{"push": {"result":
  "<result>"}}`: `sent`, `not_registered`, `bad_ticket`, `unregistered`,
  `rate_limited`, `capped` or `failed`. A test is sent once, without retries,
  because the app waits for the answer.

### Storage

`~/.monkeyssh/state/push-devices.json`, mode 0600 in a 0700 directory, written
through a temporary file and a rename. Every MonkeyMux server for the user
shares it, so each read and each read-modify-write holds an exclusive lock on
`push-devices.json.lock` (`flock` on POSIX, `LockFileEx` on Windows); without it
two servers could both read, change and rename, and one change would be lost.

- A registration is a device as reached through one saved host:
  `(deviceId, hostRef)`. Two saved hosts that reach the same machine user (LAN
  and Tailscale, say) register separately and can be turned off separately; an
  event still goes to each device once, through its most recently updated
  registration.
- Caps: 8 devices and 4 saved hosts per device; the least recently updated is
  evicted.
- A registration the app has not refreshed for 30 days expires. The app
  re-registers on every attach, so this only drops hosts the user deleted or
  stopped using.
- Up to 32 refused tickets are remembered for 30 days (`deviceId`, a hash of
  the ticket, and why), so a fresh attach that offers one is told to replace it.
- A file written by a newer schema version is never overwritten.

### Attendance

The app reports presence for each MonkeyMux connection: its device id, the
connection's attach client id, and one of three states.

- **Viewing** (`foreground: true`): the app is in the foreground with this
  connection's terminal on screen. Repeated every 20 seconds.
- **Local** (`local: true`): the app is alive in the background with this
  attach under Android's background service, and raises some notifications
  itself. `alerts` says this connection's window bar is mounted, so the app
  raises its window alerts; `bridges` lists the native agent bridges whose
  events it is receiving. Repeated every 20 seconds. iOS suspends a
  backgrounded app, so iOS reports idle instead.
- **Idle**: neither. Sent once.

A report counts while it is under 45 seconds old and the attach client is still
attached. A device **attends** window W when it is viewing and W is the active
window, or when a report in the last 30 seconds saw it viewing W. A device is
**covered locally** for window alerts when its last local report said
`alerts`, and for a native agent event when that report listed the event's
bridge. A local claim lapses 25 seconds after it was made (one heartbeat plus
slack), so a suspended or killed app stops covering anything within that time.
A one-off event (`finished`, `alert`) skipped only because of local coverage
is kept for 2 minutes and sent if the coverage lapses first.

- `permission`, `input` and `finished` skip the devices that attend the window
  or are covered locally.
- `alert` is skipped for every device when any device attends the window, and
  for devices covered locally.
- A desktop `monkeymux attach` never reports presence, so it never suppresses a
  phone.

### Coalescing, caps and retries

- One event per device, window and kind in any 30-second window.
- Three budgets per device, each at most 20 events an hour: urgent
  (`permission`, `input`), routine (`finished`, `alert`) and `test`. They are
  kept by each MonkeyMux server, and every session has its own server, so a
  device attached to several sessions gets a budget per session. The
  function's per-token buckets bound the total across sessions and hosts.
- A 429 suspends that device's budget for `Retry-After` seconds (60 if absent,
  at most an hour); the other budget keeps sending.
- A 5xx or network error is retried twice, after 1 and 3 seconds, then dropped;
  a still-pending request is raised again later, as it is after a 401 or 410
  once the app registers a fresh ticket. Any other 4xx (400, 413, 415) is final
  and is not raised again.
- Requests time out after 10 seconds.
- 401 and 410 delete the registrations carrying that ticket and remember it as
  refused.
- The PTY reader never waits on any of this: a bell or desktop notification is
  queued (64 deep, dropped when full, and only while a device is registered)
  for the notifier goroutine.

### Native agent signals

The ACP bridge reports monotonic counters of permission requests, input
requests and completed prompt turns, plus how many permission and input
requests are pending right now. While at least one device is registered, each
server polls the bridges behind its native agent windows every 2 seconds.

- `finished` is raised when the completed-turn counter grows.
- `permission` and `input` are raised while a request of that kind is pending,
  to each device that has not yet been sent that request (the counter value is
  the request's generation). A device that was watching, covered locally,
  backed off, capped or coalesced is not marked, so a still-pending request is
  raised as soon as that stops being true: after the 30-second grace when the
  user locks the phone, after a backoff ends, or when the app's background
  heartbeat stops. A delivery that fails is unmarked and retried the same way.
- The server records each delivery in the bridge itself
  (`{"type":"command","command":"push_delivered","data":{"deviceId","kind","generation"}}`,
  at most 128 entries) and the bridge reports them in `pushDelivered`. Bridges
  outlive a server across an upgrade, so its successor does not push the same
  request again.
- A bridge that restarts resets the turn baseline without an event and forgets
  which requests were delivered. A failed status read keeps the baseline.
- A bridge preserved from an earlier build of this branch reports a combined
  `pendingAttentionCount`; then any kind it has ever asked for counts as
  possibly pending. Bridges from helpers before 0.1.228 report no counters, so
  agents started before the upgrade raise no pushes until they are restarted.

Polling works the same whether the bridge lives in this server, in the outgoing
server after an upgrade, or in a detached `acp serve` process.

The endpoint is `https://us-central1-monkeyssh.cloudfunctions.net/pushNotify`.
`MONKEYMUX_PUSH_ENDPOINT` in the server's environment overrides it for testing.

## App

- The feature exists only when the build sets `FLUTTY_FIREBASE_ENABLED=true` and
  runs on iOS or Android. Elsewhere the settings section is hidden.
- FCM auto-init is off in `Info.plist` and `AndroidManifest.xml`, and App Check
  token auto-refresh is off in `Info.plist` (`FirebaseAppCheckTokenAutoRefreshEnabled`),
  because the App Check plugin installs its provider at launch. The app asks for
  an FCM token only after the user opts in, then turns auto-init on so the
  token refreshes; opting out turns it off again. A user who never opts in
  never contacts FCM or App Check. `test/app/push_native_config_test.dart` pins
  these keys.
- **Opt in:** request notification permission, activate App Check, get the FCM
  token, create the X25519 key pair and the host reference key in secure
  storage, call `registerPushDevice` with a limited-use App Check token, and
  store the device id, the ticket and when it was issued.
- **Attach:** for each live MonkeyMux connection whose host has push enabled,
  send `push_register` once per connection, then presence (see Attendance).
  The viewed connection comes from the route's `connectionId`. When that id
  matches no live connection (the terminal reconnected) or is absent, a host
  with a single MonkeyMux connection is unambiguous and two are treated as not
  viewed.
- **Renewal:** at every start and resume the app compares the current FCM token
  with the one its ticket seals (Android does not redeliver a token that
  rotated while the app was not running) and renews the ticket when it changed,
  when it is a week old, or when a host reports it refused. Each renewal spends
  an App Check attestation, so a failed renewal is retried from later syncs
  after 1 minute, then 2, 4 and so on up to an hour. A ticket a host refused is
  not offered again. After `token_unregistered` the app must delete the dead
  token before fetching another; until that succeeds it keeps retrying rather
  than sealing the dead token again.
- **Opt out:** wait for any sync in flight, send `push_unregister` to reachable
  hosts and remember the rest for their next attach (deleted saved hosts are
  dropped from that list), turn auto-init off, delete the FCM token, and delete
  the device key, the host reference key, the device id and the ticket.
  Payloads from hosts that could not be reached can no longer be decrypted.
  The opt-out is saved before any of this starts, so an app killed half-way
  finishes it at its next start (hosts that held the registration are
  unregistered on their next attach). Turning auto-init off and deleting the
  token are retried separately from later syncs and across restarts until
  each succeeds, serialized with opt-in. A token deletion is only scheduled
  once FCM has issued a token (iOS cannot delete one before its first
  check-in), and a new opt-in cancels pending retries.
- **Per host:** turning a saved host off takes effect for a sync already
  running, waits for it, then sends `push_unregister` with that host's
  reference now, or on its next attach if it is not connected. Deleting a saved
  host leaves its registration on the machine until it expires (30 days without
  a refresh).
- **Tap:** decrypt `p`, map `hostRef` back to a host by recomputing the HMAC for
  each saved host, and open `/terminal/<hostId>` at that MonkeyMux session and
  window, reconnecting if needed. A native agent window opens its chat. A
  payload that does not decrypt opens the app on Connections.
- **Foreground:** iOS presents nothing while the app is open (the AppDelegate
  answers `willPresent` with no options, as before the app had a notification
  delegate, and runs each completion handler once). `onMessage` drops the push
  when the terminal on screen shows that window, or when it is an `alert` from
  the session on screen, whose window bar raises its own alert. Anything else
  shows a snackbar with an Open action.
- **Android channels:** "Agent attention" (`agent-attention`, high importance)
  for approvals and questions, and "Agent updates" (`agent-updates`, low
  importance, no sound) for finished turns and window alerts.

## Follow-ups

- A notification service extension that shows decrypted text such as "Claude
  needs approval on build-box". It needs the App Group and keychain access group
  work in #947.
- Live Activity push updates for #922.
- A CI job that runs `npm test` in `functions/`, and a deploy job.

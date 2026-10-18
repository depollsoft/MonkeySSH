# Push notifications for agent events

This is the wire specification for issue #948. When an agent needs the user and
the app is suspended or closed, the host sends an encrypted event to a
Firebase Function, which delivers it through Firebase Cloud Messaging
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
| Function, Google, Apple | Sealed ticket and the Firebase Installation ID (or, from older app builds, FCM token) inside it, host IP address, timing, coarse event kind, collapse key, encrypted payload |
| App (device key holder) | Everything in the payload |

Besides opaque ids, the payload names the session and, when known, the
agent's short command name and the window's title as the window bar shows it.
The title is whatever the agent, the program or the user named the window (an
agent's summary of its task, a window name, a folder's name), so it can say
what the window is working on; MonkeyMux leaves out titles that are only a
path, a host name or a shell's `user@host`. The payload never contains
prompts, the agent's messages, terminal output or full paths, and only the
device can read it. The coarse kind is sent in clear text so a phone that
cannot open the payload can still say something useful. The phone adds the
host's label itself, from its own saved hosts.

## Encodings

All binary values are base64url without padding (RFC 4648 section 5). Decoders
reject padding, `+`, `/`, whitespace and non-canonical spellings (unused
trailing bits must be zero), so each byte string has exactly one encoding. The
vectors include a non-canonical ticket that every implementation must refuse.

## Identifiers

- **Device id.** 16 random bytes, base64url (22 characters). The function
  assigns it on the first registration. The app sends it back on later
  registrations so it stays stable when the FID changes. Accepted pattern:
  `^[A-Za-z0-9_-]{16,64}$`.
- **Host reference.** Opaque to the host and the function. The app derives it as
  the first 16 characters of `base64url(HMAC-SHA256(hostRefKey, "host:" + hostId))`,
  where `hostRefKey` is 32 random bytes kept in secure storage. Opting out deletes
  the key, so references issued before cannot be resolved again. Accepted
  pattern: `^[A-Za-z0-9_-]{1,64}$`.
- **Collapse key.** Chosen by the host so repeated events for one window replace
  each other on the device: the first 32 hex characters of
  `HMAC-SHA256(hostSalt, deviceId + "\n" + session + "\n" + window + "\n" + group)`,
  where `group` is `attention` for `permission` and `input` and `update` for
  every other kind (since 0.1.237), so a routine event never replaces a request
  still waiting on the user, and `hostSalt` is 32 random bytes kept in the
  host's registration file. Accepted
  pattern: `^[A-Za-z0-9_-]{1,64}$`.
- **Session key.** Names a MonkeyMux session in the host's registration file
  without writing the name there: the first 32 hex characters of
  `HMAC-SHA256(hostSalt, "session\n" + session)`. The server that receives
  `push_register` computes it from its own session name; the app never sends
  one.

## Ticket

The function issues a ticket so the host can address a device without ever
seeing its FCM registration, and so the function needs no database.

```
ticket    = "v1." keyId "." base64url(nonce || ciphertext || tag)
keyId     = 1*32( ALPHA / DIGIT / "_" / "-" )
nonce     = 12 random bytes
aad       = "v1." keyId            ; ASCII
key       = 32 bytes from the PUSH_TICKET_KEYS secret, selected by keyId
plaintext = JSON {"f": fid, "d": deviceId, "i": issuedAtSeconds, "p": "ios" | "android", "a": 1}
```

`f` is the app's Firebase Installation ID (FID), which FCM sends to directly.
App builds before FID registration sent an FCM registration token, sealed as
`t` in place of `f`; the function still opens and sends to those tickets until
they expire. A ticket with both, or neither, does not open.

AES-256-GCM with a 16-byte tag. Binding the key id into the AAD means a ticket
cannot be replayed under a different key id. `p` is optional and only used for
platform-specific message fields and the `platform` log field. `a` is present
when the app registered with `appNotifications`: it posts its own
notifications from data-only messages (see "FCM message").

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
| `agent` | Since 0.1.236, when known: the agent the window runs, as the short command name MonkeyMux detects (`claude`, `codex`, `copilot`, `opencode`, `antigravity`, `cursor-agent`, `pi`, `hermes`, `openclaw`, `grok`, `muse`). Only lowercase letters, digits and `-`, at most 32 bytes. The phone names the agent in the notification it shows |
| `title` | Since 0.1.237, when the window has one worth showing: its title, the first of the agent's session title, the title the program set (without a leading spinner or status glyph), the window name and the working folder's name that is not generic (a shell's name, the agent's own name, a host name, a path, `user@host`, a bare status word such as `working`, or the home folder). Control characters and runs of space become one space; at most 64 characters, cut with `…` |
| `alert` | For an `alert` only, since 0.1.233: `["bell"]`, `["notice"]` or both, the categories this registration wanted. The app honours each of the host's switches with it (for example in the foreground snackbar); an alert without it needs both on |
| `ts` | Event time, Unix seconds |

Decoders ignore unknown fields. The app trusts the decrypted `kind` over the
clear-text one.

## Kinds

| Kind | Host signal | Visible text | Priority |
| --- | --- | --- | --- |
| `permission` | A native agent asked for permission (`session/request_permission`) and the request is still pending, or a terminal program's status became `blocked` with `kind=permission` | "Approval needed" / "An agent is waiting for your approval." | high |
| `input` | A native agent asked for input (`elicitation/create`) and the request is still pending, or a terminal program's status became `blocked` with any other kind | "Input needed" / "An agent is waiting for your answer." | high |
| `finished` | A native `session/prompt` turn ended, or a terminal program's status went from `working` to `done` or `idle` | "Agent finished" / "An agent finished its turn." | normal |
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
{"fid": "<Firebase Installation ID>", "platform": "android", "deviceId": "<optional existing id>", "appNotifications": true}
```

App builds before FID registration send `"token": "<FCM registration token>"`
instead of `fid`, and so does the current app on Android devices whose Google
Play services predate FID registration (before 26.12): FCM reports a legacy
token through `onRegistered` there, which the app recognizes by its `:`. The function accepts exactly one of the two and logs which
(`target: "fid" | "token"`), so the remaining token registrations can be
watched as they age out.

The Android app sends `appNotifications: true`: it posts its own notifications
from data-only messages, which Android builds before that could not show. Any
other value is ignored. A ticket the app holds from before it sent the field
is renewed at the next start, so its pushes get the new form.

Response data:

```json
{"deviceId": "pX7cQe2LrV0sNw4yJk9aTg", "ticket": "v1.k1...."}
```

Errors use the callable error codes: `invalid-argument` for a bad request,
`unauthenticated` when the App Check token is missing, invalid or already used,
and `internal` when the ticket keys are not configured.

On Android, App Check uses Play Integrity. Both Play apps must have Cloud
project `monkeyssh` (529923319565) linked under Play Console > Protected with
Play > Play Integrity API. Without that link, App Check fails on every real
device, however the app was installed. Emulator debug builds use a debug token
and never exercise this path.

App Check settings differ between the two Android apps:

- **Production** (`xyz.depollsoft.monkeyssh`) accepts only installs Google Play
  recognizes (the default for Play Integrity).
- **β** (`xyz.depollsoft.monkeyssh.private`) also accepts installs Play does not
  recognize (`appIntegrity.allowUnrecognizedVersion`), so PR previews can opt
  in. Its Firebase app lists one SHA-256 certificate per way a β build reaches a
  phone: Play's app signing key (Play tracks), the Internal test certificate
  from Play Console > Test and release > Internal app sharing, and the upload
  key, which signs the APKs sent through Firebase App Distribution. App Check
  rejects a build whose signing certificate is not on that list with a 403 from
  `ExchangePlayIntegrityToken`, even though Play Integrity itself succeeded.

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
| 410 | `{"error":"unregistered"}` | FCM says the FID or token is not registered (`installation-id-not-registered`, `registration-token-not-registered`, `invalid-registration-token`) | delete the registration and remember the ticket as refused |
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

- In-memory token buckets keyed by a hash of the ticket's FID (or token) and split three
  ways: `permission` and `input`; `finished` and `alert`; and `test`. Each is
  burst 5, refilled at 30 per hour. Routine events and test taps can never use
  up the allowance approval requests need. A send that FCM could not take
  (5xx) refunds its token, so retries are free. Each function instance keeps
  its own buckets, so the real ceiling is that limit times the instance count.
- `maxInstances` in the global options is the hard bound on cost and abuse.
- The owner's Blaze spending cap is the outer bound. A Cloud Billing budget only
  alerts; it does not stop spending, so `maxInstances` is the actual limit.

### FCM message

An Android ticket with `a` (see "Ticket") gets a data-only message. The app
decrypts `p` and posts the notification itself (see "Notification text" under
App), in the slot its own notifications for that window use; `k` and `c` let it
post the generic text for the kind, tagged with the collapse key, when the
payload does not open. Every such push ends in a visible notification, so all
kinds go at high priority to wake the app:

```json
{
  "fid": "<from the ticket>",
  "data": {"v": "1", "p": "<payload>", "k": "finished", "c": "<collapse>"},
  "android": {"priority": "high", "collapseKey": "<collapse>", "ttl": "3600s"}
}
```

An iOS ticket, an Android ticket without `a` (a build that cannot show
data-only messages) and a ticket without a platform get an alert, which the iOS
notification service extension rewrites on the phone:

```json
{
  "fid": "<from the ticket>",
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

A ticket that seals a token (`t`) is sent with `"token"` in place of `"fid"`.

In the alert form, normal-priority kinds use `"priority": "normal"`,
`apns-priority: 5`, no sound on iOS, and the Android channel
`agent-updates-v2` (on Android 8 and later the channel, not the message
priority, decides sound and heads-up display). `mutable-content` lets the iOS
notification service extension replace the text with decrypted details (see
[iOS notification service extension](#ios-notification-service-extension)).

### Logging

Structured outcome codes only: `outcome`, `kind`, `platform`, for a
registration `target` (`fid` or `token`), and for FCM failures `fcmCode`, a
fixed enum such as `third-party-auth-error` (anything outside `[a-z0-9-]` is
logged as `unknown`). Tickets, FIDs, tokens, device ids, collapse keys and
payloads are never logged.

Cloud Run request logs record the caller's IP address. They are not stored:
the `_Default` sink has the exclusion `push-request-logs` (applied 2026-10-10,
and by `scripts/setup_functions_iam.sh`), so only the outcome logs above are
kept, for the bucket's default 30 days. The privacy policy's 30-day limit on
request logs therefore still holds. To check it:

```sh
gcloud logging sinks describe _Default --project=monkeyssh --format='value(exclusions[].name)'
```

Do not lengthen `_Default` retention: the privacy policy relies on 30 days.

### Deployment

CI owns deploys. The `functions-test` job in `ci.yml` builds and tests
`functions/` on pull requests and in the merge queue. After merge,
`.github/workflows/deploy-functions.yml` tests the same commit again and runs
`firebase deploy --only functions --force` on every push to `main` that changes
the paths in `FUNCTIONS_PATHS` (`scripts/ci_changes.py`). It can also be run by
hand on `main`. The deploy then checks that `pushNotify` answers `{}` with 400
and `registerPushDevice` answers a call without App Check with 401, because
firebase-tools can exit 0 with a function missing (a missing one answers 404).

- **Identity:** the workflow holds no key. GitHub's OIDC token is exchanged
  through the `github` Workload Identity pool for `functions-deployer@`, and
  the pool's provider accepts only this repository, `refs/heads/main` and
  `deploy-functions.yml`.
- **Runtime:** the functions run as `push-functions@`, which may send FCM
  messages, verify App Check tokens and read `PUSH_TICKET_KEYS`, and nothing
  else. The default compute account is a project Editor.
- **Setup:** `scripts/setup_functions_iam.sh` creates both accounts, their
  roles and the pool, and is safe to re-run. The ticket secret is created once
  by hand and never passes through CI:

  ```sh
  python3 -c 'import os,base64,json;print(json.dumps({"current":"k1","keys":{"k1":base64.urlsafe_b64encode(os.urandom(32)).rstrip(b"=").decode()}}))' \
    | firebase functions:secrets:set PUSH_TICKET_KEYS --project monkeyssh --data-file -
  ```

  A rotation adds a new secret version (`firebase functions:secrets:access
  PUSH_TICKET_KEYS` reads the current one). The functions pick up the latest
  version on their next deploy, so run the workflow by hand after setting it.

## MonkeyMux

### Control operations

The helper advertises the `push-v1` capability. Push fields travel in a nested
`push` object on the control message.

```json
{"id": "1", "type": "push_register",   "push": {"deviceId": "...", "ticket": "v1....", "publicKey": "<32 bytes>", "hostRef": "...", "events": ["attention", "finished", "bell", "notice"]}}
{"id": "2", "type": "push_unregister", "push": {"deviceId": "...", "hostRef": "<optional>"}}
{"id": "3", "type": "push_presence",   "clientId": "<attach client id>", "push": {"deviceId": "...", "foreground": false, "local": true, "alerts": true, "notices": true, "bridges": ["<bridge id>"]}}
{"id": "4", "type": "push_test",       "push": {"deviceId": "..."}}
```

- `push_register` answers `push_registered` with `{"push": {"result":
  "registered"}}`. If the function already refused that exact ticket, it answers
  `push_register_rejected` with result `stale_ticket` (after a 401) or
  `token_unregistered` (after a 410) and stores nothing. The app then fetches a
  new ticket, and for `token_unregistered` a new FCM registration first. The
  result keeps its name from when tickets sealed FCM tokens.
- `events` on `push_register` lists the event categories this saved host
  wants pushed. Without it (an app from before the list) the
  registration wants all of them; an empty list wants none; unknown entries
  are ignored. Registering again replaces the list. The categories are:
  - `attention`: `permission` and `input`.
  - `finished`: `finished`.
  - `bell`: an `alert` raised by a BEL.
  - `notice`: an `alert` raised by a desktop notification (OSC 9 text, OSC
    777 `notify`, or an OSC 99 notification that is not a query or close).

  One chunk of output can raise both; such an alert goes to a registration
  that wants either. `test` is always sent: it checks the path, not a
  preference. When a device has two registrations for the session (two saved
  hosts, see Storage), an event goes once, through the newest registration
  that wants it.
- `push_registered` echoes the categories the registration will receive in
  `push.events`. Helpers before 0.1.233 ignore `events` and echo nothing, so
  they would push everything. When a saved host has any kind turned off and
  the answer has no echo, the app sends `push_unregister` for that saved host
  and treats the helper like one without push support (retried later; Send
  test reports that the host needs a MonkeyMux update). It never leaves a
  registration in place that sends what the user turned off.
- `push_unregister` with a `hostRef` removes that one saved host's
  registration; without one it removes every registration of the device. It
  answers `push_unregistered`.
- `push_presence` answers `push_presence_ack`.
- `push_test` answers `push_test_result` with `{"push": {"result":
  "<result>"}}`: `sent`, `not_registered`, `bad_ticket`, `unregistered`,
  `rate_limited`, `capped` or `failed`. A test is sent once, without retries,
  because the app waits for the answer. It only finds a registration for this
  server's session; `not_registered` means the device has none here (another
  connection of the same saved host may have moved it to its session), so the
  app registers through that connection again and retries once.
- A helper older than the registration file answers with an error that names
  a newer MonkeyMux (see Storage). The app treats it like a helper without
  `push-v1`, which answers `unsupported command`: it skips that connection
  (another connection of the saved host registers instead, if there is one)
  and Send test reports that the host needs a MonkeyMux update. An unregister
  that either kind of helper refuses stays pending, because another session on
  the machine may run a newer helper that holds the registration; an updated
  session removes it on its next attach.

### Storage

`~/.monkeyssh/state/push-devices.json`, mode 0600 in a 0700 directory, written
through a temporary file and a rename. Every MonkeyMux server for the user
shares it, so each read and each read-modify-write holds an exclusive lock on
`push-devices.json.lock` (`flock` on POSIX, `LockFileEx` on Windows); without it
two servers could both read, change and rename, and one change would be lost.

- A registration is a device as reached through one saved host, for the one
  MonkeyMux session that saved host attaches to: `(deviceId, hostRef,
  sessionKey)`, plus the `events` it wants (absent means all). Only that session's server sends to it. Saved hosts that reach
  the same machine with different session names (one per project, say) are
  therefore separate: none receives another's events, and every notification
  names the saved host and session the app opens on a tap. Attaching a saved
  host through another session (its session setting changed) moves its
  registration rather than adding one. A saved host attached to two sessions
  at once (by hand, or by a tap on a notification from its old session) would
  move it back and forth, so the app registers one connection per saved host:
  the one on the saved host's configured session, or else the newest. Two saved hosts that reach the same
  machine user and session (LAN and Tailscale, say) register separately and
  can be turned off separately; an event still goes to each device once,
  through its most recently updated registration for that session.
- The file is schema version 3 since 0.1.233, which added `events`; version
  2 (0.1.230) added `sessionKey`. A helper treats a file with a higher version
  than its own as written by a newer MonkeyMux: it neither sends from it nor
  writes it, and its `push_register` fails, so a session still running an
  older helper cannot strip the session keys or the event lists. It sends
  nothing until the app updates it on the next attach.
- A version 2 file is read as it is: its registrations are already scoped to a
  session and, having no `events`, want everything until the app registers
  them again. The next write stamps version 3. A version 1 file reads as
  having no registrations: its records named no session and are replaced by
  the next `push_register`. Its salt and refused tickets are kept.
- Each server rereads the file when its size, modification time or identity
  changed, at most once a second. Every write renames a new file into place,
  so the identity check catches a rewrite of the same size within the
  filesystem's timestamp granularity.
- Caps: 8 devices and 16 saved hosts per device; the least recently updated is
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
  raises its bell alerts; `notices` says it raises desktop notifications
  itself. Without `notices` (an app from before the field), `alerts`
  covers desktop notifications too. `bridges` lists the native agent bridges
  whose events it is receiving.
  Repeated every 20 seconds. iOS suspends a backgrounded app, so iOS reports
  idle instead.
- **Idle**: neither. Sent once.

A report counts while it is under 45 seconds old and the attach client is still
attached. A device **attends** window W when it is viewing and W is the active
window, or when a report in the last 30 seconds saw it viewing W. A device is
**covered locally** for an alert when its last local report covered every
category of that alert the device wants (`alerts` for a bell, `notices` for a
desktop notification), and for a native agent event when that report listed
the event's bridge. A terminal program's status (OSC 7501) is never covered
locally: the host pushes it, and on Android it takes the window's slot from
the bell the app raised. A local claim lapses 25 seconds after it was made (one heartbeat plus
slack), so a suspended or killed app stops covering anything within that time.
A one-off event (`finished`, `alert`) skipped only because of local coverage
is kept for 2 minutes and sent if the coverage lapses first; a deferred alert
remembers its categories, so it is sent when the claim for any of them lapses.

- `permission`, `input` and `finished` skip the devices that attend the window
  or are covered locally.
- `alert` is skipped for every device when any device attends the window, and
  for devices covered locally.
- A desktop `monkeymux attach` never reports presence, so it never suppresses a
  phone.

### One notification per window and event

An agent that needs the user or finishes its turn usually also rings the bell
or posts a desktop notification. Pushed as well, that alert would arrive as a
second notification beside the status one. From 0.1.243:

- An alert from a window's output is held for 1.5 seconds before it is raised,
  since the program's status report often comes in the next chunk, and up to
  5 seconds more while a status push for that window is still on its way.
- A device is not sent a window's alert when a status that reached it (the
  function accepted it) still holds: the window's program waits on a request
  of the kind the device was last sent for that window, or it finished a turn
  that reached the device under 15 seconds ago and still reports `done` or
  `idle`. Anything else is a new event or one the device did not hear of (it
  turned that status off, or the push was refused or failed), and the alert
  is pushed.
- When kept-back events go out together after a local claim lapses, a device
  gets a window's status without its alert.
- A closing server raises the window events still queued or held and, beside
  its teardown, waits up to 2 seconds for pushes in flight, so a session that
  ends right after an alert still delivers it within the time an upgrade
  gives the outgoing helper.

### Coalescing, caps and retries

- One event per device, window and kind in any 30-second window. A push that
  never arrived (refused or failed) does not hold the next one back.
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
  queued with what raised it (64 deep, dropped when full, and only while a
  device is registered) for the notifier goroutine.

### Native agent signals

The ACP bridge reports monotonic counters of permission requests, input
requests and completed prompt turns, plus how many permission and input
requests are pending right now. While at least one device is registered for
its session, each server polls the bridges behind its native agent windows
every 2 seconds.

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

### Terminal agent signals

A program in a terminal window that reports its status with the Program Status
Protocol (OSC 7501, which Claude Code and Pi send) raises the same kinds from
0.1.236 on. The PTY reader compares the window's
published status before and after each chunk:

- `working` to `done` or `idle` raises `finished`.
- A newly `blocked` status raises `permission` for `kind=permission` and
  `input` for any other kind (`question`, `auth` or none). A change from one
  blocked kind to another raises again; the same block reported twice does not.
- A rejected prompt (`blocked` to `idle`), an `error`, and a status that ends
  because the program exited raise nothing.

The push carries only its kind and window, never the report's `msg`, `title` or
`app`. Unlike a native request, a terminal one is raised once, when the status
changes: if a device was watching that window or the event was coalesced, it is
not raised again while the program stays blocked. Native agent windows are
skipped here because their bridge raises the same events.

The endpoint is `https://us-central1-monkeyssh.cloudfunctions.net/pushNotify`.
`MONKEYMUX_PUSH_ENDPOINT` in the server's environment overrides it for testing.

## App

- The feature exists only when the build sets `FLUTTY_FIREBASE_ENABLED=true` and
  runs on iOS or Android. Elsewhere the settings section is hidden.
- FCM auto-init is off in `Info.plist` and `AndroidManifest.xml`, and App Check
  token auto-refresh is off in `Info.plist` (`FirebaseAppCheckTokenAutoRefreshEnabled`),
  because the App Check plugin installs its provider at launch. The app
  registers with FCM only after the user opts in, then turns auto-init on so
  FCM keeps the registration current; opting out turns it off again. A user who
  never opts in never contacts FCM or App Check. FID registration is on
  (`FirebaseMessagingInstallationIdEnabled` in `Info.plist`,
  `firebase_messaging_installation_id_enabled` in `AndroidManifest.xml`), so
  FCM registers the Firebase Installation ID and the token APIs are disabled.
  `test/app/push_native_config_test.dart` pins these keys.
- **Opt in:** request notification permission, activate App Check, register
  with FCM (`register()` reports the FID through `onRegistered`), create the
  X25519 key pair and the host reference key in secure
  storage, call `registerPushDevice` with a limited-use App Check token, and
  store the device id, the ticket and when it was issued. If push is still on
  from a run whose keys the app could not read at start (a keychain error, say),
  hosts may hold tickets for that FID, so the opt-in first deletes the Firebase
  installation as an opt-out would. If a step fails, the
  app turns auto-init off, unregisters from FCM and deletes the new keys. It
  keeps the Firebase installation, which the other Firebase SDKs share, because
  no host has a ticket for that FID yet. An unregister that fails is retried as
  a pending deletion (see Opt out).
- **Attach:** for each saved host with push enabled, send `push_register`
  through one of its live MonkeyMux connections (see Storage for which), once
  per connection, then presence for every connection (see Attendance). The
  registration is for that connection's MonkeyMux session: each saved host
  receives only the events of the session it attaches to.
  The viewed connection comes from the route's `connectionId`. When that id
  matches no live connection (the terminal reconnected) or is absent, a host
  with a single MonkeyMux connection is unambiguous and two are treated as not
  viewed.
- **Renewal:** at every start and resume the app registers with FCM and
  compares the FID with the one its ticket seals (an FID that rotated while the
  app was not running is never redelivered) and renews the ticket when it
  changed, when it is a week old, or when a host reports it refused. A ticket
  from a build before FID registration sealed a token, which never matches, so
  it is renewed at the first start after the update. Each renewal spends
  an App Check attestation, so a failed renewal is retried from later syncs
  after 1 minute, then 2, 4 and so on up to an hour. A ticket a host refused is
  not offered again. After `token_unregistered` the app must unregister from
  FCM before registering again, because `register()` otherwise reports the
  cached registration; until that succeeds it keeps retrying rather than
  sealing the dead FID again.
- **Opt out:** wait for any sync in flight, send `push_unregister` to reachable
  hosts and remember the rest for their next attach (deleted saved hosts are
  dropped from that list), turn auto-init off, unregister from FCM and delete
  the Firebase installation, and delete the device key, the host reference
  key, the device id and the ticket.
  Payloads from hosts that could not be reached can no longer be decrypted.
  The opt-out is saved before any of this starts, so an app killed half-way
  finishes it at its next start (hosts that held the registration are
  unregistered on their next attach). An FID outlives `unregister()`, so
  deleting the installation is what makes a later opt-in register a new FID:
  a host that missed the unregister then gets 410 for the old one instead of
  delivering pushes the new device key cannot open. Whether the deletion also
  retires an FCM token issued before the update is not documented; a ticket
  sealing one expires within 90 days either way. Turning auto-init off and
  deleting the installation are retried separately from later syncs and across
  restarts until each succeeds, serialized with opt-in, and so is the check at
  every start and resume. A deletion is only scheduled once FCM has registered
  the app (iOS cannot unregister before its first check-in). A new opt-in
  cancels a pending auto-init change but finishes a pending deletion before it
  registers, and fails (to be retried) if the deletion fails again, so the old
  FID never comes back with a new device key.
- **Per host:** turning a saved host off takes effect for a sync already
  running, waits for it, then sends `push_unregister` with that host's
  reference now, or on its next attach if it is not connected. Deleting a saved
  host leaves its registration on the machine until it expires (30 days without
  a refresh).
- **Kinds per host:** each saved host stores which kinds it may raise (agent
  needs you, agent finished, window alerts, shell notifications) and whether
  it pushes while MonkeySSH is closed; they live on the host row and travel
  with transfers. The app applies them at once to what it shows, including
  the foreground snackbar. A registration carries them as `events` and is
  sent again when they change, so a connected host follows within one sync
  and one that is not connected on its next attach. The app-wide Desktop
  notifications switch in Settings removes `notice` from every
  registration. Presence is per device and session: two saved hosts on one
  session with different kinds share the claim the last report made, which
  can let an alert through twice.
- **Tap:** decrypt `p`, map `hostRef` back to a host by recomputing the HMAC for
  each saved host, and open `/terminal/<hostId>` at that MonkeyMux session and
  window. A live connection is reused only when it is attached to that
  MonkeyMux session, or when it has no terminal yet (an earlier tap replaced
  the terminal that was opening it), see `resolveMuxSessionConnection`.
  Otherwise the terminal opens a new connection that attaches to the session,
  rather than showing another session's terminal on a connection to the same
  host. A native agent window opens its chat. A payload
  that does not decrypt opens the app on Connections.
- **Notification text:** the phone names the agent, the window, the saved
  host and the MonkeyMux session, from the decrypted payload and its own host
  labels: "Claude Code finished" / "Fix login bug · build-box · MonkeySSH".
  Titles are "<Agent> needs approval", "<Agent> has a question" and "<Agent>
  finished" when the payload names a known agent (otherwise the generic titles
  in the Kinds table), and "Terminal alert" or "MonkeySSH" for the other
  kinds. The body joins the window's title, the host label when the phone
  knows the host, and then the session with ` · `, each once (the session is
  named after the host by default, so it usually shows once); with none of
  them it is the generic body.
  `lib/domain/services/push/push_notification_text.dart` and the iOS
  extension build the same strings.
- **Notification context:** to show that text while MonkeySSH is not running,
  the app stores the device's private key, every saved host's label and local
  id by host reference, and the categories each host may push now
  (`{"v":1,"seed":"<base64url>","hosts":{"<hostRef>":"<label>"},"ids":{"<hostRef>":3},"allow":{"<hostRef>":["attention","finished","bell","notice"]}}`:
  the host's kinds, without `notice` when Desktop notifications are off in
  Settings, and none when the host's push is off). It is written after opt-in
  and whenever a sync follows a change to the saved hosts or that switch, and
  deleted on opt-out and at any start without a registration (an opt-out the
  app was killed in, or a delete that failed). Android keeps it in secure storage
  (`monkeyssh_push_notify_v1`); iOS keeps it in the keychain group
  `<team>.<bundle id>.push` (service `xyz.depollsoft.monkeyssh.push`, account
  `notification-context-v1`, readable after first unlock on this device only),
  which the app and its notification service extension share. It never
  leaves the phone.
- **Android:** pushes arrive as data only (for a ticket with `a`). A
  FlutterFire background handler, registered at startup, opens the payload and
  posts the notification on the channel for the kind, in the window's
  notification slot for its kind (see "One notification per window"), so a
  newer push for the window replaces the older one and a push sent after a
  lapsed local claim replaces what the app already raised. Without the host's
  id in the context (one written by an older build) the id comes from the
  collapse key. It drops a push the context's `allow` says the host no longer
  raises: a host's registration changes only when the host is reached, so a
  kind turned off meanwhile still arrives (iOS cannot drop a push this way and
  shows it). When the payload does not open (no context yet, or a key from an
  earlier opt-in) it posts the generic text for `k`. A tap comes back through
  the local notification plugin carrying the encrypted payload and opens like
  an FCM tap, also when it starts a new activity on the running engine (the
  bridge reads the activity's launch intent again when the app resumes).
- **One notification per window:** a MonkeyMux or tmux window has two local
  notification slots, as its pushes have two collapse groups: one for a
  request its program waits on and one for everything else
  (`buildWindowNotificationId`). The app's bells and the desktop
  notifications the helper forwards share them across every connection to
  the session, and a bell that arrives with a desktop notification for the
  same window is not posted on its own. While the window's program waits on
  the user, its bells and notifications go to the request slot and say what
  it waits for, so on Android they and the host's push for that request are
  one notification, whichever came last. Android pushes use the slot for
  their kind (see Android), and a request push also clears the window's
  other slot, where the app put a bell it rang before the program reported
  the request. A slot has one owner across every connection's window bar: a
  later bell or notification takes it, so an older notification's close, one
  that never showed, or a bell's flag clearing (the window viewed, the bar
  closed or reconnected) does not remove what shows, and the app never
  removes a push from a slot. Known limits: iOS notifications from pushes and
  from the app have different identifiers, so in the seconds before iOS
  suspends a backgrounded app, a bell can show beside the push for a window
  the app was not viewing, and an answered request stays beside the finished
  turn that followed it (as before 0.1.243); the active window's own desktop
  notifications (from the live terminal stream) and native chat
  notifications keep their own ids; and two saved hosts for one machine and
  session have separate slots.
- **iOS:** the notification service extension
  (`ios/NotificationServiceExtension`) opens the payload with the shared
  context, rewrites the title and body, and groups a host's notifications by
  thread. Anything it cannot open is shown unchanged.
- **Foreground:** iOS presents nothing while the app is open (the AppDelegate
  answers `willPresent` with no options, as before the app had a notification
  delegate, and runs each completion handler once). `onMessage` drops the push
  when the terminal on screen shows that window, or when it is an `alert` from
  the session on screen, whose window bar raises its own alert. Anything else
  shows a snackbar with an Open action.
- **Android channels:** "Agent attention" (`agent-attention`, high importance,
  pops up) for approvals and questions, and "Agent updates"
  (`agent-updates-v2`, default importance: sound and the status bar, no pop-up)
  for finished turns and window alerts. The first "Agent updates" channel
  (`agent-updates`) was low importance, which put finished turns in the
  collapsed Silent section beside the SSH connection notification. Android
  never raises an existing channel's importance, so the app deletes it and
  creates the new id. A message naming a channel the app has not created shows
  on the manifest default, `agent-attention`.

### iOS notification service extension

`ios/NotificationServiceExtension/` decrypts `p` before iOS shows the push and
replaces the generic text. Android builds the same strings in Dart.

| Kind | Title with a known `agent` | Title otherwise |
| --- | --- | --- |
| `permission` | "Claude Code needs approval" | "Approval needed" |
| `input` | "Claude Code has a question" | "Input needed" |
| `finished` | "Claude Code finished" | "Agent finished" |
| `alert` | "Terminal alert" | "Terminal alert" |
| `test` | "MonkeySSH" | "MonkeySSH" |

Agent labels: `claude` Claude Code, `codex` Codex, `copilot` Copilot,
`opencode` OpenCode, `antigravity` Antigravity, `cursor-agent` Cursor Agent,
`pi` Pi, `hermes` Hermes, `openclaw` OpenClaw, `grok` Grok, `muse` Muse Code.
The body is "Push notifications are working." for a test, otherwise
"<host label> · <session>" when the app shared a label for `hostRef` (just the
label when there is no session or the session is named after the host, as it is
by default), and the generic body when it did not. The thread
identifier becomes `hostRef`, so each host's notifications group together.
`userInfo` is never changed, and any failure (no `p`, no keychain item, a
payload that does not open) delivers the push as sent.

The extension reads the device key and host labels from a keychain item the
app writes through the `xyz.depollsoft.monkeyssh/push_notification_context`
method channel (`write` with `{"json": ...}`, `delete`):

| Attribute | Value |
| --- | --- |
| Class | generic password |
| Service | `xyz.depollsoft.monkeyssh.push` |
| Account | `notification-context-v1` |
| Access group | `<AppIdentifierPrefix><app bundle id>.push` |
| Accessible | after first unlock, this device only |
| Data | `{"v": 1, "seed": "<base64url device private key>", "hosts": {"<hostRef>": "<label>"}}` |

Both targets name the access group in Info.plist (`MonkeySSHPushKeychainGroup`)
and list it in `keychain-access-groups`. The app lists its own group,
`<AppIdentifierPrefix><bundle id>`, first: the first group is the default for
keychain items written without one, so every secret the app already stores
keeps its group. Builds re-signed by `fastlane resign_ipa` (TestFlight and
Firebase builds of the private app) are signed with the profile's
entitlements, whose first group is `TEAMID.*`; the lane keeps that order,
appends the push group, and writes the concrete group into both Info.plists,
because an unsigned build leaves `$(AppIdentifierPrefix)` empty. The extension
lists the push group alone.

The extension ids are `xyz.depollsoft.monkeyssh.NotificationService` and
`xyz.depollsoft.monkeyssh.private.NotificationService`. The Regenerate iOS
Provisioning Profiles workflow registers them in the developer portal before
match creates their profiles. `scripts/test_ios_push_notification_content.sh`
checks the decryption and text against the shared vectors. The Build iOS CI
job runs it.

## Follow-ups

- Live Activity push updates for #922.

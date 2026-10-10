# dartssh2 (vendored)

> **Vendored fork.** This is a copy of [`dartssh2`](https://pub.dev/packages/dartssh2)
> **4.1.0** from pub.dev (`vicajilau/dartssh2`), carrying one small patch for
> SSH agent forwarding. Everything outside the files listed below is
> byte-for-byte the published package. Upstream is MIT licensed; see
> [`LICENSE`](LICENSE). Only `lib/`, `LICENSE` and `pubspec.yaml` are kept; the
> upstream tests, examples and tooling live in the upstream repository.

MonkeySSH lets a host use the phone's keys through agent forwarding. Upstream
4.1.0 lets a process on that host stall the app and exhaust its memory through
`$SSH_AUTH_SOCK`, and makes every session after the first on an OpenSSH
connection fail once forwarding is on. The patch fixes both and should go
upstream; replace this directory with the released package once it does.

## Patch

`lib/src/ssh_agent.dart`, `SSHAgentChannel`:

- Input goes into a buffer that grows geometrically and is parsed at an
  offset. Upstream copied the rest of the buffer for every frame, which is
  quadratic in the number of frames; a plain append-and-copy is still
  quadratic when one frame arrives as many tiny writes.
- One request is handled at a time, and the channel yields to the event loop
  before the next. Upstream drained a burst of frames in one go, so a flood
  blocked timers, input and rendering for as long as it lasted (about a minute
  for one 2 MiB window of 5-byte frames on a laptop).
- The channel closes when more than `maxBufferedInputBytes` of requests wait
  unanswered (a client that waits for each reply never has more than one
  frame outstanding), or when more than `maxPendingReplyBytes` of replies
  wait for the peer to read them. Upstream queued replies without limit.
- At most `maxChannelsPerHandler` (32) agent channels are served at once for
  one handler. `SSHClient` refuses further channel opens with
  `SSH_OPEN_RESOURCE_SHORTAGE` before allocating anything for them (patched
  in `lib/src/ssh_client.dart`). Each `ssh` run on the server holds one
  while it authenticates, so this caps simultaneous onward sign-ins, not
  onward connections.
- When the peer sends EOF, the requests it already sent are still answered,
  as upstream does; the slot is released when the channel closes.

The reply cap relies on the server's sshd honouring channel windows, as
OpenSSH does: once the agent client stops reading, sshd stops granting window,
replies wait in `pendingOutputBytes`, and the cap closes the channel. A
server that grants window without reading its socket is not bounded by this
patch; that would need backpressure on the transport's socket writes.

`lib/src/ssh_channel.dart`:

- `SSHChannel.pendingOutputBytes` counts bytes passed to `addData` that the
  upload loop has not sent yet, so the agent channel can tell when the peer
  stops reading.
- `sendAgentForwardingRequest` sends `auth-agent-req@openssh.com` with
  `want_reply` false and does not wait, as `ssh(1)` does. OpenSSH's sshd sets
  forwarding up for the first request on a connection and refuses the rest,
  although every later session still gets `SSH_AUTH_SOCK`; waiting for that
  refusal failed each later session with `Failed to request agent forwarding`.

The app's regression tests for these live in
`test/domain/services/ssh_agent_channel_flood_test.dart` and the opt-in
`test/integration/ssh_agent_forwarding_sshd_e2e_test.dart`.

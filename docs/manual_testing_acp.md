# ACP over SSH validation

Use the deterministic fake provider before testing a network-backed agent. It
uses ACP v1 over stdio, needs no credentials, never calls the network, and emits
small fixed fixtures for every supported surface.

## Automated harness

From the repository root on a machine with localhost SSH access:

```bash
./scripts/setup_acp_test_env.sh
source "$HOME/.local/state/monkeyssh/acp-test/env.sh"
flutter test test/integration/acp_ssh_bridge_e2e_test.dart
./scripts/setup_acp_test_env.sh teardown
```

The setup script reuses the localhost SSH-key helper used by the tmux harness.
It builds the current `remote/monkeymux` source, installs it and
`fake-acp-provider` in an isolated state directory, verifies key-only localhost
SSH, and prints the exact MonkeySSH host and provider configuration. Teardown
stops bridges labeled `MonkeySSH ACP E2E`, removes the authorized test key, and
deletes the isolated files.

The SSH test is skipped with setup instructions unless
`MONKEYSSH_RUN_LOCAL_SSH_E2E=1` and the printed environment is loaded. The
credential-free provider protocol and script checks always run in CI:

```bash
flutter test test/scripts
```

Automated coverage includes initialization and auth metadata, create/list/load/
resume/close, config options, slash commands, user/assistant/thought replay,
plan and usage updates, tool creation/update, exact permission choices, bounded
image/resource content, prompt cancellation, SSH disconnect/reconnect replay,
and bridge stop.

## Fake-provider app setup

Use the values printed by `setup_acp_test_env.sh`:

1. Add the localhost SSH host with the generated key.
2. In **Settings → Agents → Custom providers**, add `Fake ACP v1`.
3. Set the command to the printed absolute `fake-acp-provider` path.
4. Approve that exact command and use the printed working directory.
5. Configure the host to use MonkeyMux, connect its terminal, and open the
   window navigator.
6. Choose **New Window → Other native agent**, select `Fake ACP v1`, and start
   the session.

The provider advertises `/echo`, `/fixtures`, and `/wait`. `/fixtures` emits
all rendering fixtures and a permission request. `/wait` remains active until
Cancel is tapped.

## Mobile one-handed flow

Test on the smallest supported phone size:

1. Open a MonkeyMux terminal and its window navigator with one thumb.
2. Choose **New Window → Other native agent** and create a fake-provider session
   without rotating the device.
3. Enter `/fixtures`, select it from the slash-command picker, and send.
4. Scroll through thought, plan, tool, image, resource, and usage cards.
5. Choose each permission option in separate turns; the exact choices are
   **Allow once**, **Always allow**, **Reject once**, and **Always reject**.
6. While a response streams, type and queue a follow-up; verify the submitted
   text moves into chat immediately and the keyboard remains open.
7. Type `/` and continue entering a command while autocomplete stays visible
   without dismissing the keyboard. Then run `/wait` and tap Cancel. No
   critical control should require a two-handed reach or be hidden behind the
   keyboard/safe area.

Check VoiceOver/TalkBack labels, Dynamic Type/font scaling, landscape, and
light/dark mode while completing the same flow.

## Free and Pro concurrency

| Check | Free | Pro |
| --- | --- | --- |
| First active ACP session | Starts normally | Starts normally |
| Second simultaneous session | Upgrade/concurrency choice appears; existing session remains safe | Starts and both sessions remain independently usable |
| Switch during streaming | Existing turn is not duplicated or silently stopped | Both timelines retain the correct host/provider/session |
| Stop one session | Only that bridge/session stops | Only that bridge/session stops |

Repeat with sessions on two different hosts. Declining an upgrade or cancelling
the concurrency choice must not stop an already running session.

## Attachments and permissions

- Send a small image, text file, and remote SFTP file. Verify previews, removal,
  retry, and prompt ordering.
- Try an unsupported or oversized attachment. The UI must reject it clearly
  without sending partial content.
- Confirm image/resource bytes appear only in the intended session and are not
  copied into diagnostics or telemetry.
- For each fake permission option, verify the selected `optionId` reaches the
  matching tool card and that reject/cancel does not report success.
- Background the app while the permission sheet is open. Returning must restore
  the same request once, without auto-approval.

## Background, reconnect, and notifications

1. Start `/fixtures`, background the app before answering permission, briefly
   disable connectivity, restore it, and foreground the app.
2. Verify MonkeyMux reconnects, replay is deduplicated, the pending permission
   returns, and the prompt completes once.
3. Start `/wait`, background the app, restore it, then cancel. Verify the final
   stop reason is `cancelled`.
4. Let a background turn finish and tap its notification. Navigation must open
   the correct host, provider, and session rather than the most recently viewed
   session.
5. Stop the session and confirm its bridge disappears from
   `monkeymux acp list`; reconnect must not resurrect it.

## Real-provider matrix

Record provider version, install method, shell, remote OS/version, advertised
ACP capabilities, and failures. Capabilities are negotiated at runtime, so an
empty cell is a test result—not an assumption. Authentication and model access
are the only steps that may require provider credentials.

| Remote OS | Copilot CLI (`copilot --acp --no-color --no-auto-update --log-level error`) | OpenCode (`opencode acp --log-level ERROR`) | Pi (MonkeySSH-pinned `pi-acp` via `npx`) | Expected differences to record |
| --- | --- | --- | --- | --- |
| macOS | Initialize, login handoff, new/list/load/resume, text/image/resource, permission, cancel, reconnect | Initialize, `opencode auth login`, new/list/load/resume, text/image/resource, permission, cancel, reconnect | Resolve `npx`; test text/image/tool output, extension slash commands such as `/wt create`, queueing, cancel, and reconnect | Homebrew/npm PATH in SSH exec shells; provider-specific slash commands, modes/models, session titles, and permission wording |
| Linux | Same flow; test package and npm installs | Same flow; test installer and npm installs | Same flow; verify the pinned adapter fetches once and is reused from the npm cache | Distribution shell/PATH, sandbox/tool availability, notification behavior when the phone backgrounds |
| Windows | Test native OpenSSH + PowerShell; repeat in WSL when used | Test native OpenSSH + PowerShell; repeat in WSL when used | Test Node/`npx` resolution and WSL separately | Native path/quoting and executable suffixes versus POSIX paths in WSL; some versions may advertise different load/resume, image, or embedded-resource capabilities |

For every cell:

1. Compare advertised capabilities with visible controls; unsupported controls
   must be absent or disabled.
2. Run a harmless read-only prompt, then a tool requiring permission.
3. Test attachment types separately; do not infer resource support from image
   support.
4. Disconnect during streaming and during permission, then verify replay and
   session identity after reconnect.
5. Close/stop from the native chat or MonkeyMux window navigator and confirm
   no provider or bridge process remains.

## Privacy checks

- Inspect Settings → Diagnostics after the flow. It may contain IDs, counts,
  durations, states, and error types only.
- It must not contain hostnames, usernames, IPs, commands, prompts, responses,
  thought text, tool input/output, session/window names, paths, attachment
  names/data, clipboard contents, credentials, or raw ACP/SSH frames.
- With telemetry disabled, no analytics or crash upload should occur. With
  telemetry enabled, inspect only allowlisted coarse events and verify opt-out
  and delete-unsent-reports still work.
- Remove provider credentials and the generated localhost key after testing.

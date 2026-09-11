# MonkeyMux

MonkeyMux is MonkeySSH's purpose-built remote terminal multiplexer. It is a
per-user helper that runs on the SSH target and exposes:

- `monkeymux attach <session>` for the foreground terminal path.
- `monkeymux control <session> --json` for newline-delimited JSON control.
- `monkeymux acp` for persistent, local-only Agent Client Protocol (ACP)
  provider bridges.

## Using MonkeyMux on the host

MonkeySSH installs a managed launcher at `~/.local/bin/monkeymux`. Add that
directory to `PATH` once if the host does not already include it:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Running `monkeymux` with no arguments creates `main` when nothing is running,
attaches immediately when there is one session, or shows a numbered chooser
when several sessions are available.

The direct CLI accepts both concise and familiar tmux-style commands:

```sh
monkeymux                         # attach, create, or choose
monkeymux attach work             # attach to work
monkeymux attach --existing work  # attach only if work is still running
monkeymux attach-session -t work  # same operation, tmux spelling
monkeymux new-session -s review   # create and attach
monkeymux new-session -d -s build # create in the background
monkeymux list-sessions           # alias: ls
monkeymux kill-session -t review
```

Every attached terminal remains connected. The active window is shared, as it
is for clients attached to the same tmux session, so a switch made on the phone
also switches a host terminal. Input from every client reaches that window.
The client that most recently types, taps the MonkeySSH terminal, or selects a
window becomes primary, and MonkeyMux resizes the shared PTY to that client's
viewport. Other clients stay attached and follow the same window; interacting
with one immediately makes its screen size authoritative. A stalled client is
disconnected instead of blocking the others.

### Prefix keys

The default prefix is `Ctrl-B`:

| Keys | Action |
| --- | --- |
| `Ctrl-B c` | Create a window in the active window's directory |
| `Ctrl-B n` / `Ctrl-B p` | Select the next / previous window |
| `Ctrl-B 0` ... `Ctrl-B 9` | Select a window by index |
| `Ctrl-B l` | Return to the last window |
| `Ctrl-B &`, then `y` | Close the current window |
| `Ctrl-B d` | Detach only this terminal |
| `Ctrl-B Ctrl-B` | Send a literal `Ctrl-B` to the program |

Use `monkeymux attach --no-prefix <session>` when an application must receive
every `Ctrl-B` unchanged.

Ordinary foreground output is relayed directly without terminal emulation.
MonkeyMux observes metadata and routes response-producing terminal queries only
to the primary client so simultaneous terminals cannot send duplicate replies.
All structured state and commands belong on the control backchannel.

### Persistent ACP bridges

`monkeymux acp start --provider-id ID --provider LABEL --command COMMAND --cwd DIR` starts an
already-approved ACP provider in `DIR` without a PTY. The provider's stdin and
stdout are strictly NDJSON; stderr is discarded separately and is never
relayed, logged, or persisted. The bridge daemon is detached from its launching
SSH exec channel, so provider work continues across phone suspension and
reconnects.

Each bridge has an opaque ID and a distinct user-only socket in MonkeyMux's
existing runtime directory. The bridge namespace is intentionally separate from
terminal session sockets. The supported operations are:

```text
monkeymux acp start --provider-id ID --provider LABEL --command COMMAND --cwd DIR
monkeymux acp attach BRIDGE_ID       # `connect` is an alias
monkeymux acp list
monkeymux acp status BRIDGE_ID
monkeymux acp stop BRIDGE_ID
monkeymux acp gc
```

`attach` speaks newline-delimited JSON over its stdin/stdout. Its first frame is
`{"version":1,"type":"hello","bridgeId":"...","lastAck":N}`. Provider output is
relayed as `output` frames with a monotonically increasing `sequence`; clients
reply with `ack` frames and may reconnect using `lastAck`. The bridge retains a
bounded in-memory replay window. If a requested sequence was evicted, it sends
an `overflow` frame with `retainedFrom` before the retained events. State changes
are sequenced `state` frames. Client-to-provider ACP messages use
`{"version":1,"type":"input","data":{...}}`.

Multiple clients may attach safely as readers. Only one attached client holds
the input writer lease at a time; another client can take the lease after that
writer disconnects. Provider-originated JSON-RPC requests, including permission
requests, remain pending while no client is attached. MonkeyMux never creates a
permission response.

The replay buffer is memory-only. Bridge metadata exposed by `list` and
`status` contains bounded provider/session IDs, working directory, state,
counts, timing, and a command hash so clients can rediscover native windows; it
never contains the command, stderr, prompts, responses, or other ACP payload.
Explicit `stop` terminates the provider process tree. Bridges persist until
explicitly stopped, like MonkeyMux terminal windows. `gc` performs deliberate
idle cleanup and removes stale socket artifacts. ACP children use ordinary
pipes on every platform—never a POSIX PTY or Windows ConPTY.

### Terminal session details

`attach` and `new-session` can start a session server. Optional `--cwd`,
`--name`, and `--command` flags seed the initial window only when a new server
is created, so MonkeySSH can launch a coding agent without creating a duplicate
window on reconnect. If a session process is still alive but its socket is not
accepting connections, `attach` refuses to steal the socket path and create a
replacement server — on Windows that race previously orphaned the real windows
behind an unreachable helper while auto-connect surfaced a fresh one-window
workspace. Helper upgrades similarly refuse to replace a running server when a
window snapshot cannot be collected. An upgrade also waits for the outgoing
helper's process to exit and only unlinks the socket inode it created, so a
still-closing old helper cannot delete the replacement's rebound path. If that
path does disappear, the live server republishes it instead of staying
unreachable. Pi windows resolve an explicit `--session`, then a uniquely open
JSONL file. Named sessions are matched against Pi's published terminal title
(official builds use `π - <name> - <cwd>`), using the latest `session_info`
record even when large image records appear earlier in the JSONL. This remains
reliable when Pi creates the JSONL only after its first assistant response or
several restored processes started at once. A validated exact identity is kept
on the live window for later helper upgrades, including unnamed sessions on
Windows where process arguments cannot recover it. For unnamed same-directory
windows inherited from an older helper, MonkeyMux pairs a unique JSONL write
time with that window's most recent terminal output; overlapping timestamps
stay ambiguous. MonkeyMux otherwise correlates a unique session-header creation
time with the live process start and relaunches a matched session by its exact
file path. A later unowned write in the same working directory marks that match
ambiguous (including `/new` and `/resume` rotation), so it launches fresh rather
than risking the wrong conversation. Plain working-directory fallback is used
only for one live window and one unused session updated during that foreground
process. Across Copilot, Codex, OpenCode, Claude Code, Antigravity, and
Cursor Agent, argv, open-file, or live-lock identity wins; cwd/history fallback
only accepts state updated during that foreground process. Claude Code's cwd
fallback follows a session that moved: entering a git worktree relocates the
JSONL into the worktree's project directory, so that directory's name — which
encodes where the session lives — decides ownership, not the directory the
session opened in or the per-message `cwd`, which tracks the agent's own shell
through any `cd`. Directories the session recorded remain the fallback for a
project directory name that encoding cannot account for. A carried resume ID
is revalidated because a failed resume may have fallen back to a fresh agent.
Stale or ambiguous evidence leaves the restored window fresh instead of
injecting an older conversation. `--session-dir`,
environment, and global/project `settings.json` session directories are honored,
while nested child-agent stores are excluded. The server inherits the environment from
the shell that launched it exactly, so profile-managed values such as `PATH`
and tool-specific variables remain user-owned. PTY windows inherit that
environment and add terminal defaults such as `TERM=xterm-256color` and
`COLORTERM=truecolor` only when the launch environment does not already provide
usable terminal hints. They also advertise `FORCE_HYPERLINK=1` (unless already
set) so OSC 8 capable CLIs such as Copilot and `gh` emit clickable hyperlinks,
which MonkeySSH renders and opens.

Window switching and reconnect repaint from raw byte history for the selected
window. Main-screen shell history is capped for responsive switching; active
alternate-screen, agent, and non-shell foreground program windows replay the
larger retained history so scrollback is restored before the next resize/redraw.
MonkeyMux still does not emulate terminal screen state; the history is
only a best-effort direct replay so the foreground terminal visibly moves to
the selected PTY. Replay strips old terminal response queries, such as device
attributes and OSC color queries, so re-showing history does not synthesize new
input into the live PTY.

A client can hand MonkeyMux its static terminal replies with
`attach --capability-hint-base64` (the `capabilityHint` field of the attach
hello). MonkeyMux answers device attribute, XTVERSION, and device-status probes
from that cache for any window no terminal is currently showing. Without it an
agent relaunched by an upgrade restore — which starts before the client
reattaches, or in a background window — never gets a reply in time and falls
back to a less capable rendering mode. Queries with no cached reply, and every
query whose answer depends on live terminal state, are still buffered and
re-delivered to the terminal on the next attach or window switch.

MonkeyMux observes 7-bit and C1 OSC title and working-directory reports for
metadata only, without stripping or rewriting those bytes from the foreground
stream. It also retains each window's OSC 9;4 progress state on the control
backchannel so the MonkeySSH window bar can show active and background work
independently. Normal reconnects and live native ACP handoffs retain progress.
Upgrade restores that relaunch CLI or shell processes start without the old
process's progress, so an idle resumed agent does not inherit a stuck busy bar.
Restored shell history also drops old OSC 9;4 markers; normal reconnect history
is unchanged. It also tracks the PTY foreground process group for snapshots,
so shell-launched tools
such as Codex can be surfaced as agent windows even when the terminal title is
only the current directory. Window replay resets stale local mouse/focus modes
before replaying history so touch input from one window is not leaked into a
plain shell prompt in another. Closing the active window selects the next open
window immediately before the old PTY is torn down.

Control clients can ask MonkeyMux to run bounded metadata commands through the
server process. This keeps app-side probes on the MonkeyMux backchannel and
uses the environment inherited by the foreground `attach` shell instead of
opening unrelated SSH exec sessions.

Theme/focus refresh requests are backchannel hints. MonkeyMux only forwards
focus transitions to recognized foreground agent TUIs; it does not inject
tmux-style palette reports into shell windows.

Live terminal identity, status, and color queries are sent to one primary
terminal only. Ordinary output and notifications still reach every attached
terminal. This prevents several real terminals from returning duplicate query
responses to the foreground program.

When `attach` finds an existing server from a different helper version, it asks
before replacing that session. Choosing no attaches to the running server
best-effort so app updates do not silently discard in-progress windows. If the
old helper predates safe shutdown support, the prompt says the update may
abandon existing windows before starting the newer helper.

`monkeyMuxVersion` in `main.go` is the single source of truth for that
comparison: it is compiled into the binary, reported in the server `hello`
frame, and checked by `attach` before it restarts anything.
`monkeymux-version.sh` derives the packaging version from that same constant so
`assets/monkeymux/manifest.json` always describes the binary it ships. Bump the
constant and run `scripts/ensure_monkeymux_assets.sh`; never edit the version in
the generated manifest by hand. The manifest and compressed binaries are
ignored build outputs. CI builds them once from the checked-out source and
fans the resulting artifact out to every Flutter package job. If the manifest
ever claims a version the binary does not report, MonkeySSH offers an "update
and restore" that `attach` then skips as a no-op, so the prompt returns on every
connect without ever applying. The targeted Flutter asset test and the
MonkeyMux Go tests both fail when generated assets drift.

The target matrix covers Linux and macOS on amd64 and arm64, plus Windows on
amd64 and arm64. On Windows the foreground path is backed by a ConPTY
(pseudo console) instead of a POSIX pty; window creation, switching, resize,
byte-relay, and the JSON control channel all work the same way. Windows has no
controlling-terminal foreground process group, so agent detection there falls
back to walking the window shell's child processes, and POSIX-only metadata
probes (process arguments, open files) degrade gracefully.

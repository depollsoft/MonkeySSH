# Muse Code

MonkeySSH recognizes Meta's `muse` CLI and the versioned `muse-bin-*` process
started by its launcher. Muse appears in host launch presets, terminal and
native-chat pickers, Agent Management, and recent project sessions.

Install Muse on a macOS, Linux, or native Windows SSH host through Agent
Management. Meta provides [a shell installer](https://dev.meta.ai/install.sh)
and [a PowerShell installer](https://dev.meta.ai/install.ps1), including x64
and ARM64 Windows builds. Run `muse login` in a terminal to sign in. Windows
installation defaults to `%LOCALAPPDATA%\Programs\muse`; MonkeySSH includes
that directory in its remote PATH. WSL over SSH follows the Linux path.

Terminal launches support additional arguments and YOLO mode. Resume uses
`muse resume <session-id>`; continuing uses `muse resume --last`. MonkeyMux
detects the actual versioned process and binds its root session log for window
identity and helper-restart recovery. MonkeyMux 0.1.203 upgrades older helpers
to include Muse support. Nested worker logs are excluded, and unchanged log
metadata is cached between discovery polls.

Recent sessions read bounded log heads, plus the local index on POSIX, under
`${XDG_DATA_HOME:-$HOME/.local/share}/muse`. Log discovery also finds sessions
created before Muse builds or refreshes its index. Titles and working directories
stay in session UI, never diagnostics or telemetry.

Native chat uses the separate community
[`@bex-co/muse-code-acp` adapter](https://github.com/bex-co/muse-code-acp), with an
on-demand fallback pinned to 0.6.0. Install the adapter from Agent Management to
avoid the on-demand download. It requires Node.js 22 or newer and Muse installed
separately. MonkeySSH checks for Muse before offering the installed adapter or
the npx fallback, honoring a configured absolute `MUSE_CODE_EXECUTABLE` file path. On Windows, MonkeySSH resolves the native executable selected by
the official launcher for the adapter, preserving an explicit
`MUSE_CODE_EXECUTABLE` override. This avoids passing `muse.cmd` to Node
subprocess APIs that require an executable. `muse serve` speaks MSP, so it
cannot be launched directly as ACP.
Chat uses the adapter's advertised capabilities for text, image attachments,
tool approvals, session history, modes, model settings, and cancellation.
Terminal YOLO flags are not passed to the separate adapter; chat permissions use
the adapter's mode and configuration controls.

Version probes set `MUSE_NO_AUTO_UPDATE=1`. Latest-version checks read Meta's
stable-channel manifest. Updates use the launcher's synchronous update mode or
Homebrew for a detected Homebrew installation.

Muse account quotas are not available through a verified API, so Agent
Management reports usage as not reported and does not display estimated rings.
The adapter also has its own capability limits and host-version compatibility
notes in its README. In particular, older terminal sessions using automatic
approval review may need to resume in the terminal instead of native chat.

Command and log contracts were checked against Muse 1.3.0-R3233.1. Local checks
covered an isolated echo session and real SDK prompts against a local test
server with adapter 0.6.0, including streamed replies, session listing, and
history loading. These checks do not exercise paid Meta model requests.

Windows integration is covered by command-generation, discovery, and PowerShell
execution tests. The PowerShell fixtures ran on macOS; a live native Windows
SSH session has not been exercised locally.

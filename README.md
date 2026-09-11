# MonkeySSH

**MonkeySSH is the SSH workspace for agentic coding.** It combines native chat windows for coding agents, a full mobile terminal, MonkeyMux/tmux remote windows, and an SFTP workspace in one app.

[![CI](https://github.com/depollsoft/MonkeySSH/actions/workflows/ci.yml/badge.svg)](https://github.com/depollsoft/MonkeySSH/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

MonkeySSH is built for the way people work with remote development environments now: connect to a box, attach to a persistent agent workspace, open the right agent as a native chat or a terminal, switch remote windows, browse files, edit config, forward a port, paste commands safely, and keep moving without a laptop.

## Why MonkeySSH

- **Native chat for coding agents.** Supported agents open in a readable conversation with streamed tool progress, permission prompts, images, attachments, slash commands, and session history. The full terminal is one tap away.
- **Built for agent workflows.** Launch presets per host, project-scoped recent-session discovery, and Agent Management to install, repair, and update agents on the host you are connected to.
- **MonkeyMux and tmux aware.** Long-running coding sessions survive reconnects and stay easy to resume. MonkeyMux sessions can be shared with a desktop terminal.
- **A real SSH workspace.** Terminal, SFTP, remote editing, snippets, key management, jump hosts, and port forwarding.
- **Mobile-first terminal UX.** Modifier keys, gestures, IME-friendly text input, paste review, shared clipboard, clickable file paths, and a window switcher that works one-handed.
- **Private by default.** Local auth, host-key verification, encrypted offline transfers, no required cloud sync, and analytics/crash reporting that stays off until you opt in.

## Built for agentic coding

MonkeySSH supports Claude Code, Copilot CLI, Codex, OpenCode, Antigravity, Cursor Agent, Pi, Hermes, OpenClaw, and Grok Build. Each one can open as a terminal window or as a native chat. Available chat controls depend on the agent's ACP adapter.

- **Native agent windows** run the agent through the Agent Client Protocol (ACP) over SSH and a persistent MonkeyMux bridge, so a conversation keeps running while the phone sleeps or the connection drops. Prompts, tool calls, plans, diffs, permission requests, images, and attachments from your photos, files, or the remote host over SFTP all render natively. Sessions can be resumed, forked, stopped, or deleted, and background completions and permission requests raise notifications.
- **Agent window mode** decides whether a launch opens native chat, a terminal window, or asks each time.
- **Recent agent session discovery** for supported CLIs, scoped to the active project so you can jump back into the right conversation.
- **Saved launch presets** with working-directory changes, MonkeyMux/tmux session names, extra arguments, YOLO mode where the agent supports it, and optional one-tap automation.
- **Agent Management** installs, repairs, and updates agent CLIs and ACP adapters on the connected host through npm, pipx, Homebrew, or the agent's own updater. It shows installed and latest versions, updates supported installations together, and flags available updates with a dot on the terminal menu. Tools that need a manual install or update are labeled.
- **Remote window navigation** for discovering sessions and windows, tracking the active pane path, launching agents into persistent workspaces, and switching windows from a bottom sheet or wide-screen sidebar.
- **IME keyboard support** so autocorrect, suggestions, swipe typing, keyboard dictation, and password-friendly prompt input behave more like a normal mobile text field, even in a terminal.
- **Safer command handling** with review prompts for suspicious pasted or auto-run shell text before it is inserted or executed.
- **Remote clipboard sync** so it is easier to move code and commands between your device and the remote machine.

## Feature overview

| Area | What you get |
| --- | --- |
| **SSH connections** | Password and key auth, jump hosts, cancellable connection attempts, multiple concurrent sessions, host organization, search, favorites, home-screen shortcuts |
| **Terminal** | xterm-256color, customizable themes, adjustable fonts, modifier keys, function keys, gestures, macros, bell, inline images and animations, tap-to-show keyboard, and IME-friendly typing with autocorrect, swipe, keyboard dictation, and password-friendly prompt input |
| **Native agent chat** | ACP conversations for supported agents with streamed responses, tool progress, plans, diffs, permission controls, images, attachments, slash commands, model and mode selectors, session history, fork, and background notifications |
| **Coding workflow** | Terminal or native window per agent, AI session picker, scoped recent session resume, MonkeyMux/tmux launch flows, multi-client MonkeyMux sessions shared with your desktop, window switcher, wide-screen sidebar, clickable file paths, shared clipboard, safer paste review |
| **Agent Management** | Install, repair, and update agent CLIs and ACP adapters on a host, installed and latest versions, update all, update indicators on the terminal menu |
| **Files** | SFTP browser, upload/download, remote file creation, direct remote text editing, syntax highlighting, path-aware navigation from terminal output |
| **Automation** | Snippets, variable-aware snippet insertion, host auto-connect commands, saved agent launch presets |
| **Networking** | Local and remote port forwards for tunnels, dashboards, previews, and remote services, live per-session forward controls, automatic proxying for detected remote listeners, an in-app browser for forwarded ports with file uploads, downloads, and site permissions, and Android device debugging over the current SSH session |
| **Keys and trust** | Generate/import/export Ed25519 and RSA keys, verify SSH host fingerprints, track trusted hosts locally |
| **Security and portability** | PIN + biometrics, auto-lock, encrypted offline transfer bundles, encrypted full-app migration packages, no required cloud sync, telemetry sharing off by default |

## MonkeySSH Pro

MonkeySSH Pro is a monthly or annual subscription. It unlocks:

- parallel native chats with instant switching and session forks
- agent launch presets and recent terminal-session discovery
- Agent Management, including automatic update checks
- auto-connect automation
- encrypted host and key transfers
- full migration import/export
- host-specific terminal themes

Core SSH, terminal, SFTP, the agent window mode choice, and one connected native chat with supported chat and tool controls stay available without Pro.

## Screenshots

Native chat and Agent Management on iPhone. Only Agent Management is badged Pro; native chat is available free.

![Native chat and Pro Agent Management](https://github.com/depollsoft/MonkeySSH/releases/download/store-assets/monkeyssh-agent-workspace.png)

[Download the full iPhone, iPad, and Android screenshot sets and demo videos](https://github.com/depollsoft/MonkeySSH/releases/tag/store-assets).

## Privacy and telemetry

MonkeySSH stores hosts, keys, snippets, transfer packages, and settings on device. SSH, SFTP, clipboard, port-forwarding, and agent conversation traffic goes directly between your device and the servers you configure.

Firebase Analytics and Crashlytics are compiled only into telemetry-enabled builds and stay off until you opt in. Opt-in analytics uses coarse allowlisted events for broad feature usage, setup funnels, connection reliability, SFTP transfer outcomes, remote window usage, and agent launch/session-history usage. It excludes hostnames, usernames, IP addresses, commands, terminal output, file paths, file names, tmux session/window names, clipboard contents, passwords, passphrases, private keys, tokens, and raw SSH/SFTP/tmux data.

## Platforms

Store releases target iPhone, iPad, and Android. The app is built with Flutter and the repository carries desktop and web targets, but the release pipeline and store metadata cover only the mobile apps.

## Development

```bash
./scripts/ensure_monkeymux_assets.sh
flutter pub get
dart run build_runner build
flutter analyze
dart format .
flutter test
```

MonkeyMux executables are generated build outputs rather than Git-tracked
files. The ensure script cross-compiles all supported remote-host targets with
the pinned Go toolchain and skips the work when its inputs have not changed.

### Android builds

Use **JDK 17** for Android and Gradle work in this repo:

```bash
export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
```

### Integration and manual testing

```bash
flutter test integration_test
```

To test tmux navigation against a real SSH target:

```bash
./scripts/setup_tmux_test_env.sh
# ... run the app and connect to localhost ...
./scripts/setup_tmux_test_env.sh teardown
```

For deterministic ACP validation over a real SSH exec channel and persistent
MonkeyMux bridge, see [ACP manual testing](docs/manual_testing_acp.md).

## Deployment

Release automation, app variants, store setup, and signing details live in [docs/deployment.md](docs/deployment.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE).

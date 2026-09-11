# Repository notes for agents

- Branch from `main` and open PRs against `main`; this repository does not use a `develop` branch.
- Use JDK 17 for Android/Gradle builds in this repo. JDK 25 fails in the Android/Kotlin toolchain with `IllegalArgumentException: 25.0.1`.
- On macOS, set `JAVA_HOME="$(/usr/libexec/java_home -v 17)"` before running `flutter build ...` or `./gradlew ...` for Android.

## iOS provisioning profiles after capability changes

After enabling a new App ID capability in the Apple Developer portal (e.g. Access WiFi Information, Push Notifications, App Groups), the existing provisioning profiles in the match git repo are stale — they don't include the new entitlement, so signing with the new entitlements file in `ios/Runner/Runner.entitlements` will fail.

Refresh once via the **Regenerate iOS Provisioning Profiles** GitHub Actions workflow (`workflow_dispatch`), or run locally:

```bash
cd ios
bundle exec fastlane regenerate_profiles            # both Private + Production
bundle exec fastlane regenerate_profiles scheme:Private
```

For Firebase App Distribution, select `profile-type: adhoc` in that workflow,
or run `bundle exec fastlane regenerate_profiles scheme:Private type:adhoc`.
The default `appstore` profile type is for TestFlight and App Store builds.
Preview distribution intentionally uses readonly match profiles; refresh them
through this maintenance workflow when required.

Local Xcode builds with automatic signing pick up the new entitlement on next build without any extra step (Xcode regenerates dev profiles via the developer portal automatically).

## MonkeyMux Go tests on a Windows dev machine

CI runs the MonkeyMux Go suite on both Linux and Windows (the `go-test` job), because the two platforms cover disjoint sets: most of the suite is `//go:build !windows` and needs `creack/pty` plus the `unixPty` type, while the ConPTY backend tests are `//go:build windows`.

On a Windows workstation `go test ./...` in `remote/monkeymux` therefore only runs the ~17 portable + Windows-tagged tests. To run the full Linux set locally, use WSL:

```powershell
wsl --install Ubuntu-26.04 --no-launch   # WSL2 kernel ships with Windows; a clean machine may still require a reboot first
```

Then, once the distro is available (after a reboot if Windows prompts for one), install Go (the module needs the toolchain in `go.mod`, not the older apt package) and clone into the **Linux** filesystem:

```bash
curl -sSLO https://go.dev/dl/go1.26.5.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.26.5.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' | sudo tee /etc/profile.d/go.sh
sudo apt-get install -y build-essential   # cgo, needed for `go test -race`

git clone --depth 1 --single-branch file:///mnt/c/path/to/MonkeySSH ~/MonkeySSH
cd ~/MonkeySSH/remote/monkeymux && go test -race ./...
```

**Do not run the suite over `/mnt/c`.** The repository has no `.gitattributes` and Git for Windows checks out CRLF, so `gofmt -l` flags every file. `os.Symlink` also fails on `/mnt/c` without Developer Mode, and `TestAssignCopilotSessionsByWorkingDirectoryNormalizesPaths` has a `t.Skipf` guard, so that coverage is silently lost rather than reported. Cloning into the Linux filesystem gives an LF checkout and working symlinks. A local `file://` clone avoids needing GitHub credentials in the distro; use `--depth 1` because `.git` is several GB.

## Manual testing: tmux navigation

The tmux/MonkeyMux navigator feature requires a real SSH connection to a host running tmux or MonkeyMux. Use the setup script to create a local tmux test environment:

```bash
# Set up local SSH + tmux test environment
./scripts/setup_tmux_test_env.sh

# Run the app in a simulator
flutter run --device-id <simulator-id>

# When done, tear down
./scripts/setup_tmux_test_env.sh teardown
```

The script generates a temporary SSH key, authorizes it for localhost, and creates a tmux session with 3 windows. Follow the on-screen instructions to add a host in the app and test the navigator. For MonkeyMux-specific validation, prefer a host configured with `remoteMuxBackend: monkeyMux` and verify window switching, new-window creation, recent agent sessions, alerts, and session-end recovery.

## Manual testing: Android emulator local SSH

For Android emulator validation against the Mac host, use `10.0.2.2` from the emulator to reach services bound to `127.0.0.1` on macOS. Run the private flavor with JDK 17:

```bash
JAVA_HOME="$(/usr/libexec/java_home -v 17)" \
  flutter run -d emulator-5554 --debug --flavor private -t lib/main.dart
```

A no-auth Paramiko SSH server is useful for quick simulator testing, but make it behave like the Mac default SSH environment:

- Use `/bin/zsh` for both shell channels and exec probes (`/bin/zsh -lc <command>`).
- Set `SHELL=/bin/zsh`, `TERM=xterm-256color`, `COLORTERM=truecolor`, and include Homebrew in `PATH` (`/Users/depoll/homebrew/bin`, `/opt/homebrew/bin`, `/usr/local/bin`).
- Do not launch `bash --noprofile --norc`; it hides Homebrew tools and does not match a normal Mac SSH session.
- Build a clean environment instead of copying the agent process environment; inherited variables such as `TMUX` make TUIs think they are running inside tmux and can change their terminal protocol behavior.
- Honor SSH `pty-req` and `window-change` dimensions by applying them to the local PTY with `TIOCSWINSZ`; otherwise TUIs such as Codex can think the terminal has an invalid size (for example 65,535 rows) and render a blank viewport.
- For opencode system-theme testing, create a temp HOME with `.config/opencode/tui.json` containing `{"theme":"system"}`.

In the app, create or seed a host with hostname `10.0.2.2`, the test server port (for example `2223`), the test username, and no password/key for no-auth. Leave auto-connect fields empty unless you specifically need to test Pro-gated auto-connect behavior. To start a TUI without fragile ADB text input, put a temporary zsh startup command such as `exec opencode --pure` in the test HOME `.zshrc`, then remove it when done.

Useful emulator commands:

```bash
ADB="$HOME/Library/Android/sdk/platform-tools/adb"
"$ADB" shell cmd uimode night no      # light mode
"$ADB" shell cmd uimode night yes     # dark mode
"$ADB" exec-out screencap -p > /tmp/monkeyssh.png
```

ADB text injection is IME-dependent. Prefer separate key events for spaces (`adb shell input keyevent SPACE`) rather than relying on escaped spaces in `adb shell input text`.

### Key gotchas for tmux over SSH exec channels

- **PATH**: SSH exec channels use a minimal PATH that excludes Homebrew. The tmux service sources `~/.profile`, `~/.bash_profile`, and `~/.zprofile` before running commands.
- **Format strings**: tmux's `-F` option does **not** interpret `\t` as tab. Use ASCII Unit Separator (`\x1f`) delimiters instead so window names and titles can still contain `|`.
- **Environment variables**: Exec channels don't share the interactive shell's environment. Use `tmux list-sessions` / `tmux display-message` instead of `echo $TMUX`.

## Store assets, screenshots, and demo videos

Store listing **copy** lives under `ios/fastlane/metadata-*` and `android/fastlane/metadata-*` and stays in git. Keep production and private/beta copy aligned while preserving their distinct app names and beta wording. Validate text limits with:

```bash
python3 scripts/validate_app_store_metadata.py
python3 scripts/validate_play_store_metadata.py
```

Regenerated store **media** (screenshots, App Previews, demo videos) is not committed. Publish it with `scripts/store_assets.sh publish` to the rolling `store-assets` GitHub Release; CI re-hosts the archive as Actions artifacts and Sync Store Metadata / production releases download it before Fastlane upload. Restore locally with `scripts/store_assets.sh download`.

The screenshot set has eight scenes per device. Only entirely Pro-only features get screenshot badges. Native chat is available free, so its screenshots stay unbadged. Agent Management has a Pro caption outside the real app capture. Agent Management captures live version checks only, without installing or updating the developer's tools.

Regenerate screenshots with `python3 scripts/generate_store_screenshots.py [ios|android|both]` and short demo videos with `python3 scripts/generate_store_demo_videos.py [ios|android|both]`, then publish:

```bash
./scripts/store_assets.sh publish --generate all --platform both --sync
```

For a guided end-to-end release (copy + media publish + optional ship), use the repo skill `/prepare-release` (`.agents/skills/prepare-release/SKILL.md`).


Both generators use the normal app, a temporary local SSH server, a live MonkeyMux workspace, real Copilot CLI and Claude Code panes, and seeded release-demo data. They must fail rather than substituting mocked captures when that live workspace cannot be created. Each device is recorded once and composed into store-compliant deliverables: App Store **app previews** are full-screen native app captures at the exact device slot resolution (iPhone 886x1920 at `ios/fastlane/app-previews/en-US/iphone_67_1.mov`, iPad 1200x1600 at `ipad_13_1.mov`) with fading caption overlays and a silent audio track, because App Store Connect validates resolution at upload; the **Google Play preview** is a 16:9 landscape branded promo at `store/demo-videos/google-play/monkeyssh-google-play-promo.mp4` (uploaded to YouTube and referenced by URL); and the portrait **branded canvas** is kept for ads under `store/demo-videos/ads/`. The demo flow walks Claude Code, the MonkeyMux window switcher, OpenCode, a real image paste into Copilot CLI, and a Copilot prompt against that screenshot. Copilot scenes must show the CLI displaying the image inline. Do not enable Copilot streamer mode or rename sessions to placeholders; the harness temporarily forces streamer mode off and restores the prior setting. The MonkeyMux window scene should show the current supported agent family: Copilot CLI, Claude Code, Codex, OpenCode, Antigravity, Cursor Agent, Pi, Hermes, and OpenClaw. Validate everything with `python3 scripts/validate_store_demo_videos.py all` (per-slot resolution, 15-30s duration, audio track on Apple previews, and live-region scene progression).

## Diagnostics logging

Preview and beta/internal builds expose an in-memory diagnostics log in Settings > Diagnostics. Users can tap **Copy diagnostics log** and paste the sanitized text into an issue or chat for troubleshooting.

When adding diagnostics, use `DiagnosticsLogService.instance` (or `diagnosticsLogServiceProvider` in UI code) and keep entries structured with a short category, short event name, and primitive fields. The logger is gated to diagnostics-enabled preview/beta builds and maintains a bounded ring buffer.

Never log secrets or user content. Do not log hostnames, usernames, passwords, passphrases, private keys, tokens, raw commands, terminal output, tmux window/session names, window titles, working directories, file paths, clipboard contents, or raw SSH/tmux stream lines. Prefer safe metadata such as connection ID, host ID, booleans, counts, durations, enum states, retry attempts, error types, exit statuses, and sanitized event categories.

For tmux control-mode logging, log the control marker category (for example `subscription_changed` or `window_add`) and counts/timing only. Do not log the full control-mode line because it can include pane titles, window names, paths, and command output.

## Firebase telemetry

Firebase Analytics and Crashlytics are opt-in and gated by the `FLUTTY_FIREBASE_ENABLED` compile flag. Native Firebase config files are not committed; CI injects the flavor-specific files from secrets.

When adding telemetry, use `telemetryServiceProvider` and keep every event and parameter allowlisted, coarse, and primitive. Never log hostnames, usernames, IP addresses, commands, terminal output, file paths, file names, tmux session/window names, clipboard contents, passwords, passphrases, private keys, tokens, raw SSH/SFTP/tmux streams, or arbitrary user-provided strings. Telemetry failures must stay best-effort and must not block app behavior or prevent opt-out/delete-unsent-reports paths from running.

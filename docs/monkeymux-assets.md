# MonkeyMux build assets

MonkeySSH embeds MonkeyMux helpers for Linux, macOS, and Windows on amd64 and
arm64 so it can install the matching helper over the existing SSH connection.
The compressed executables and their checksum manifest are generated build
outputs and are intentionally ignored by Git.

## Local builds

Generate or refresh the assets before `flutter pub get`, testing, or packaging:

```bash
./scripts/ensure_monkeymux_assets.sh
```

The script fingerprints the MonkeyMux source, pinned Go toolchain, ConPTY
inputs, and packaging tools. It exits without rebuilding when all outputs are
present and the fingerprint matches. Force a clean rebuild when diagnosing the
packaging process:

```bash
./scripts/ensure_monkeymux_assets.sh --force
```

The exact packaging toolchain is declared by the `toolchain` directive in
`remote/monkeymux/go.mod`. Builds disable VCS stamping, strip local paths, and
use that pinned Go standard library for timestamp-free gzip output so the same
source and toolchain produce the same payloads on every supported build host.

## CI and releases

CI builds `assets/monkeymux/` once per workflow run and uploads it as a
short-lived workflow artifact. Flutter analysis, tests, and platform package
jobs download that artifact before running `flutter pub get`. The reusable
build-and-deploy workflow follows the same process for release and preview
source builds; jobs that reuse an already packaged AAB or IPA do not regenerate
MonkeyMux.

The workflow artifact is only an internal build handoff. The final Flutter
application still contains all six helpers, preserving installation on remote
hosts without a separate web download.

## Windows host cleanup

Windows helpers install under
`~/.monkeyssh/bin/monkeymux/<version>/<platform>/<sha256>/monkeymux.exe`, so
updating does not require deleting an executable used by a running helper.
After a verified install or reuse updates the managed command launcher, the
installer records the build's use in `.last-used` and prunes older builds for
that Windows platform, including the legacy layout without a checksum folder.

Cleanup keeps the current build, builds installed or used within seven days,
and executables Windows refuses to delete because they are running or locked.
Locked copies are retried on a later connection. It skips linked paths and
unrecognized files, removes only empty directories, and never blocks a
connection if cleanup fails. Custom launchers are preserved and skip cleanup.
This policy applies to Windows hosts; POSIX version directories are retained.

## One-time Git history cleanup

Removing the generated files in an ordinary commit stops future repository
growth but does not remove their existing blobs. After this change is merged,
an administrator can reclaim that space with a coordinated history rewrite.
Announce a maintenance window first: every rewritten commit gets a new ID,
open branches must be rebased or recreated, and existing clones should be
replaced afterward.

From a disposable mirror clone with `git-filter-repo` installed:

```bash
git clone --mirror https://github.com/depollsoft/MonkeySSH.git MonkeySSH-rewrite.git
cd MonkeySSH-rewrite.git
git filter-repo \
  --path-glob 'assets/monkeymux/bin/**' \
  --path assets/monkeymux/manifest.json \
  --invert-paths
git remote add origin https://github.com/depollsoft/MonkeySSH.git
git push --force --all origin
git push --force --tags origin
```

Before pushing, inspect the rewritten refs and verify that
`remote/monkeymux/conpty/` is still present. Branch protection may need a
temporary administrative exception. Do not use `git push --mirror` against
GitHub because mirror clones can contain server-owned pull-request refs that
GitHub rejects. GitHub can retain unreachable objects for a grace period, so
the hosted size may not fall immediately.

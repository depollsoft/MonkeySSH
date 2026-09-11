---
name: prepare-release
description: Type `/prepare-release` (optionally with version, channel, or flags) to walk MonkeySSH production release prep end-to-end — listing copy, regenerated store media publish, validation, and shipping a GitHub Release / Actions release. Use when the user wants to prepare, cut, or ship a store release.
user-invocable: true
argument-hint: "[vX.Y.Z] [--channel production|internal] [--skip-media] [--skip-copy] [--media-only] [--copy-only] [--ship] [--no-ship] [--platform both|ios|android] [--sync]"
---

# Prepare MonkeySSH release

Use this skill when the user types `/prepare-release` or asks to prepare/cut/ship a production store release.

Do the work. Do not only print the checklist unless the user asks for a dry run.

## Arguments

Parse free text after `/prepare-release`:

| Token | Meaning | Default |
| --- | --- | --- |
| `vX.Y.Z` / `X.Y.Z` | Exact app version to ship | Ask only if shipping and version is unclear; otherwise let `release.yml` choose the next App Store patch from `pubspec.yaml` |
| `--channel production\|internal` | Release channel | `production` |
| `--platform both\|ios\|android` | Store media + ship platforms | `both` |
| `--skip-media` | Do not regenerate or publish screenshots/videos | off |
| `--skip-copy` | Do not review/update listing copy | off |
| `--media-only` | Only regenerate/publish store media (no ship) | off |
| `--copy-only` | Only listing-copy PR work (no media, no ship) | off |
| `--ship` | Create GitHub Release / dispatch Release after prep | ask if unspecified |
| `--no-ship` | Stop after prep/publish; do not cut the release | off |
| `--sync` | After media publish, trigger Sync Store Metadata | on when media is published |
| `--dry-run` | Print the plan and commands only | off |

If flags conflict (`--ship` + `--no-ship`, `--media-only` + `--copy-only`), ask one clarifying question.

## Non-negotiables

1. **Branch from `origin/main`** after fetch unless the user says otherwise. Open PRs against `main`.
2. **Never commit regenerated store media** (screenshots, App Previews, demo videos). Publish with `scripts/store_assets.sh`.
3. Listing **copy**, feature graphics, and app icons stay in git.
4. Generation needs a real Mac environment: Xcode simulators and/or a running Android emulator, plus authenticated `copilot` and `claude` CLIs and Python Pillow.
5. If live SSH/MonkeyMux capture cannot be created, **stop** — do not substitute mocks.
6. Prefer Conventional Commits. Include required commit trailers when this environment specifies them.
7. Use JDK 17 for any local Android build (`JAVA_HOME="$(/usr/libexec/java_home -v 17)"`).

## Required reading (skim, then act)

Before editing or generating, read:

- `docs/deployment.md` — release + metadata workflows
- `docs/store-assets-prompt.md` — media quality bar and banned scenes
- `AGENTS.md` store-assets section
- Current listing copy under:
  - `ios/fastlane/metadata-production/`
  - `ios/fastlane/metadata-private/`
  - `android/fastlane/metadata-production/android/en-US/`
  - `android/fastlane/metadata-private/android/en-US/`
- `pubspec.yaml` version
- Recent user-facing changes since the last GitHub Release (`gh release view --json tagName,publishedAt` + `git log`)

## End-to-end workflow

Copy this checklist and keep it updated while running:

```text
Prepare-release progress
- [ ] 0. Parse args + confirm ship intent
- [ ] 1. Repo hygiene (fetch main, clean worktree/PR branch)
- [ ] 2. Decide what changed since last release
- [ ] 3. Listing copy updates (if needed)
- [ ] 4. Validate listing copy
- [ ] 5. Regenerate store media (if needed)
- [ ] 6. Validate store media
- [ ] 7. Publish store-assets release (+ optional metadata sync)
- [ ] 8. Open/merge copy PR if any
- [ ] 9. Ship GitHub Release / dispatch Release workflow
- [ ] 10. Report URLs + remaining manual steps (YouTube Play promo if refreshed)
```

### 0) Confirm intent

- If neither `--ship` nor `--no-ship`/`--media-only`/`--copy-only` was given, ask whether to cut the production release after prep.
- Default recommendation: prepare copy + media, then ship production for both platforms.

### 1) Repo hygiene

```bash
git fetch origin main
git status --short
git rev-parse --show-toplevel
```

- Do release prep on a dedicated branch from `origin/main` when making copy/docs commits (e.g. `release/prepare-vX.Y.Z` or `chore/store-copy-<date>`).
- If the checkout is dirty with unrelated work, create a sibling worktree under `*.worktrees/` instead of mixing changes.
- Confirm `scripts/store_assets.sh` exists and is executable. If missing, the store-assets CI PR may not be merged yet — stop and say so.

### 2) Decide what needs refreshing

Inspect product changes since the last release:

```bash
gh release list --limit 5
git log --oneline "$(gh release view --json tagName --jq .tagName 2>/dev/null || echo origin/main)~1..origin/main" -- lib/ ios/fastlane/metadata-production android/fastlane/metadata-production docs/PRODUCT.md PRODUCT.md README.md
```

Refresh media when UI, onboarding, MonkeyMux/agent surfaces, or store-facing flows changed materially. Skip media with `--skip-media` only when the user confirms the existing `store-assets` release is still accurate.

```bash
gh release view store-assets --json publishedAt,url,assets
```

### 3) Listing copy (git-managed)

Skip if `--skip-copy` or `--media-only`.

Update only when needed:

- iOS: `ios/fastlane/metadata-*/en-US/{name,subtitle,description,keywords,release_notes,privacy_url,support_url}.txt`
- Android: `android/fastlane/metadata-*/android/en-US/{title,short_description,full_description}.txt` and `changelogs/default.txt`
- Keep production and private/beta aligned; preserve distinct names (`MonkeySSH` vs `MonkeySSH β`) and beta wording
- Release notes should be concrete and user-facing, not a raw commit dump
- Do **not** hand-edit generated Play `icon.png` (CI regenerates from `assets/icons/`)

### 4) Validate listing copy

```bash
python3 scripts/validate_app_store_metadata.py both
python3 scripts/validate_play_store_metadata.py both
```

Fix failures before continuing.

### 5) Regenerate store media (not committed)

Skip if `--skip-media` or `--copy-only`.

Prereqs to verify first:

```bash
command -v flutter && command -v python3 && command -v copilot && command -v claude
python3 - <<'PY'
from PIL import Image  # noqa: F401
print('Pillow OK')
PY
# iOS
xcrun simctl list devices available | head
# Android (if platform includes android)
adb devices
```

Generate:

```bash
platform=both  # or ios|android from --platform
if [ "$platform" != both ]; then
  ./scripts/store_assets.sh download
fi
python3 scripts/generate_store_screenshots.py "$platform"
python3 scripts/generate_store_demo_videos.py "$platform"
```

Quality bar (fail the run if violated — see `docs/store-assets-prompt.md`):

- Real app + live temporary SSH/MonkeyMux workspace
- Copilot scenes show an image inline (no streamer mode / placeholder session renames)
- MonkeyMux selector shows current agent family: Copilot CLI, Claude Code, Codex, OpenCode, Antigravity, Cursor Agent, Pi, Hermes, and OpenClaw
- No port-forward/subscription/checkout as primary scenes unless product direction changed
- No secrets, local private paths, API keys, crash dialogs, empty shells

### 6) Validate store media

```bash
python3 scripts/validate_store_screenshots.py "$platform"
# videos/app previews:
if [ "$platform" = both ]; then
  python3 scripts/validate_store_demo_videos.py all
else
  python3 scripts/validate_store_demo_videos.py "$platform"
fi
```

### 7) Publish media to CI artifacts / rolling release

**Do not `git add` screenshots, `.mov`, or demo `.mp4` files.**

```bash
# Publish archive to GitHub Release tag store-assets and dispatch publish-store-assets.yml
./scripts/store_assets.sh publish --platform "$platform" --sync
```

If media was generated in this run already, do **not** pass `--generate` again unless you intentionally want a second capture.
For single-platform generation, restore the baseline in step 5 before capturing.
Publishing existing local files validates both platforms; missing complementary
media fails validation instead of restoring over fresh captures.

Confirm:

```bash
gh release view store-assets --json url,publishedAt,assets --jq '{url,publishedAt,assets:[.assets[].name]}'
gh run list --workflow publish-store-assets.yml --limit 3
```

Optional restore check:

```bash
./scripts/store_assets.sh download
```

### 8) Commit copy-only changes + PR

If listing copy/docs changed:

```bash
git status --short
git add ios/fastlane/metadata-production ios/fastlane/metadata-private \
  android/fastlane/metadata-production android/fastlane/metadata-private \
  docs  # only if docs were intentionally updated
# never add:
# ios/fastlane/screenshots ios/fastlane/app-previews store/demo-videos
# android/.../images/*Screenshots

git commit -m "chore: refresh store listing copy for release"
git push -u origin HEAD
gh pr create --base main --title "chore: refresh store listing copy for release" --body "..."
```

If shipping immediately, wait for the copy PR to merge (or merge it if the user wants you to) so `main` has the text the release will upload.

### 9) Ship

Skip if `--no-ship`, `--media-only`, or `--copy-only`.

#### Production (default)

Preferred: publish a GitHub Release with tag `vX.Y.Z`:

```bash
version=X.Y.Z  # from args or agreed version
gh release create "v${version}" --generate-notes --title "v${version}"
```

That triggers `release.yml` production deploy for iOS + Android. The workflow:

- resolves/prepares the App Store version
- builds production
- downloads latest `store-assets`
- uploads metadata, screenshots, App Previews, and binaries
- submits for review / completed Play rollout per `docs/deployment.md`

Alternative without a GitHub Release tag:

```bash
gh workflow run release.yml \
  -f channel=production \
  -f ios=true \
  -f android=true \
  -f version=X.Y.Z   # optional override; blank lets iOS auto-pick patch
```

#### Internal only

```bash
gh workflow run release.yml \
  -f channel=internal \
  -f ios=true \
  -f android=true
```

Watch:

```bash
gh run list --workflow release.yml --limit 5
gh run watch
```

### 10) Final report

Always tell the user:

1. What was refreshed (copy / screenshots / videos / none)
2. `store-assets` release URL and publish-store-assets run URL
3. Copy PR URL (if any) and merge state
4. Release tag / release.yml run URL
5. Manual leftovers:
   - If the Google Play promo MP4 changed, it must be uploaded to YouTube (public/unlisted, ads off) and the Play Console listing video URL updated — Fastlane does not upload Play videos
   - App Review may still need human attention in App Store Connect / Play Console

## Dry run mode

If `--dry-run`, print the exact commands for the chosen path and stop without generating, publishing, committing, or shipping.

## Common paths (shortcuts)

### Full production release

```text
/prepare-release --ship
```

Agent runs copy review → media regen/publish → merge copy if needed → `gh release create vX.Y.Z`.

### Media refresh only

```text
/prepare-release --media-only --platform both --sync
```

### Copy only

```text
/prepare-release --copy-only
```

### Ship using already-published media

```text
/prepare-release v1.2.3 --skip-media --skip-copy --ship
```

## Failure handling

- Missing `copilot` / `claude` / simulator / emulator / Pillow: stop with install/start instructions; do not fake assets.
- `scripts/store_assets.sh publish` fails auth: ensure `gh auth status` has `repo` + `workflow` scopes.
- Validators fail: fix sources and re-run validators; do not publish known-bad media.
- Release workflow fails after publish: media can stay; re-run `release.yml` without regenerating unless assets were wrong.
- Never force-push or rewrite release tags unless the user explicitly demands it.

## Reference commands

```bash
# package/publish/download media
./scripts/store_assets.sh present
./scripts/store_assets.sh package
./scripts/store_assets.sh publish --generate all --platform both --sync
./scripts/store_assets.sh download

# validators
python3 scripts/validate_app_store_metadata.py both
python3 scripts/validate_play_store_metadata.py both
python3 scripts/validate_store_screenshots.py both
python3 scripts/validate_store_demo_videos.py all

# ship
gh release create vX.Y.Z --generate-notes
gh workflow run release.yml -f channel=production -f ios=true -f android=true
gh run list --workflow release.yml --limit 5
```

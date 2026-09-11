# Deployment Guide

This guide covers automated deployment to TestFlight, Play Store internal
testing, Firebase App Distribution, and public store releases.

## App Variants

| Variant | Android Package | iOS Bundle ID | Display Name | Purpose |
| --------- | ---------------- | --------------- | -------------- | --------- |
| **private** | `xyz.depollsoft.monkeyssh.private` | `xyz.depollsoft.monkeyssh.private` | MonkeySSH β | PR previews, internal testing |
| **production** | `xyz.depollsoft.monkeyssh` | `xyz.depollsoft.monkeyssh` | MonkeySSH | App Store / Play Store releases |

Both variants install side-by-side on the same device.

## Prerequisites

### Apple Developer Account

1. Log in to [App Store Connect](https://appstoreconnect.apple.com/)
2. Create **two** apps:
   - Bundle ID: `xyz.depollsoft.monkeyssh` — name: "MonkeySSH"
   - Bundle ID: `xyz.depollsoft.monkeyssh.private` — name: "MonkeySSH β"
3. Create an **App Store Connect API Key**:
   - Go to Users and Access → Integrations → App Store Connect API
   - Generate a new key with "App Manager" role
   - Download the `.p8` file (you can only download it once)
   - Note the **Key ID** and **Issuer ID**

### Google Play Developer Account

1. Log in to [Google Play Console](https://play.google.com/console)
2. Create **two** apps:
   - Package: `xyz.depollsoft.monkeyssh` — name: "MonkeySSH"
   - Package: `xyz.depollsoft.monkeyssh.private` — name: "MonkeySSH β"
3. Create a **Service Account**:
   - Go to Setup → API access
   - Create a new service account in Google Cloud Console
   - Grant "Service Account User" role
   - Create and download a JSON key
   - Back in Play Console, grant the service account access with "Release manager" permissions

### Firebase App Distribution

Every push to a same-repository pull request, plus app changes pushed to
`main`, distributes the **private** flavor to Firebase App Distribution testers
(see the Firebase Distribution workflow below). Pull requests build unsigned
artifacts without deployment credentials; a trusted `workflow_run` validates
and distributes the immutable artifacts. Fork pull requests are skipped. One-time
setup in the [Firebase console](https://console.firebase.google.com/) for
project `monkeyssh`:

1. Open **App Distribution** and press **Get started** for both private apps
   (`xyz.depollsoft.monkeyssh.private` on Android and iOS)
2. Create a tester **group** with alias `testers` (or set the
   `FIREBASE_TESTER_GROUPS` repository *variable* to a comma-separated list of
   your group aliases) and add tester emails to it
3. Create a **service account** in the Google Cloud console for the Firebase
   project, grant it the **Firebase App Distribution Admin** role, and download
   a JSON key — this becomes the `FIREBASE_SERVICE_ACCOUNT_JSON` secret
4. **iOS only:** App Distribution installs ad hoc builds, so every tester
   device UDID must be registered in the Apple Developer portal. Have testers
   register through the invite link (Firebase collects the UDID), then add the
   device in the developer portal.

   Apple requires **at least one registered device** before it will issue an
   ad hoc profile, so register a device before the first firebase deploy. The
   first deploy then creates the `AdHoc_*` match profiles automatically,
   reusing the existing distribution certificate. Later device registrations
   are picked up automatically too (`force_for_new_devices`), so no manual
   step is normally needed. To force a refresh anyway:

   ```bash
   cd ios
   bundle exec fastlane regenerate_profiles type:adhoc
   ```

### Fastlane Match (iOS Certificates)

1. Create a **private Git repository** for storing certificates (e.g., `github.com/yourorg/certificates`)
2. Initialize match locally:

   ```bash
   cd ios
   bundle exec fastlane match init
   ```

3. Generate certificates for every shipped iOS bundle ID, including the Live Activity extension:

    ```bash
    bundle exec fastlane match appstore --app_identifier xyz.depollsoft.monkeyssh
    bundle exec fastlane match appstore --app_identifier xyz.depollsoft.monkeyssh.private
    bundle exec fastlane match appstore --app_identifier xyz.depollsoft.monkeyssh.ConnectionStatusLiveActivity
    bundle exec fastlane match appstore --app_identifier xyz.depollsoft.monkeyssh.private.ConnectionStatusLiveActivity
    ```

### Android Upload Keystore

Generate a release keystore:

```bash
keytool -genkey -v \
  -keystore upload-keystore.jks \
  -keyalg RSA \
  -keysize 2048 \
  -validity 10000 \
  -alias upload
```

Signed Android release builds require `android/app/key.properties` (see `key.properties.example`) and the real upload keystore. Debug builds for local development do not require release signing material.

## GitHub Secrets

Configure these secrets in your repository settings (Settings → Secrets and variables → Actions):

### iOS / Apple

| Secret | Description | How to get it |
| -------- | ------------- | --------------- |
| `MATCH_GIT_URL` | Private Git repo URL for certificates | `https://github.com/yourorg/certificates.git` |
| `MATCH_PASSWORD` | Encryption password for match | Set during `fastlane match init` |
| `MATCH_GIT_BASIC_AUTHORIZATION` | Base64-encoded `username:PAT` | `echo -n "username:ghp_token" \| base64` |
| `APP_STORE_CONNECT_API_KEY_ID` | API Key ID | From App Store Connect → Integrations |
| `APP_STORE_CONNECT_API_ISSUER_ID` | API Issuer ID | From App Store Connect → Integrations |
| `APP_STORE_CONNECT_API_KEY_CONTENT` | API Key content (raw .p8 PEM) | Contents of `AuthKey_XXXXXX.p8` file |

### Android / Google Play

| Secret | Description | How to get it |
| -------- | ------------- | --------------- |
| `ANDROID_KEYSTORE_BASE64` | Base64-encoded keystore | `base64 -i upload-keystore.jks` |
| `ANDROID_KEY_ALIAS` | Keystore key alias | Set during `keytool -genkey` |
| `ANDROID_KEY_PASSWORD` | Key password | Set during `keytool -genkey` |
| `ANDROID_STORE_PASSWORD` | Keystore password | Set during `keytool -genkey` |
| `PLAY_STORE_SERVICE_ACCOUNT_JSON` | Service account JSON key content | Downloaded from Google Cloud Console |

### Firebase App Distribution

| Secret | Description | How to get it |
|--------|-------------|---------------|
| `FIREBASE_SERVICE_ACCOUNT_JSON` | Service account JSON key with the Firebase App Distribution Admin role | Google Cloud Console for the `monkeyssh` Firebase project |

Optionally set the `FIREBASE_TESTER_GROUPS` repository **variable** (not a
secret) to override the default `testers` group alias.

## Workflows

### PR Preview (`preview.yml`)

Triggered automatically on PRs to `main` and `develop`. Builds the **private** flavor and:

- **iOS**: Builds an unsigned release IPA for `/deploy` promotion to TestFlight
- **Android**: Builds an unsigned release AAB plus a debug-signed APK for direct download in the PR comment

When `/deploy` promotes a PR preview, it reuses the existing unsigned preview artifacts when their build number is still ahead of the latest private deploy. If a newer private build has already been deployed, the workflow automatically rebuilds with a fresh build number before uploading to TestFlight and Play internal.

### Deploy Private (`deploy-private.yml`)

Triggered on push to `main`. Builds the **private** flavor and deploys to:

- **iOS**: TestFlight (MonkeySSH β)
- **Android**: Play Store internal testing track

This ensures TestFlight and Play Store internal testing always reflect the latest `main`.

### Firebase Distribution (`firebase-distribution.yml`)

Triggered after each successful **PR Preview** and **PR Preview iOS** run, and
whenever a push to `main` touches app code. PR code runs only in the
unprivileged preview workflows. The trusted default-branch workflow verifies
that the artifact SHA is still the PR head, checks out trusted deployment code,
then signs and uploads the immutable artifact using the **private** flavor:

- **iOS**: ad hoc signed IPA (match `adhoc` profiles; tester devices must be
  registered in the Apple Developer portal)
- **Android**: release-signed universal APK (no Play account link required)

Release notes carry the associated PR number and title, source branch, version,
and latest commit SHA and subject. Direct pushes without an associated PR retain
the branch and commit details. Main distributions serialize because they may
refresh the shared match repository. PR artifacts use existing ad hoc profiles
in read-only mode, so each trusted artifact consumer can run independently.
Stale PR artifacts are rejected before signing. TestFlight and Play
uploads are unaffected: `/deploy` on a PR still promotes to TestFlight + Play
internal, and pushes to `main` still run Deploy Private.

### Release (`release.yml`)

Triggered by:

- Creating a GitHub Release (tag format: `vX.Y.Z`)
- Manual workflow dispatch

Published GitHub releases deploy both platforms to production using the tag as
the exact version. Manual runs provide:

- **Channel**: `production` (default) or `internal`
- **Platforms**: independent iOS and Android toggles, both enabled by default
- **Version**: optional exact `x.y.z` override

For production iOS releases without an override, the workflow selects the next
available patch version from App Store Connect. It uploads metadata,
screenshots, App Preview videos, and the binary together, submits the version
for review, and releases it automatically after approval. Starting another
release while a review is active cancels that review and advances the App Store
version before uploading the replacement release.

Production Android releases upload the listing and AAB to the Play production
track as a completed rollout, send the changes for Google review, and publish
automatically after approval. Internal runs upload to TestFlight and Play
internal without changing the production store listings.

Android listing icons are managed as Play Store metadata; iOS App Store icons
come from the submitted app build's asset catalog.

Android release workflows fail early if the signing secrets or local `android/app/key.properties` configuration are missing or incomplete. This prevents release builds from silently falling back to the debug keystore.

### Sync Metadata (`sync-metadata.yml`)

Triggered automatically on pushes to `main` that touch repository-managed store
**copy**/icons, and can also be run manually to sync store metadata without a
new build. Useful for updating app descriptions, Android listing icons, or
other listing text.

Regenerated screenshots, iOS App Preview videos, and demo videos are **not**
stored in git. CI downloads the latest rolling `store-assets` GitHub Release
archive (published by `scripts/store_assets.sh publish` / the Publish Store
Assets workflow) before validation and Fastlane upload, and re-hosts that media
as workflow artifacts.

Supports selecting:

- **Platform**: iOS, Android, or both
- **App**: private, production, or both

### Publish Store Assets (`publish-store-assets.yml`)

Validates the rolling `store-assets` release archive and uploads Actions
artifacts (`store-assets`, platform screenshot sets, App Previews, demo
videos). Optionally chains into Sync Store Metadata. Local publishers should
prefer:

```bash
./scripts/store_assets.sh publish --generate all --platform both --sync
```

### GitHub Deployment Environments

Store uploads create GitHub Deployments so PRs and the repository deployment
view show the latest status for each supported channel:

| Environment | Updated by |
| ------------- | ------------ |
| `iOS Private / TestFlight` | PR `/deploy`, Deploy Private |
| `Android Private / Play Internal` | PR `/deploy`, Deploy Private |
| `iOS Private / Firebase App Distribution` | Firebase Distribution (PR revision or push to `main`) |
| `Android Private / Firebase App Distribution` | Firebase Distribution (PR revision or push to `main`) |
| `Android Private / Internal App Sharing` | PR Preview Internal App Sharing |
| `iOS Production / TestFlight` | Release (`internal` channel) |
| `Android Production / Play Internal` | Release (`internal` channel) |
| `iOS Production / App Store` | Release (`production` channel) |
| `Android Production / Play Production` | Release (`production` channel) |
| `iOS Private / App Store Metadata` | Sync Metadata |
| `iOS Production / App Store Metadata` | Sync Metadata |
| `Android Private / Play Store Metadata` | Sync Metadata |
| `Android Production / Play Store Metadata` | Sync Metadata |

### Build Numbers

All deployable builds use epoch-derived build numbers (`$(date +%s) / 10`) — monotonically increasing regardless of how many PRs are active. PR info is stored in build metadata, not the build number.

## Store Metadata

Store metadata is managed per-app in the repository. Each app variant (private
and production) has its own metadata directory with distinct names and listing
copy. Android also has per-variant Play Store icon metadata.

### iOS (App Store Connect)

```
ios/fastlane/
├── screenshots/             # NOT in git — restored from store-assets release
│   └── en-US/               # Shared App Store iPhone and iPad screenshots
├── app-previews/            # NOT in git — restored from store-assets release
│   └── en-US/               # Optional App Store product demo videos
├── metadata-private/        # MonkeySSH β (preview app)
│   ├── en-US/
│   │   ├── name.txt         # "MonkeySSH β"
│   │   ├── subtitle.txt
│   │   ├── description.txt
│   │   ├── keywords.txt
│   │   ├── release_notes.txt
│   │   ├── privacy_url.txt
│   │   └── support_url.txt
│   ├── review_information/
│   │   └── notes.txt
│   ├── copyright.txt
│   └── primary_category.txt
└── metadata-production/     # MonkeySSH (production app)
    ├── en-US/
    │   └── (same structure)
    ├── copyright.txt
    └── primary_category.txt
```

Fastlane `deliver` no longer uploads iOS App Store icons through metadata sync;
App Store Connect uses the app icon embedded in the selected build.

`review_information/notes.txt` holds the App Review notes shown to Apple's
reviewers. App Store Connect only accepts a review-detail update when the full
App Review contact is also supplied, so the sync reads the contact from CI
secrets (never committed, since this repo is public):

- `APP_REVIEW_CONTACT_FIRST_NAME`
- `APP_REVIEW_CONTACT_LAST_NAME`
- `APP_REVIEW_CONTACT_EMAIL`
- `APP_REVIEW_CONTACT_PHONE` (E.164 format, e.g. `+14155550123`)

When these secrets are unset, the notes sync is skipped with a warning and the
rest of the metadata still syncs.

### Android (Google Play)

```
android/fastlane/
├── metadata-private/        # MonkeySSH β (preview app)
│   └── android/en-US/
│       ├── title.txt        # "MonkeySSH β"
│       ├── short_description.txt
│       ├── full_description.txt
│       ├── icon.png         # 512x512 (private banner icon)
│       ├── images/
│       │   ├── featureGraphic.png   # in git
│       │   ├── phoneScreenshots/    # NOT in git — store-assets release
│       │   ├── sevenInchScreenshots/
│       │   └── tenInchScreenshots/
│       └── changelogs/
│           └── default.txt
└── metadata-production/     # MonkeySSH (production app)
    └── android/en-US/
        └── (same structure)
```

Edit committed listing copy and metadata will sync on the next release deploy, or trigger the **Sync Metadata** workflow manually. Publish regenerated screenshots/videos with `scripts/store_assets.sh publish` instead of committing them.
Android `icon.png` files are auto-regenerated from `assets/icons/monkeyssh_icon*.png` during deploy/metadata-sync workflows, so marketplace icons stay aligned with the app icon assets.
Google Play text limits still apply to the repository files: `title.txt` must stay within 30 characters, `short_description.txt` within 80 characters, and `full_description.txt` within 4000 characters. You can validate them locally with `python3 scripts/validate_play_store_metadata.py`.
App Store text limits can be validated locally with `python3 scripts/validate_app_store_metadata.py`.
Store screenshots can be regenerated locally with `python3 scripts/generate_store_screenshots.py` after installing Pillow (`python3 -m pip install Pillow`). The generator starts a temporary local `sshd` and uniquely named MonkeyMux workspace, boots the normal MonkeySSH app on iOS simulators and an Android emulator with release-demo data, drives real app navigation through a real Copilot ACP conversation in the embedded native agent window, a real Copilot CLI terminal, hosts, snippets, the MonkeyMux window selector with the current supported agent family, SFTP, and a real Claude Code terminal, then captures native device screenshots into the Fastlane folders. The generator fails instead of substituting mock screenshots if the real SSH/MonkeyMux workspace cannot be created.
Each device gets eight screenshots. The final two show a real native chat and Agent Management with live remote version checks. Only entirely Pro-only features get screenshot badges. Agent Management has a Pro caption below the complete app image, without covering controls. Native chat is available free, so it uses the full unbadged capture. The screenshot entrypoint grants demo Pro access only, with purchases disabled. Agent Management waits for real SSH probes and never installs or updates the developer's CLIs. The existing `STORE_SCREENSHOT_REDACT_IDENTITIES` flag hides private executable directories in the manager while preserving real version numbers and install sources. Uncaptioned originals for badged scenes stay under `build/store-screenshots/raw/` for inspection.

Run the caption and scene-contract regression checks with `python3 -m unittest discover -s test/scripts -p 'store_screenshots_test.py'` on macOS with Pillow installed. For a screenshot-only refresh, download the current archive before generation to preserve existing videos, then publish without `--generate` so the archive restore does not overwrite the new captures. Omit `--sync` when preparing a PR rather than updating live listings. The publisher also regenerates and uploads `monkeyssh-agent-workspace.png`, the release-hosted README gallery, from the current iPhone native-chat and Agent Management captures. To preview that composition without launching the app, run `python3 scripts/generate_store_screenshots.py --gallery-only`. To replace only a failed scene while preserving validated captures, use `python3 scripts/generate_store_screenshots.py both --scene terminal_claude` or another registered scene name. This still captures the real app and live SSH workspace; it is not a mock or image-only fallback. Set `ANDROID_SERIAL` to a dedicated emulator when other projects are running locally. Android capture checks the foreground activity and fails rather than saving another app's screen.

Generated screenshot counts, dimensions, and OCR content can be validated locally on macOS with `python3 scripts/validate_store_screenshots.py` after installing Pillow.
Short product demo videos can be recorded with `python3 scripts/generate_store_demo_videos.py [ios|android|both]` and validated with `python3 scripts/validate_store_demo_videos.py [ios|android|all]`. The video generator reuses the real screenshot capture environment, records native simulator/emulator screen video while the app opens a real Copilot ACP conversation in the embedded native agent window, then walks Claude Code, the MonkeyMux window switcher, OpenCode, a real image paste into Copilot CLI, and a Copilot prompt against that screenshot, then composes that single recording into store-compliant deliverables. Copilot screenshot/video scenes must show the CLI displaying the image inline; the harness must not enable streamer mode or rename sessions to placeholders. App Store **app previews** are full-screen native captures at the exact device slot resolution — `ios/fastlane/app-previews/en-US/iphone_67_1.mov` (886x1920) and `ipad_13_1.mov` (1200x1600) — with fading caption overlays and a silent audio track, because App Store Connect validates resolution at upload. The **Google Play preview** is a 16:9 landscape branded promo at `store/demo-videos/google-play/monkeyssh-google-play-promo.mp4` (1920x1080); Google Play videos are externally hosted, so this MP4 is uploaded to YouTube and referenced by URL in Play Console rather than synced by Fastlane. The portrait branded canvas is kept for ads under `store/demo-videos/ads/`. The validator enforces per-slot resolution, 15-30s duration, H.264, an audio track on the Apple previews, and that the live app region advances through scenes.

After generation, **do not commit the binaries**. Publish them instead:

```bash
./scripts/store_assets.sh publish --sync
```

That uploads a rolling `store-assets` GitHub Release archive. CI downloads it during Sync Metadata / production releases and also exposes the media as Actions artifacts. Restore into a checkout with `./scripts/store_assets.sh download`.

### Agent slash command

For an end-to-end guided release (copy review, media publish, optional ship),
invoke the repo skill:

```text
/prepare-release
/prepare-release --ship
/prepare-release --media-only --sync
/prepare-release v1.2.3 --skip-media --skip-copy --ship
```

Skill source: `.agents/skills/prepare-release/SKILL.md`.

The future refresh prompt lives in `docs/store-assets-prompt.md`.

> **Note:** Apple and Google require unique app names per account. The private app uses "MonkeySSH β" to distinguish it from the production "MonkeySSH" listing.

## Building Flavors Locally

### iOS release validation prerequisites

Use the standard Xcode bundle with the installed iOS runtime when validating iOS releases locally:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
flutter build ios --flavor production --release --no-codesign
```

Do not validate releases with a side-by-side Xcode beta or point release unless its selected SDK has a matching installed iOS runtime. For example, Xcode 26.4.1 fails when only the iOS 26.2 simulator runtime is installed; `/Applications/Xcode.app` (Xcode 26.2 on the current release image) is the supported local and CI selector.

Flutter 3.41 also warns that UIScene lifecycle support will soon be required. MonkeySSH has a custom `AppDelegate` for native method channels, document pickers, Live Activities, and foreground/background state, so the automatic Flutter migration is not safe. Track the manual migration as release work: add `UIApplicationSceneManifest`, introduce a `SceneDelegate`/`FlutterSceneDelegate`, switch plugin registration to `FlutterImplicitEngineDelegate`, and move scene foreground/background handling out of `AppDelegate` together.

```bash
# Private flavor
flutter build apk --flavor private --release
flutter build ios --flavor private --release --no-codesign

# Production flavor
flutter build apk --flavor production --release
flutter build ios --flavor production --release --no-codesign

# With custom version
flutter build apk --flavor private --release --build-name=0.1.0-pr.1 --build-number=12345
```

### Firebase analytics and crash reporting

Firebase Analytics and Crashlytics are compiled into the app but disabled at
runtime unless Firebase is explicitly enabled for the build:

```bash
flutter build apk \
  --flavor production \
  --release \
  --dart-define=FLUTTY_FIREBASE_ENABLED=true
```

MonkeySSH uses Firebase project `monkeyssh`.

Before enabling that flag, provide the Firebase app config for the matching
platform/flavor:

- Android: `android/app/src/private/google-services.json` and
  `android/app/src/production/google-services.json`
- iOS: `ios/Runner/Firebase/private/GoogleService-Info.plist` and
  `ios/Runner/Firebase/production/GoogleService-Info.plist`

The config files are ignored by git so release automation should write them
from encrypted secrets before the build. Without these files, the app keeps
telemetry unavailable and the native Crashlytics upload phase skips dSYM upload.
The in-app Settings toggle controls both Firebase Analytics collection and
Crashlytics collection; collection defaults to off for existing and new installs.
The Android manifest and iOS Info.plist also disable Firebase collection by
default so native startup cannot collect before Dart applies the saved setting.
Firebase's current Apple SDK requires iOS 15 or newer. iOS and macOS builds
resolve every plugin and the Firebase SDK through Swift Package Manager, so
there is no Podfile and no `pod install` step. The `Upload Crashlytics dSYMs`
build phase reads the `run` script from the resolved SPM checkout under
`$BUILD_DIR`. It handles two cases differently: with no Firebase config it
logs a plain `Skipping Crashlytics dSYM upload` note, which is the expected
state for unconfigured builds; if the config is present but the run script
is missing it emits an Xcode `warning:`, because that means dSYMs silently
did not reach Crashlytics. Neither case fails the build.

GitHub Actions reads Firebase config from these repository secrets and writes
the matching flavor file before each build:

- `FIREBASE_ANDROID_PRODUCTION_GOOGLE_SERVICES_JSON`
- `FIREBASE_ANDROID_PRIVATE_GOOGLE_SERVICES_JSON`
- `FIREBASE_IOS_PRODUCTION_GOOGLE_SERVICE_INFO_PLIST`
- `FIREBASE_IOS_PRIVATE_GOOGLE_SERVICE_INFO_PLIST`

When the relevant secret is present, the build passes
`--dart-define=FLUTTY_FIREBASE_ENABLED=true`; otherwise Firebase remains
disabled for that build.

## First-Time Setup Checklist

- [ ] Apple Developer account active
- [ ] Two apps created in App Store Connect
- [ ] Two apps created in Google Play Console
- [ ] Private Git repo created for fastlane match
- [ ] `fastlane match init` run locally
- [ ] Certificates generated for both bundle IDs
- [ ] Android upload keystore generated
- [ ] Google Play service account created with JSON key
- [ ] App Store Connect API key created with .p8 file
- [ ] All GitHub Secrets configured
- [ ] First manual upload to Play Store done (required before API uploads work)
- [ ] Firebase App Distribution enabled for both private apps, tester group created
- [ ] Firebase service account created with App Distribution Admin role (`FIREBASE_SERVICE_ACCOUNT_JSON`)
- [ ] At least one iOS tester device UDID registered (required for ad hoc profiles)

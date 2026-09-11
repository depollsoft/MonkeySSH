#!/usr/bin/env bash
# Manage regenerated store media outside git.
#
# Store screenshots, App Preview videos, and demo videos are large binary
# deliverables produced by local generators. They are published to a rolling
# GitHub Release tag (store-assets) and re-hosted as GitHub Actions artifacts
# during publish/sync workflows instead of being committed to the repository.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RELEASE_TAG="${STORE_ASSETS_RELEASE_TAG:-store-assets}"
RELEASE_TITLE="${STORE_ASSETS_RELEASE_TITLE:-Store assets}"
ASSET_NAME="${STORE_ASSETS_ARCHIVE_NAME:-store-assets.tar.gz}"
DEFAULT_OUTPUT="${STORE_ASSETS_ARCHIVE:-$ROOT_DIR/build/store-assets/$ASSET_NAME}"

usage() {
  cat <<'EOF'
Usage: scripts/store_assets.sh <command> [options]

Commands:
  paths                 Print regenerated store-media globs
  package [options]     Create a tar.gz of local regenerated store media
  download [options]    Download + extract the latest published store assets
  publish [options]     Package local media, upload to the store-assets release,
                        and optionally validate / trigger metadata sync
  present               Exit 0 if required store media exists locally

package options:
  -o, --output <path>   Archive path (default: build/store-assets/store-assets.tar.gz)
  --require-screenshots Fail if screenshot sets are incomplete
  --require-videos      Fail if demo/app-preview videos are incomplete
  --platform <target>   ios|android|both (default: both); scopes validators

download options:
  -o, --output <dir>    Directory to extract into (default: repo root)
  --repo <owner/repo>   GitHub repo (default: current gh repo)
  --tag <tag>           Release tag (default: store-assets)
  --archive <path>      Use a local archive instead of downloading
  --run-id <id>         Download the store-assets artifact from a workflow run

publish options:
  --generate <target>   Generate before packaging: none|screenshots|videos|all
                        (default: none). Partial generation first restores the
                        current store-assets release so other media is kept.
  --platform <target>   ios|android|both (default: both)
  --skip-validate       Skip local validators before upload
  --sync                Trigger Sync Store Metadata after publishing
  --app <target>        private|production|both when --sync (default: both)
  --no-workflow         Do not dispatch publish-store-assets.yml
  -o, --output <path>   Archive path to build (basename must be store-assets.tar.gz)

Environment:
  STORE_ASSETS_RELEASE_TAG   Override release tag (default: store-assets)
  STORE_ASSETS_ARCHIVE_NAME  Override archive file name
  GH_TOKEN / gh auth         Required for download/publish against GitHub
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "'$1' is required but was not found on PATH."
}

repo_slug() {
  if [ -n "${STORE_ASSETS_REPO:-}" ]; then
    printf '%s\n' "$STORE_ASSETS_REPO"
    return
  fi
  if [ -n "${GITHUB_REPOSITORY:-}" ]; then
    printf '%s\n' "$GITHUB_REPOSITORY"
    return
  fi
  require_command gh
  gh repo view --json nameWithOwner --jq .nameWithOwner
}

managed_media_roots() {
  cat <<'EOF'
ios/fastlane/screenshots
ios/fastlane/app-previews
store/demo-videos
android/fastlane/metadata-private/android/en-US/images/phoneScreenshots
android/fastlane/metadata-private/android/en-US/images/sevenInchScreenshots
android/fastlane/metadata-private/android/en-US/images/tenInchScreenshots
android/fastlane/metadata-production/android/en-US/images/phoneScreenshots
android/fastlane/metadata-production/android/en-US/images/sevenInchScreenshots
android/fastlane/metadata-production/android/en-US/images/tenInchScreenshots
EOF
}

screenshot_globs() {
  cat <<'EOF'
ios/fastlane/screenshots/en-US/*.png
android/fastlane/metadata-production/android/en-US/images/phoneScreenshots/*.png
android/fastlane/metadata-production/android/en-US/images/sevenInchScreenshots/*.png
android/fastlane/metadata-production/android/en-US/images/tenInchScreenshots/*.png
android/fastlane/metadata-private/android/en-US/images/phoneScreenshots/*.png
android/fastlane/metadata-private/android/en-US/images/sevenInchScreenshots/*.png
android/fastlane/metadata-private/android/en-US/images/tenInchScreenshots/*.png
EOF
}

video_globs() {
  cat <<'EOF'
ios/fastlane/app-previews/en-US/*.mov
ios/fastlane/app-previews/en-US/*.mp4
ios/fastlane/app-previews/en-US/*.m4v
store/demo-videos/google-play/*.mp4
store/demo-videos/ads/*.mp4
EOF
}

all_globs() {
  screenshot_globs
  video_globs
}

expand_existing() {
  local pattern
  local path
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    shopt -s nullglob
    # shellcheck disable=SC2086
    for path in $pattern; do
      if [ -f "$path" ]; then
        printf '%s\n' "$path"
      fi
    done
    shopt -u nullglob
  done
}

list_media_files() {
  all_globs | expand_existing | sort -u
}

count_media_files() {
  list_media_files | wc -l | tr -d ' '
}

normalize_platform() {
  case "${1:-}" in
    ios | android | both) printf '%s\n' "$1" ;;
    *) fail "platform must be ios, android, or both (got: ${1:-})" ;;
  esac
}

validation_python() {
  if [ -x "$ROOT_DIR/.venv/bin/python" ]; then
    echo "$ROOT_DIR/.venv/bin/python"
  else
    command -v python3
  fi
}

assert_screenshots_present() {
  local platform python
  platform="$(normalize_platform "${1:-both}")"
  python="$(validation_python)"
  "$python" scripts/validate_store_screenshots.py "$platform" >/dev/null
}

assert_videos_present() {
  local platform python
  platform="$(normalize_platform "${1:-both}")"
  python="$(validation_python)"
  if [ "$platform" = both ]; then
    "$python" scripts/validate_store_demo_videos.py all >/dev/null
  else
    "$python" scripts/validate_store_demo_videos.py "$platform" >/dev/null
  fi
}

cmd_paths() {
  all_globs
}

cmd_present() {
  local count
  count="$(count_media_files)"
  if [ "$count" -eq 0 ]; then
    echo "No regenerated store media found in the working tree."
    return 1
  fi
  echo "Found $count regenerated store media file(s)."
  list_media_files
}

write_manifest() {
  local archive_path="$1"
  local manifest_path="$2"
  require_command python3
  python3 - "$archive_path" "$manifest_path" "$RELEASE_TAG" <<'PY'
import hashlib
import json
import os
import sys
import time
from pathlib import Path

archive_path = Path(sys.argv[1])
manifest_path = Path(sys.argv[2])
release_tag = sys.argv[3]
root = Path.cwd()

files = []
for line in os.popen('scripts/store_assets.sh paths'):
    pattern = line.strip()
    if not pattern:
        continue
    for path in sorted(root.glob(pattern)):
        if not path.is_file() or path.is_symlink():
            continue
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        rel = path.relative_to(root).as_posix()
        files.append({
            'path': rel,
            'sha256': digest,
            'size': path.stat().st_size,
        })

payload = {
    'version': 1,
    'generated_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    'release_tag': release_tag,
    'archive': archive_path.name,
    'file_count': len(files),
    'files': files,
}
manifest_path.parent.mkdir(parents=True, exist_ok=True)
manifest_path.write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')
print(f'Wrote manifest with {len(files)} file(s) to {manifest_path}')
PY
}

cmd_package() {
  local output="$DEFAULT_OUTPUT"
  local require_screenshots=false
  local require_videos=false
  local platform="both"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -o | --output)
        shift
        [ "$#" -gt 0 ] || fail "--output requires a path"
        output="$1"
        ;;
      --require-screenshots)
        require_screenshots=true
        ;;
      --require-videos)
        require_videos=true
        ;;
      --platform)
        shift
        [ "$#" -gt 0 ] || fail "--platform requires ios|android|both"
        platform="$(normalize_platform "$1")"
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown package option: $1"
        ;;
    esac
    shift
  done

  require_command tar
  require_command gzip

  if [ "$(count_media_files)" -eq 0 ]; then
    fail "No regenerated store media found to package. Generate screenshots/videos first."
  fi

  if [ "$require_screenshots" = true ]; then
    assert_screenshots_present "$platform"
  fi
  if [ "$require_videos" = true ]; then
    assert_videos_present "$platform"
  fi

  mkdir -p "$(dirname "$output")"
  local staging
  staging="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf $(printf %q "$staging")" RETURN

  local path
  while IFS= read -r path; do
    mkdir -p "$staging/$(dirname "$path")"
    cp "$path" "$staging/$path"
  done < <(list_media_files)

  write_manifest "$output" "$staging/store-assets-manifest.json"

  # Avoid macOS AppleDouble "._*" entries in the archive.
  COPYFILE_DISABLE=1 tar -C "$staging" --exclude '._*' --exclude '.DS_Store' -czf "$output" .
  local size
  size="$(wc -c <"$output" | tr -d ' ')"
  echo "Packaged store assets -> $output ($size bytes)"
}

# Safely extract a store-assets archive into dest.
# - Clears managed media roots first (no stale overlay)
# - Rejects paths outside the allowlist, absolute paths, .., and symlinks
# - Verifies store-assets-manifest.json hashes when present
extract_archive() {
  local archive="$1"
  local dest="$2"
  require_command python3
  require_command tar
  mkdir -p "$dest"

  python3 - "$archive" "$dest" <<'PY'
from __future__ import annotations

import hashlib
import json
import os
import shutil
import sys
import tarfile
import tempfile
from pathlib import Path

archive = Path(sys.argv[1])
dest = Path(sys.argv[2]).resolve()

ALLOWED_EXACT = {'store-assets-manifest.json'}
ALLOWED_PREFIXES = (
    'ios/fastlane/screenshots/',
    'ios/fastlane/app-previews/',
    'store/demo-videos/',
    'android/fastlane/metadata-private/android/en-US/images/phoneScreenshots/',
    'android/fastlane/metadata-private/android/en-US/images/sevenInchScreenshots/',
    'android/fastlane/metadata-private/android/en-US/images/tenInchScreenshots/',
    'android/fastlane/metadata-production/android/en-US/images/phoneScreenshots/',
    'android/fastlane/metadata-production/android/en-US/images/sevenInchScreenshots/',
    'android/fastlane/metadata-production/android/en-US/images/tenInchScreenshots/',
)


def normalize_member_name(name: str) -> str:
    normalized = name.replace('\\', '/')
    while normalized.startswith('./'):
        normalized = normalized[2:]
    return normalized.lstrip('/')


def is_ignored_junk(path: str) -> bool:
    parts = Path(path).parts
    base = Path(path).name
    if base in {'.DS_Store', '.gitkeep'}:
        return True
    if base.startswith('._'):
        return True
    if any(part.startswith('._') for part in parts):
        return True
    return False


def is_allowed(path: str) -> bool:
    if path in ALLOWED_EXACT:
        return True
    return any(path.startswith(prefix) for prefix in ALLOWED_PREFIXES)


def clear_managed(dest_root: Path) -> None:
    roots = [prefix.rstrip('/') for prefix in ALLOWED_PREFIXES]
    # Preflight every root before clearing any media. A safe archive path can
    # still escape dest through an existing ancestor symlink. Root symlinks
    # themselves are safe to unlink below; their targets are never traversed.
    for rel in roots:
        for parent in reversed(Path(rel).parents):
            target = dest_root / parent
            if target.is_symlink() or (target.exists() and not target.is_dir()):
                raise SystemExit(f'Refusing unsafe destination ancestor: {target}')
    manifest = dest_root / 'store-assets-manifest.json'
    if manifest.is_dir() and not manifest.is_symlink():
        raise SystemExit(f'Refusing destination manifest directory: {manifest}')

    for rel in roots:
        target = dest_root / rel
        if target.exists() or target.is_symlink():
            if target.is_dir() and not target.is_symlink():
                shutil.rmtree(target)
            else:
                target.unlink()
    if manifest.exists() or manifest.is_symlink():
        manifest.unlink()


def main() -> None:
    if not archive.is_file():
        raise SystemExit(f'Archive not found: {archive}')

    with tarfile.open(archive, 'r:*') as tf:
        members = tf.getmembers()
        approved: list[tarfile.TarInfo] = []
        for member in members:
            name = normalize_member_name(member.name)
            if not name or name.endswith('/'):
                continue
            if is_ignored_junk(name):
                continue
            if member.issym() or member.islnk():
                raise SystemExit(f'Refusing archive member symlink/hardlink: {member.name}')
            if not member.isfile():
                continue
            if name != Path(name).as_posix() or '..' in Path(name).parts:
                raise SystemExit(f'Refusing unsafe archive path: {member.name}')
            if os.path.isabs(member.name) or member.name.startswith(('/', '\\')):
                raise SystemExit(f'Refusing absolute archive path: {member.name}')
            if not is_allowed(name):
                raise SystemExit(f'Refusing non-allowlisted archive path: {name}')
            member.name = name
            approved.append(member)

        if not approved:
            raise SystemExit('Archive contained no approved store media files')

        with tempfile.TemporaryDirectory(prefix='store-assets-safe-') as tmp:
            tmp_path = Path(tmp)
            # filter='data' blocks special files on Python 3.12+
            try:
                tf.extractall(tmp_path, members=approved, filter='data')
            except TypeError:
                tf.extractall(tmp_path, members=approved)

            extracted_files: list[Path] = []
            for path in tmp_path.rglob('*'):
                if path.is_symlink():
                    raise SystemExit(
                        f'Refusing extracted symlink: {path.relative_to(tmp_path)}',
                    )
                if path.is_file():
                    rel = path.relative_to(tmp_path).as_posix()
                    if not is_allowed(rel):
                        raise SystemExit(f'Refusing extracted non-allowlisted path: {rel}')
                    extracted_files.append(path)

            manifest_path = tmp_path / 'store-assets-manifest.json'
            if manifest_path.is_file():
                payload = json.loads(manifest_path.read_text(encoding='utf-8'))
                entries = payload.get('files') or []
                if not isinstance(entries, list) or not entries:
                    raise SystemExit('store-assets-manifest.json is missing file entries')
                file_count = payload.get('file_count')
                if type(file_count) is not int or file_count != len(entries):
                    raise SystemExit(
                        'store-assets-manifest.json file_count must be an integer '
                        'matching its file entries',
                    )
                by_path = {}
                for entry in entries:
                    if not isinstance(entry, dict) or not isinstance(
                        entry.get('path'), str,
                    ):
                        raise SystemExit('Invalid store-assets-manifest.json file entry')
                    rel = entry['path']
                    if rel in by_path:
                        raise SystemExit(f'Duplicate manifest file entry: {rel}')
                    by_path[rel] = entry
                media_paths = {
                    path.relative_to(tmp_path).as_posix()
                    for path in extracted_files
                    if path != manifest_path
                }
                missing = by_path.keys() - media_paths
                if missing:
                    raise SystemExit(
                        f'Manifest file missing from archive: {sorted(missing)[0]}',
                    )
                for path in extracted_files:
                    rel = path.relative_to(tmp_path).as_posix()
                    if rel == 'store-assets-manifest.json':
                        continue
                    entry = by_path.get(rel)
                    if entry is None:
                        raise SystemExit(f'Extracted file missing from manifest: {rel}')
                    digest = hashlib.sha256(path.read_bytes()).hexdigest()
                    expected = str(entry.get('sha256', ''))
                    if digest != expected:
                        raise SystemExit(f'Manifest hash mismatch for {rel}')
                    expected_size = entry.get('size')
                    if expected_size is not None and int(expected_size) != path.stat().st_size:
                        raise SystemExit(f'Manifest size mismatch for {rel}')

            clear_managed(dest)

            for path in extracted_files:
                rel = path.relative_to(tmp_path).as_posix()
                target = dest / rel
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, target)

            print(f'Safely extracted {len(extracted_files)} store media file(s) into {dest}')


if __name__ == '__main__':
    main()
PY
}

install_extracted_tree() {
  local source="$1"
  local dest="$2"
  local tmp_archive
  tmp_archive="$(mktemp -t store-assets-repack.XXXXXX.tar.gz)"
  # shellcheck disable=SC2064
  trap "rm -f $(printf %q "$tmp_archive")" RETURN
  require_command tar
  tar -C "$source" -czf "$tmp_archive" . || return
  extract_archive "$tmp_archive" "$dest"
}

cmd_download() {
  local dest="$ROOT_DIR"
  local repo=""
  local tag="$RELEASE_TAG"
  local archive=""
  local run_id=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -o | --output)
        shift
        [ "$#" -gt 0 ] || fail "--output requires a directory"
        dest="$1"
        ;;
      --repo)
        shift
        [ "$#" -gt 0 ] || fail "--repo requires owner/name"
        repo="$1"
        ;;
      --tag)
        shift
        [ "$#" -gt 0 ] || fail "--tag requires a release tag"
        tag="$1"
        ;;
      --archive)
        shift
        [ "$#" -gt 0 ] || fail "--archive requires a path"
        archive="$1"
        ;;
      --run-id)
        shift
        [ "$#" -gt 0 ] || fail "--run-id requires a workflow run id"
        run_id="$1"
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown download option: $1"
        ;;
    esac
    shift
  done

  require_command tar
  mkdir -p "$dest"

  if [ -n "$archive" ]; then
    [ -f "$archive" ] || fail "Archive not found: $archive"
    # This function is also called in a conditional, where errexit is disabled.
    extract_archive "$archive" "$dest" || return
    echo "Extracted $archive into $dest"
    return 0
  fi

  require_command gh
  repo="${repo:-$(repo_slug)}"

  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf $(printf %q "$tmp")" RETURN

  if [ -n "$run_id" ]; then
    echo "Downloading store-assets artifact from run $run_id ($repo)..."
    gh run download "$run_id" \
      --repo "$repo" \
      --name store-assets \
      --dir "$tmp" || return
    if [ -f "$tmp/$ASSET_NAME" ]; then
      extract_archive "$tmp/$ASSET_NAME" "$dest" || return
    elif [ -f "$tmp/store-assets/$ASSET_NAME" ]; then
      extract_archive "$tmp/store-assets/$ASSET_NAME" "$dest" || return
    elif [ -d "$tmp/ios" ] || [ -d "$tmp/store" ] || [ -d "$tmp/android" ]; then
      install_extracted_tree "$tmp" "$dest" || return
    else
      fail "Could not find store assets inside workflow artifact for run $run_id"
    fi
    echo "Restored store assets from workflow run $run_id into $dest"
    return 0
  fi

  echo "Downloading $ASSET_NAME from release $tag ($repo)..."
  if ! gh release download "$tag" \
    --repo "$repo" \
    --pattern "$ASSET_NAME" \
    --dir "$tmp" \
    --clobber; then
    fail "Failed to download $ASSET_NAME from release '$tag'. Publish store assets first with scripts/store_assets.sh publish"
  fi
  extract_archive "$tmp/$ASSET_NAME" "$dest" || return
  echo "Restored store assets from release $tag into $dest"
}

ensure_canonical_output_name() {
  local output="$1"
  local base
  base="$(basename "$output")"
  if [ "$base" != "$ASSET_NAME" ]; then
    fail "Publish archive basename must be '$ASSET_NAME' (got '$base'). CI always downloads that asset name from the store-assets release."
  fi
}

restore_current_release_if_present() {
  local repo="$1"
  if gh release view "$RELEASE_TAG" --repo "$repo" >/dev/null 2>&1; then
    echo "Restoring current $RELEASE_TAG release before partial generation..."
    if ! cmd_download --repo "$repo"; then
      echo "warning: could not restore current $RELEASE_TAG release; continuing with local media only" >&2
    fi
  else
    echo "No existing $RELEASE_TAG release found; packaging whatever media is local."
  fi
}

cmd_publish() {
  local output="$DEFAULT_OUTPUT"
  local generate="none"
  local platform="both"
  local skip_validate=false
  local sync=false
  local app="both"
  local dispatch_workflow=true

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -o | --output)
        shift
        [ "$#" -gt 0 ] || fail "--output requires a path"
        output="$1"
        ;;
      --generate)
        shift
        [ "$#" -gt 0 ] || fail "--generate requires none|screenshots|videos|all"
        generate="$1"
        ;;
      --platform)
        shift
        [ "$#" -gt 0 ] || fail "--platform requires ios|android|both"
        platform="$(normalize_platform "$1")"
        ;;
      --skip-validate)
        skip_validate=true
        ;;
      --sync)
        sync=true
        ;;
      --app)
        shift
        [ "$#" -gt 0 ] || fail "--app requires private|production|both"
        app="$1"
        ;;
      --no-workflow)
        dispatch_workflow=false
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown publish option: $1"
        ;;
    esac
    shift
  done

  case "$app" in
    private | production | both) ;;
    *) fail "--app must be private, production, or both" ;;
  esac
  case "$generate" in
    none | screenshots | videos | all) ;;
    *) fail "--generate must be one of: none, screenshots, videos, all" ;;
  esac

  ensure_canonical_output_name "$output"

  require_command gh
  require_command python3

  local repo
  repo="$(repo_slug)"

  # Restore only before partial generation here; local captures must survive
  # publishing without generation. Packaging validates the complete archive.
  if [ "$generate" != none ] && { [ "$generate" != all ] || [ "$platform" != both ]; }; then
    restore_current_release_if_present "$repo"
  fi

  case "$generate" in
    none) ;;
    screenshots)
      python3 scripts/generate_store_screenshots.py "$platform"
      ;;
    videos)
      python3 scripts/generate_store_demo_videos.py "$platform"
      ;;
    all)
      python3 scripts/generate_store_screenshots.py "$platform"
      python3 scripts/generate_store_demo_videos.py "$platform"
      ;;
  esac

  # Published rolling archives must stay complete for CI consumers.
  local package_args=(--platform both)
  if [ "$skip_validate" = false ]; then
    package_args+=(--require-screenshots)
    if video_globs | expand_existing | grep -E '\.(mov|mp4|m4v)$' >/dev/null 2>&1 ||
      [ "$generate" = videos ] || [ "$generate" = all ]; then
      package_args+=(--require-videos)
    fi
  fi
  cmd_package -o "$output" "${package_args[@]}"

  # Rebuild the release-hosted README image from the exact captured files we
  # just packaged, never a stale contact sheet left in the build directory.
  "$(validation_python)" scripts/generate_store_screenshots.py --gallery-only
  local gallery="$ROOT_DIR/build/store-screenshots/monkeyssh-agent-workspace.png"

  local notes
  notes="$(mktemp)"
  cat >"$notes" <<EOF
Rolling archive of regenerated MonkeySSH store media (screenshots, App Previews, demo videos).

- Updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
- Source commit: $(git rev-parse HEAD)
- Do not commit these binaries to git; download with \`scripts/store_assets.sh download\`.
EOF

  if gh release view "$RELEASE_TAG" --repo "$repo" >/dev/null 2>&1; then
    gh release upload "$RELEASE_TAG" "$output" \
      --repo "$repo" \
      --clobber
    gh release edit "$RELEASE_TAG" \
      --repo "$repo" \
      --title "$RELEASE_TITLE" \
      --notes-file "$notes" \
      --prerelease \
      --latest=false >/dev/null
  else
    gh release create "$RELEASE_TAG" "$output" \
      --repo "$repo" \
      --title "$RELEASE_TITLE" \
      --notes-file "$notes" \
      --prerelease \
      --latest=false
  fi
  gh release upload "$RELEASE_TAG" "$gallery" --repo "$repo" --clobber
  rm -f "$notes"
  echo "Published $output and README gallery to release $RELEASE_TAG on $repo"

  if [ "$dispatch_workflow" = true ]; then
    local sync_value=false
    if [ "$sync" = true ]; then
      sync_value=true
    fi
    gh workflow run publish-store-assets.yml \
      --repo "$repo" \
      -f "sync=$sync_value" \
      -f "app=$app" \
      -f "platform=$platform"
    echo "Dispatched publish-store-assets.yml (platform=$platform, sync=$sync_value, app=$app)"
  elif [ "$sync" = true ]; then
    gh workflow run sync-metadata.yml \
      --repo "$repo" \
      -f "platform=$platform" \
      -f "app=$app"
    echo "Dispatched sync-metadata.yml (platform=$platform, app=$app)"
  fi
}

main() {
  local command="${1:-}"
  if [ -z "$command" ]; then
    usage
    exit 1
  fi
  shift || true
  case "$command" in
    paths) cmd_paths "$@" ;;
    present) cmd_present "$@" ;;
    package) cmd_package "$@" ;;
    download) cmd_download "$@" ;;
    publish) cmd_publish "$@" ;;
    -h | --help | help) usage ;;
    *)
      usage >&2
      fail "Unknown command: $command"
      ;;
  esac
}

main "$@"

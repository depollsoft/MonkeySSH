#!/usr/bin/env bash
# Prefetch sqlite3 hook binaries so Flutter native-asset builds do not fail
# on a single GitHub release-asset disconnect.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: cache_sqlite3_native_assets.sh <target> [<target> ...]

Targets:
  linux-x64
  ios-arm64
  macos-x64
  macos-arm64
  windows-x64
  android-arm64
  android-x64
  android-arm
  android-ia32

Set SQLITE3_NATIVE_ASSETS_VERIFY_ONLY=1 to validate target mappings and hashes
without downloading assets.
EOF
}

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 2
fi

if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN=python3
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN=python
else
  echo "Python 3 is required to cache sqlite3 native assets." >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PACKAGE_CONFIG="${REPO_ROOT}/.dart_tool/package_config.json"
if [[ ! -f "$PACKAGE_CONFIG" ]]; then
  echo "package_config.json is missing; run flutter pub get first." >&2
  exit 1
fi

SQLITE3_ROOT="$(
  "$PYTHON_BIN" - "$PACKAGE_CONFIG" <<'PY'
import json
import pathlib
import sys
import urllib.parse
import urllib.request

package_config = pathlib.Path(sys.argv[1]).resolve()
root_uri = next(
    package["rootUri"]
    for package in json.loads(package_config.read_text())["packages"]
    if package["name"] == "sqlite3"
)
root_url = urllib.parse.urljoin(package_config.as_uri(), root_uri)
root_path = urllib.request.url2pathname(urllib.parse.urlparse(root_url).path)
print(pathlib.Path(root_path).as_posix())
PY
)"

ASSET_HASHES="${SQLITE3_ROOT}/lib/src/hook/asset_hashes.dart"
if [[ ! -f "$ASSET_HASHES" ]]; then
  echo "sqlite3 asset hashes not found at ${ASSET_HASHES}" >&2
  exit 1
fi

RELEASE_TAG="$(
  "$PYTHON_BIN" - "$ASSET_HASHES" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r"releaseTag = '([^']+)'", text)
if match is None:
    raise SystemExit("could not parse sqlite3 releaseTag")
print(match.group(1))
PY
)"

lookup_hash() {
  local filename="$1"
  "$PYTHON_BIN" - "$ASSET_HASHES" "$filename" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text()
filename = sys.argv[2]
match = re.search(rf"'{re.escape(filename)}': '([0-9a-f]{{64}})'", text)
if match is None:
    raise SystemExit(f"unknown sqlite3 asset: {filename}")
print(match.group(1))
PY
}

verify_hash() {
  local expected_hash="$1"
  local path="$2"
  "$PYTHON_BIN" - "$expected_hash" "$path" <<'PY'
import hashlib
import pathlib
import sys

expected_hash = sys.argv[1]
path = pathlib.Path(sys.argv[2])
actual_hash = hashlib.sha256(path.read_bytes()).hexdigest()
raise SystemExit(0 if actual_hash == expected_hash else 1)
PY
}

prefetch() (
  local source_filename="$1"
  local dest_filename="$2"
  local sha256
  local dest_dir
  local dest_path
  local tmp_path
  local attempt

  sha256="$(lookup_hash "$source_filename")"
  if [[ "${SQLITE3_NATIVE_ASSETS_VERIFY_ONLY:-0}" == "1" ]]; then
    echo "Verified ${source_filename} -> ${dest_filename}"
    return
  fi

  dest_dir="${REPO_ROOT}/.dart_tool/hooks_runner/shared/sqlite3/build/download-${sha256:0:8}"
  dest_path="${dest_dir}/${dest_filename}"
  mkdir -p "$dest_dir"

  if [[ -f "$dest_path" ]]; then
    if verify_hash "$sha256" "$dest_path"; then
      echo "Reusing cached ${source_filename} as ${dest_filename}"
      return
    fi
  fi

  # Each invocation owns its download; only verified bytes replace the cache.
  tmp_path="$(mktemp "${dest_path}.tmp.XXXXXX")"
  trap 'rm -f "$tmp_path"' EXIT
  for attempt in 1 2 3 4 5; do
    if curl --fail --location \
      --retry 5 \
      --retry-all-errors \
      --retry-delay 2 \
      --output "$tmp_path" \
      "https://github.com/simolus3/sqlite3.dart/releases/download/${RELEASE_TAG}/${source_filename}"; then
      if verify_hash "$sha256" "$tmp_path"; then
        mv "$tmp_path" "$dest_path"
        echo "Cached ${source_filename} as ${dest_filename}"
        return
      fi
    fi
    rm -f "$tmp_path"
    echo "Retrying ${source_filename} (attempt ${attempt})" >&2
    sleep $((attempt * 2))
  done

  echo "Failed to download ${source_filename}" >&2
  exit 1
)

for target in "$@"; do
  case "$target" in
  linux-x64)
    prefetch libsqlite3.x64.linux.so libsqlite3.so
    ;;
  ios-arm64)
    prefetch libsqlite3.arm64.ios.dylib libsqlite3.dylib
    ;;
  macos-x64)
    prefetch libsqlite3.x64.macos.dylib libsqlite3.dylib
    ;;
  macos-arm64)
    prefetch libsqlite3.arm64.macos.dylib libsqlite3.dylib
    ;;
  windows-x64)
    prefetch sqlite3.x64.windows.dll sqlite3.dll
    ;;
  android-arm64)
    prefetch libsqlite3.arm64.android.so libsqlite3.so
    ;;
  android-x64)
    prefetch libsqlite3.x64.android.so libsqlite3.so
    ;;
  android-arm)
    prefetch libsqlite3.arm.android.so libsqlite3.so
    ;;
  android-ia32)
    prefetch libsqlite3.ia32.android.so libsqlite3.so
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown target: ${target}" >&2
    usage >&2
    exit 2
    ;;
  esac
done

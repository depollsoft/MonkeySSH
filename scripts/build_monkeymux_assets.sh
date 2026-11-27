#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE_DIR="$ROOT_DIR/remote/monkeymux"
ASSET_DIR="$ROOT_DIR/assets/monkeymux"
VERSION="$(sh "$REMOTE_DIR/monkeymux-version.sh")"
STAMP_FILE="$ASSET_DIR/.build-inputs.sha256"
TMP_DIR="$(mktemp -d)"
GZIP_TOOL="$TMP_DIR/deterministic-gzip"
trap 'rm -rf "$TMP_DIR"' EXIT

force=false
print_fingerprint=false
case "${1:-}" in
"") ;;
--force) force=true ;;
--print-fingerprint) print_fingerprint=true ;;
*)
  echo "usage: $0 [--force|--print-fingerprint]" >&2
  exit 2
  ;;
esac

targets=(
  "darwin amd64 darwin-amd64"
  "darwin arm64 darwin-arm64"
  "linux amd64 linux-amd64"
  "linux arm64 linux-arm64"
  "windows amd64 windows-amd64"
  "windows arm64 windows-arm64"
)

# Hashes the named file(s) or stdin, returning just the hex digest for a single
# input, or `<digest>  <path>` lines when called via sha256_lines.
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@" | awk '{print $1}'
    return
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$@" | awk '{print $1}'
    return
  fi
  echo "sha256sum or shasum is required" >&2
  return 1
}

sha256_lines() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@"
    return
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$@"
    return
  fi
  echo "sha256sum or shasum is required" >&2
  return 1
}

GO_TOOLCHAIN="$(awk '$1 == "toolchain" { print $2; exit }' "$REMOTE_DIR/go.mod")"
if [[ ! "$GO_TOOLCHAIN" =~ ^go[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "remote/monkeymux/go.mod must pin an exact Go toolchain" >&2
  exit 1
fi

build_fingerprint() {
  local inputs=()
  local rel
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    inputs+=("$rel")
  done < <(
    cd "$ROOT_DIR"
    find remote/monkeymux -type f \
      \( \( -name '*.go' ! -name '*_test.go' \) -o -name 'go.mod' -o -name 'go.sum' \
      -o -name 'monkeymux-version.sh' -o -path '*/conpty/*' \) \
      -print | LC_ALL=C sort
  )
  inputs+=(
    "scripts/build_monkeymux_assets.sh"
    "scripts/deterministic_gzip.go"
    "scripts/verify_monkeymux_assets.py"
  )
  {
    printf 'toolchain=%s\n' "$GO_TOOLCHAIN"
    (cd "$ROOT_DIR" && sha256_lines "${inputs[@]}")
  } | sha256
}

local_cache_enabled() {
  if [[ "${MONKEYMUX_LOCAL_CACHE:-1}" == "0" ]]; then
    return 1
  fi
  case "${CI:-}" in
  1 | true | TRUE | yes | YES) return 1 ;;
  esac
  return 0
}

local_cache_dir_for() {
  local fp="$1"
  local base="${MONKEYMUX_LOCAL_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/monkeyssh/monkeymux}"
  printf '%s/%s\n' "$base" "$fp"
}

restore_from_local_cache() {
  local fp="$1"
  local cache_dir
  cache_dir="$(local_cache_dir_for "$fp")"
  if [[ ! -f "$cache_dir/.build-inputs.sha256" ]]; then
    return 1
  fi
  if [[ "$(<"$cache_dir/.build-inputs.sha256")" != "$fp" ]]; then
    return 1
  fi
  if ! python3 "$ROOT_DIR/scripts/verify_monkeymux_assets.py" "$cache_dir" "$VERSION" >/dev/null 2>&1; then
    return 1
  fi
  mkdir -p "$ASSET_DIR"
  rm -rf "${ASSET_DIR:?}/bin" "$STAMP_FILE" "$ASSET_DIR/manifest.json"
  cp -R "$cache_dir/bin" "$ASSET_DIR/bin"
  cp "$cache_dir/manifest.json" "$ASSET_DIR/manifest.json"
  printf '%s\n' "$fp" >"$STAMP_FILE"
  return 0
}

save_to_local_cache() {
  local fp="$1"
  local cache_dir cache_parent stage_dir
  cache_dir="$(local_cache_dir_for "$fp")"
  cache_parent="$(dirname "$cache_dir")"
  if ! mkdir -p "$cache_parent" 2>/dev/null; then
    return 0
  fi
  if [[ -f "$cache_dir/.build-inputs.sha256" ]] &&
    [[ "$(<"$cache_dir/.build-inputs.sha256")" == "$fp" ]]; then
    return 0
  fi
  stage_dir="$(mktemp -d "$cache_parent/.stage.XXXXXX" 2>/dev/null || true)"
  if [[ -z "$stage_dir" ]]; then
    return 0
  fi
  if cp -R "$ASSET_DIR/bin" "$stage_dir/bin" &&
    cp "$ASSET_DIR/manifest.json" "$stage_dir/manifest.json" &&
    cp "$STAMP_FILE" "$stage_dir/.build-inputs.sha256"; then
    rm -rf "$cache_dir"
    mv "$stage_dir" "$cache_dir" 2>/dev/null || rm -rf "$stage_dir"
  else
    rm -rf "$stage_dir"
  fi
}

fingerprint="$(build_fingerprint)"
if [[ "$print_fingerprint" == true ]]; then
  printf '%s\n' "$fingerprint"
  exit 0
fi
stored_fingerprint=""
if [[ -f "$STAMP_FILE" ]]; then
  stored_fingerprint="$(<"$STAMP_FILE")"
fi
if [[ "$force" == false ]] &&
  [[ "$stored_fingerprint" == "$fingerprint" ]] &&
  python3 "$ROOT_DIR/scripts/verify_monkeymux_assets.py" "$ASSET_DIR" "$VERSION"; then
  echo "MonkeyMux assets are current ($VERSION)."
  exit 0
fi

if [[ "$force" == false ]] && local_cache_enabled && restore_from_local_cache "$fingerprint"; then
  echo "Restored MonkeyMux $VERSION assets from local cache."
  exit 0
fi

rm -f "$STAMP_FILE"
rm -rf "${ASSET_DIR:?}/bin"
mkdir -p "$ASSET_DIR/bin"

# Use the pinned Go standard library for compression so payload bytes do not
# depend on the host's gzip implementation or version.
(
  unset GOOS GOARCH CGO_ENABLED
  cd "$REMOTE_DIR"
  env GOENV=off GOFLAGS= GOEXPERIMENT= GOFIPS140=off GOWORK=off \
    GOTOOLCHAIN="$GO_TOOLCHAIN" GOAMD64=v1 GOARM64=v8.0 \
    go build -buildvcs=false -trimpath -o "$GZIP_TOOL" \
    "$ROOT_DIR/scripts/deterministic_gzip.go"
)

build_target() {
  local goos="$1"
  local goarch="$2"
  local platform="$3"
  local arch_env=()
  case "$goarch" in
  amd64) arch_env+=(GOAMD64=v1) ;;
  arm64) arch_env+=(GOARM64=v8.0) ;;
  esac
  local output_dir="$ASSET_DIR/bin/$platform"
  local raw_output="$TMP_DIR/$platform/monkeymux"
  local output="$output_dir/monkeymux.gz"
  mkdir -p "$output_dir" "$(dirname "$raw_output")"
  (
    cd "$REMOTE_DIR"
    env GOENV=off GOFLAGS= GOEXPERIMENT= GOFIPS140=off GOWORK=off \
      GOTOOLCHAIN="$GO_TOOLCHAIN" GOOS="$goos" GOARCH="$goarch" \
      CGO_ENABLED=0 "${arch_env[@]}" go build -buildvcs=false -trimpath \
      -ldflags="-s -w" -o "$raw_output" .
  )
  "$GZIP_TOOL" "$raw_output" "$output"
  local size sha
  size="$(wc -c <"$raw_output" | tr -d ' ')"
  sha="$(sha256 "$raw_output")"
  printf '    {"platform":"%s","asset":"assets/monkeymux/bin/%s/monkeymux.gz","encoding":"gzip","sha256":"%s","size":%s}' \
    "$platform" "$platform" "$sha" "$size" >"$TMP_DIR/$platform.entry"
}

pids=()
for target in "${targets[@]}"; do
  read -r goos goarch platform <<<"$target"
  build_target "$goos" "$goarch" "$platform" &
  pids+=("$!")
done

build_failed=0
for pid in "${pids[@]}"; do
  if ! wait "$pid"; then
    build_failed=1
  fi
done
if [[ "$build_failed" -ne 0 ]]; then
  exit 1
fi

manifest_entries=()
for target in "${targets[@]}"; do
  read -r _ _ platform <<<"$target"
  manifest_entries+=("$(<"$TMP_DIR/$platform.entry")")
done

{
  printf '{\n'
  printf '  "version": "%s",\n' "$VERSION"
  printf '  "entries": [\n'
  for i in "${!manifest_entries[@]}"; do
    if [ "$i" -gt 0 ]; then
      printf ',\n'
    fi
    printf '%s' "${manifest_entries[$i]}"
  done
  printf '\n  ]\n'
  printf '}\n'
} >"$ASSET_DIR/manifest.json"

printf '%s\n' "$fingerprint" >"$STAMP_FILE"
if local_cache_enabled; then
  save_to_local_cache "$fingerprint"
fi
echo "Built MonkeyMux $VERSION assets with $GO_TOOLCHAIN."

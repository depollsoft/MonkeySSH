#!/usr/bin/env bash
# Fast local inner-loop verification runner for MonkeySSH.
#
# Usage:
#   ./scripts/dev_check.sh [options]
#
# Modes (default: --changed):
#   --changed         Check files changed vs base ref plus untracked files
#   --all             Check the entire repository (parallel format + analyze)
#   --base <ref>      Git base ref for --changed (default: origin/main or main)
#
# Steps (when none are specified, runs format + analyze + targeted tests):
#   --format          Run parallel dart format check (use --fix to write)
#   --fix             Apply dart format changes instead of check-only
#   --analyze         Run daemon-backed dart analyze (--fatal-warnings --fatal-infos)
#   --test            Run targeted tests (or full suite with --all)
#   --android-debug   Build single-ABI Android private debug APK (--no-pub)
#   -h, --help        Show this help message

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

usage() {
  sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

detect_cpus() {
  if command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.ncpu 2>/dev/null || echo 4
  elif command -v nproc >/dev/null 2>&1; then
    nproc 2>/dev/null || echo 4
  else
    echo 4
  fi
}

resolve_java17_home() {
  if [[ -n "${JAVA_HOME:-}" ]] && [[ -x "$JAVA_HOME/bin/java" ]]; then
    if "$JAVA_HOME/bin/java" -version 2>&1 | grep -q 'version "17\.'; then
      printf '%s\n' "$JAVA_HOME"
      return 0
    fi
  fi
  local jh=""
  if command -v /usr/libexec/java_home >/dev/null 2>&1; then
    jh="$(/usr/libexec/java_home -v 17 2>/dev/null || true)"
  fi
  if [[ -n "$jh" ]] && [[ -x "$jh/bin/java" ]]; then
    printf '%s\n' "$jh"
    return 0
  fi
  for candidate in \
    /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
    /usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
    /opt/homebrew/opt/openjdk@17 \
    /usr/local/opt/openjdk@17; do
    if [[ -x "$candidate/bin/java" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

mode="changed"
base_ref=""
do_format=false
do_fix=false
do_analyze=false
do_test=false
do_android_debug=false
explicit_steps=false

while [[ $# -gt 0 ]]; do
  case "$1" in
  --changed) mode="changed" ;;
  --all) mode="all" ;;
  --base)
    shift
    base_ref="${1:-}"
    if [[ -z "$base_ref" ]]; then
      echo "error: --base requires a git ref" >&2
      exit 2
    fi
    ;;
  --format)
    do_format=true
    explicit_steps=true
    ;;
  --fix)
    do_format=true
    do_fix=true
    explicit_steps=true
    ;;
  --analyze)
    do_analyze=true
    explicit_steps=true
    ;;
  --test)
    do_test=true
    explicit_steps=true
    ;;
  --android-debug)
    do_android_debug=true
    explicit_steps=true
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown option: $1" >&2
    usage >&2
    exit 2
    ;;
  esac
  shift
done

if [[ "$explicit_steps" == false ]]; then
  do_format=true
  do_analyze=true
  do_test=true
fi

CPUS="$(detect_cpus)"
FORMAT_WORKERS="$CPUS"
if [[ "$FORMAT_WORKERS" -gt 8 ]]; then
  FORMAT_WORKERS=8
fi

resolve_base_ref() {
  if [[ -n "$base_ref" ]]; then
    printf '%s\n' "$base_ref"
    return 0
  fi
  for ref in origin/main main HEAD; do
    if git rev-parse --verify --quiet "$ref" >/dev/null; then
      printf '%s\n' "$ref"
      return 0
    fi
  done
  echo "HEAD"
}

collect_changed_files() {
  local base merge_base
  base="$(resolve_base_ref)"
  merge_base="$(git merge-base "$base" HEAD 2>/dev/null || echo "$base")"
  {
    git diff --name-only --diff-filter=ACM "$merge_base" --
    git ls-files --others --exclude-standard
  } | awk 'NF && !seen[$0]++'
}

changed_files=()
changed_dart=()
changed_go=false
changed_scripts=()

if [[ "$mode" == "changed" ]]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ -f "$f" ] || continue
    changed_files+=("$f")
    case "$f" in
    third_party/* | build/* | .dart_tool/*) ;;
    *.dart) changed_dart+=("$f") ;;
    esac
    case "$f" in
    remote/monkeymux/*) changed_go=true ;;
    scripts/* | test/scripts/*) changed_scripts+=("$f") ;;
    esac
  done < <(collect_changed_files)
fi

run_format() {
  if [[ "$mode" == "all" ]]; then
    local format_dirs=()
    local dir
    for dir in lib test tool integration_test test_driver; do
      if [[ -d "$dir" ]]; then
        format_dirs+=("$dir")
      fi
    done
    echo "Running parallel dart format across ${format_dirs[*]} ($FORMAT_WORKERS workers)..."
    if [[ "$do_fix" == true ]]; then
      find "${format_dirs[@]}" -name '*.dart' -print0 \
        | xargs -0 -n 64 -P "$FORMAT_WORKERS" dart format
    else
      find "${format_dirs[@]}" -name '*.dart' -print0 \
        | xargs -0 -n 64 -P "$FORMAT_WORKERS" dart format --output=none --set-exit-if-changed
    fi
    return
  fi

  if [[ "${#changed_dart[@]}" -eq 0 ]]; then
    echo "No changed Dart files to format."
    return
  fi
  echo "Running dart format on ${#changed_dart[@]} changed Dart file(s)..."
  if [[ "$do_fix" == true ]]; then
    dart format -- "${changed_dart[@]}"
  else
    dart format --output=none --set-exit-if-changed -- "${changed_dart[@]}"
  fi
}

run_analyze() {
  local cmd=()
  if command -v python3 >/dev/null 2>&1 && [[ -f "$REPO_ROOT/scripts/dart_analyze_fast.py" ]]; then
    cmd=(python3 "$REPO_ROOT/scripts/dart_analyze_fast.py" --fatal-warnings --fatal-infos)
  else
    cmd=(dart analyze --fatal-warnings --fatal-infos)
  fi

  if [[ "$mode" == "all" ]]; then
    echo "Running analyzer across repository..."
    "${cmd[@]}"
    return
  fi

  if [[ "${#changed_dart[@]}" -eq 0 ]]; then
    echo "No changed Dart files to analyze."
    return
  fi
  echo "Running analyzer on ${#changed_dart[@]} changed Dart file(s)..."
  "${cmd[@]}" -- "${changed_dart[@]}"
}

map_dart_targets_to_tests() {
  python3 - "$REPO_ROOT" "$@" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1]).resolve()
changed = sys.argv[2:]
test_root = root / 'test'

if not test_root.is_dir():
    sys.exit(0)

# Index *_test.dart files and which *_cases.dart files each entrypoint imports.
all_tests = sorted(test_root.rglob('*_test.dart'))
importers_by_cases: dict[Path, list[Path]] = {}
import_re = re.compile(r"""^\s*(?:import|part)\s+['"]([^'"]+_cases\.dart)['"]""", re.M)
for test_file in all_tests:
    try:
        text = test_file.read_text(encoding='utf-8', errors='ignore')
    except OSError:
        continue
    for match in import_re.finditer(text):
        rel = match.group(1)
        if rel.startswith('package:'):
            continue
        target = (test_file.parent / rel).resolve()
        importers_by_cases.setdefault(target, []).append(test_file)

selected: set[Path] = set()

def add_cases_or_tests(candidate_stem: Path) -> None:
    direct = candidate_stem.with_name(candidate_stem.name + '_test.dart')
    if direct.is_file():
        selected.add(direct.resolve())
    cases = candidate_stem.with_name(candidate_stem.name + '_cases.dart').resolve()
    if cases in importers_by_cases:
        for importer in importers_by_cases[cases]:
            selected.add(importer.resolve())

for raw in changed:
    p = (root / raw).resolve()
    if raw.startswith('test/'):
        if raw.endswith('_test.dart') and p.is_file():
            selected.add(p)
        elif raw.endswith('_cases.dart') and p in importers_by_cases:
            for importer in importers_by_cases[p]:
                selected.add(importer.resolve())
    elif raw.startswith('lib/') and raw.endswith('.dart') and not raw.endswith('.g.dart'):
        rel = Path(raw).relative_to('lib')
        stem = test_root / rel.with_suffix('')
        add_cases_or_tests(stem)

for path in sorted(selected):
    print(path.relative_to(root).as_posix())
PY
}

run_tests() {
  if [[ "$mode" == "all" ]]; then
    echo "Running full Flutter test suite (-j $CPUS --no-pub)..."
    flutter test --no-pub -j "$CPUS"
    return
  fi

  local ran_any=false

  if [[ "${#changed_dart[@]}" -gt 0 ]]; then
    local test_targets=()
    while IFS= read -r t; do
      [ -z "$t" ] && continue
      test_targets+=("$t")
    done < <(map_dart_targets_to_tests "${changed_dart[@]}")

    if [[ "${#test_targets[@]}" -gt 0 ]]; then
      echo "Running ${#test_targets[@]} mapped Flutter test file(s) (-j $CPUS --no-pub)..."
      flutter test --no-pub -j "$CPUS" "${test_targets[@]}"
      ran_any=true
    else
      echo "No direct Flutter test mapping found for changed Dart files; pass test paths to 'flutter test --no-pub' if needed."
    fi
  fi

  if [[ "$changed_go" == true ]]; then
    echo "Running Go checks in remote/monkeymux..."
    (
      cd "$REPO_ROOT/remote/monkeymux"
      unformatted="$(gofmt -l .)"
      if [[ -n "$unformatted" ]]; then
        echo "gofmt reported unformatted files:" >&2
        echo "$unformatted" >&2
        exit 1
      fi
      go vet ./...
      go test ./...
    )
    ran_any=true
  fi

  if [[ "${#changed_scripts[@]}" -gt 0 ]]; then
    local py_tests=()
    local rb_tests=()
    local cjs_tests=()
    local f base
    for f in "${changed_scripts[@]}"; do
      case "$f" in
      test/scripts/*_test.py) py_tests+=("$f") ;;
      test/scripts/*_test.rb) rb_tests+=("$f") ;;
      test/scripts/*_test.cjs) cjs_tests+=("$f") ;;
      scripts/build_monkeymux_assets.sh | scripts/verify_monkeymux_assets.py)
        [[ -f "test/scripts/monkeymux_cache_test.py" ]] && py_tests+=("test/scripts/monkeymux_cache_test.py")
        ;;
      scripts/cache_sqlite3_native_assets.sh)
        [[ -f "test/scripts/sqlite_native_assets_test.py" ]] && py_tests+=("test/scripts/sqlite_native_assets_test.py")
        ;;
      scripts/*.py)
        base="$(basename "$f" .py)"
        [[ -f "test/scripts/${base}_test.py" ]] && py_tests+=("test/scripts/${base}_test.py")
        ;;
      esac
    done
    if [[ "${#py_tests[@]}" -gt 0 ]]; then
      local uniq_py=()
      while IFS= read -r t; do
        [ -z "$t" ] && continue
        uniq_py+=("$t")
      done < <(printf '%s\n' "${py_tests[@]}" | sort -u)
      echo "Running Python script tests: ${uniq_py[*]}"
      for t in "${uniq_py[@]}"; do
        python3 -m unittest discover -s "$(dirname "$t")" -p "$(basename "$t")"
      done
      ran_any=true
    fi
    if [[ "${#rb_tests[@]}" -gt 0 ]]; then
      local uniq_rb=()
      while IFS= read -r t; do
        [ -z "$t" ] && continue
        uniq_rb+=("$t")
      done < <(printf '%s\n' "${rb_tests[@]}" | sort -u)
      for t in "${uniq_rb[@]}"; do
        echo "Running Ruby script test: $t"
        ruby "$t"
      done
      ran_any=true
    fi
    if [[ "${#cjs_tests[@]}" -gt 0 ]]; then
      local uniq_cjs=()
      while IFS= read -r t; do
        [ -z "$t" ] && continue
        uniq_cjs+=("$t")
      done < <(printf '%s\n' "${cjs_tests[@]}" | sort -u)
      echo "Running Node script tests: ${uniq_cjs[*]}"
      node --test "${uniq_cjs[@]}"
      ran_any=true
    fi
  fi

  if [[ "$ran_any" == false ]] && [[ "${#changed_dart[@]}" -eq 0 ]]; then
    echo "No changed test targets detected."
  fi
}

run_android_debug() {
  local java17
  if ! java17="$(resolve_java17_home)"; then
    echo "error: JDK 17 not found (checked JAVA_HOME, java_home -v 17, and Homebrew openjdk@17)." >&2
    exit 1
  fi
  echo "Building single-ABI Android private debug APK (JAVA_HOME=$java17)..."
  JAVA_HOME="$java17" PATH="$java17/bin:$PATH" \
    flutter build apk --debug --flavor private --target-platform android-arm64 --no-pub
}

# Run format + analyze in parallel when both are requested without --fix.
if [[ "$do_format" == true ]] && [[ "$do_analyze" == true ]] && [[ "$do_fix" == false ]]; then
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT
  run_format >"$TMP_DIR/format.out" 2>&1 &
  fmt_pid=$!
  run_analyze >"$TMP_DIR/analyze.out" 2>&1 &
  an_pid=$!
  fmt_rc=0
  wait "$fmt_pid" || fmt_rc=$?
  an_rc=0
  wait "$an_pid" || an_rc=$?
  cat "$TMP_DIR/format.out"
  cat "$TMP_DIR/analyze.out"
  if [[ "$fmt_rc" -ne 0 ]] || [[ "$an_rc" -ne 0 ]]; then
    exit 1
  fi
else
  if [[ "$do_format" == true ]]; then
    run_format
  fi
  if [[ "$do_analyze" == true ]]; then
    run_analyze
  fi
fi

if [[ "$do_test" == true ]]; then
  run_tests
fi
if [[ "$do_android_debug" == true ]]; then
  run_android_debug
fi

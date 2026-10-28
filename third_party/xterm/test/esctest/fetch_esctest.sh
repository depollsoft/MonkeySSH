#!/usr/bin/env bash
# Checks out the pinned esctest2 commit that test/esctest/esctest_test.dart
# runs, into DIR. esctest2 is GPL-2.0, so it is fetched at test time and never
# vendored into this repository.
#
#   test/esctest/fetch_esctest.sh DIR
#   ESCTEST_DIR=DIR flutter test test/esctest
#
# Moving to a newer commit changes which tests fail: update ESCTEST2_COMMIT,
# then rerun with ESCTEST_UPDATE=1 to rewrite expected_failures.txt.
set -euo pipefail

# esctest2 of 2026-09-13, the commit Ghostty also pins.
ESCTEST2_COMMIT=2798f12149a19c3295e9b4853ab2da4b2eff1b2b

dir="${1:?usage: fetch_esctest.sh DIR}"
if [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)" = "$ESCTEST2_COMMIT" ]; then
  exit 0
fi

mkdir -p "$dir"
git -C "$dir" init --quiet
git -C "$dir" fetch --quiet --depth 1 \
  https://github.com/ThomasDickey/esctest2.git "$ESCTEST2_COMMIT"
git -C "$dir" checkout --quiet --force --detach FETCH_HEAD
test "$(git -C "$dir" rev-parse HEAD)" = "$ESCTEST2_COMMIT"

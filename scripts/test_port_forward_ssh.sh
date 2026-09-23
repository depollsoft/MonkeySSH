#!/bin/bash
# Exercise port forwarding against real localhost OpenSSH with a temporary key.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/local_ssh_test_env.sh

state_dir="$(mktemp -d "${TMPDIR:-/tmp}/monkeyssh-forward.XXXXXX")"
marker="monkeyssh-forward-$(basename "$state_dir")"
cleanup() {
    local_ssh_test_teardown "$state_dir" "$marker"
    rm -rf "$state_dir"
}
trap cleanup EXIT
local_ssh_test_prepare "$state_dir" "$marker" "$marker"

MONKEYSSH_FORWARD_E2E_KEY="$LOCAL_SSH_TEST_KEY_PATH" \
    flutter test --no-test-assets \
    test/integration/port_forward_ssh_e2e_test.dart "$@"

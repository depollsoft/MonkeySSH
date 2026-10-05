#!/bin/bash
# Sets up localhost SSH, the current MonkeyMux helper, and a fake ACP provider.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/local_ssh_test_env.sh
source "$SCRIPT_DIR/lib/local_ssh_test_env.sh"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/monkeyssh/acp-test"
BIN_DIR="$STATE_DIR/bin"
ENV_FILE="$STATE_DIR/env.sh"
MARKER="# monkeyssh-acp-test"
PROVIDER_LABEL="MonkeySSH ACP E2E"

usage() {
    cat <<'EOF'
Usage:
  ./scripts/setup_acp_test_env.sh
  ./scripts/setup_acp_test_env.sh teardown
  ./scripts/setup_acp_test_env.sh --help

Requires localhost Remote Login, python3, Go, ssh, and ssh-keygen.
EOF
}

stop_test_bridges() {
    local list_json
    if [ ! -x "$BIN_DIR/monkeymux" ] || ! command -v python3 &>/dev/null; then
        return
    fi
    list_json="$("$BIN_DIR/monkeymux" acp list 2>/dev/null || true)"
    printf '%s\n' "$list_json" | python3 -c '
import json, sys
try:
    message = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
for bridge in message.get("bridges", []):
    if bridge.get("provider") == sys.argv[1]:
        print(bridge.get("id", ""))
' "$PROVIDER_LABEL" | while IFS= read -r bridge_id; do
        if [ -n "$bridge_id" ]; then
            "$BIN_DIR/monkeymux" acp stop "$bridge_id" >/dev/null 2>&1 || true
        fi
    done
}

teardown() {
    echo "🧹 Tearing down ACP test environment..."
    stop_test_bridges
    local_ssh_test_teardown "$STATE_DIR" "$MARKER"
    rm -rf "$STATE_DIR"
    echo "✅ ACP teardown complete."
}

cleanup_on_error() {
    local status=$?
    trap - ERR
    teardown
    exit "$status"
}

case "${1:-}" in
    teardown)
        teardown
        exit 0
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    "")
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

for command in go python3 ssh ssh-keygen; do
    if ! command -v "$command" &>/dev/null; then
        echo "❌ Required command not found: $command" >&2
        exit 1
    fi
done

echo "🔧 Setting up ACP over SSH test environment..."
trap cleanup_on_error ERR
mkdir -p "$BIN_DIR"
chmod 700 "$STATE_DIR" "$BIN_DIR"
local_ssh_test_prepare "$STATE_DIR" "monkeyssh-acp-test" "$MARKER"

(cd "$REPO_ROOT/remote/monkeymux" && go build -o "$BIN_DIR/monkeymux" .)
install -m 755 "$SCRIPT_DIR/fake_acp_provider.py" "$BIN_DIR/fake-acp-provider"

REMOTE_HOME="$(ssh -i "$LOCAL_SSH_TEST_KEY_PATH" -o BatchMode=yes \
    -o StrictHostKeyChecking=no localhost 'printf %s "$HOME"')"
REMOTE_CWD="$REMOTE_HOME"
TEST_USER="$(id -un)"

{
    printf 'export MONKEYSSH_RUN_LOCAL_SSH_E2E=%q\n' "1"
    printf 'export MONKEYSSH_ACP_E2E_HOST=%q\n' "localhost"
    printf 'export MONKEYSSH_ACP_E2E_PORT=%q\n' "22"
    printf 'export MONKEYSSH_ACP_E2E_USER=%q\n' "$TEST_USER"
    printf 'export MONKEYSSH_ACP_E2E_KEY=%q\n' "$LOCAL_SSH_TEST_KEY_PATH"
    printf 'export MONKEYSSH_ACP_E2E_BIN=%q\n' "$BIN_DIR"
    printf 'export MONKEYSSH_ACP_E2E_CWD=%q\n' "$REMOTE_CWD"
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"
trap - ERR

echo ""
echo "✅ ACP test environment ready."
echo "  Host:             localhost"
echo "  Port:             22"
echo "  Username:         $TEST_USER"
echo "  SSH key:          $LOCAL_SSH_TEST_KEY_PATH"
echo "  Remote PATH head: $BIN_DIR"
echo "  MonkeyMux helper: $BIN_DIR/monkeymux"
echo "  Provider command: $BIN_DIR/fake-acp-provider"
echo "  Provider label:   $PROVIDER_LABEL"
echo "  Working dir:      $REMOTE_CWD"
echo ""
echo "Run the automated SSH bridge test:"
echo "  source \"$ENV_FILE\""
echo "  flutter test test/integration/acp_ssh_bridge_e2e_test.dart"
echo ""
echo "In MonkeySSH, add the localhost host above and a custom ACP provider whose"
echo "exact command is: $BIN_DIR/fake-acp-provider"
echo ""
echo "Teardown: ./scripts/setup_acp_test_env.sh teardown"

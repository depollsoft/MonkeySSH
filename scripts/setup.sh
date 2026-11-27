#!/bin/bash
# Setup script for Flutty development environment

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
HOOKS_DIR=${FLUTTY_HOOKS_DIR:-$(git rev-parse --git-path hooks)}

install_hook() {
    local hook_name="$1"
    local dest="$HOOKS_DIR/$hook_name"

    # Install a tiny delegating wrapper so hooks always run the current
    # checkout or worktree's scripts/<hook> without drifting stale or breaking
    # when a temporary worktree is removed.
    cat >"$dest" <<EOF
#!/bin/bash
# Delegating git hook installed by scripts/setup.sh
set -euo pipefail
REPO_ROOT=\$(git rev-parse --show-toplevel)
exec "\$REPO_ROOT/scripts/$hook_name" "\$@"
EOF
    chmod +x "$dest"
}

echo 'Setting up Flutty development environment...'

mkdir -p "$HOOKS_DIR"

# Install delegating git hooks
echo "Installing git hooks into $HOOKS_DIR..."
install_hook pre-commit
install_hook pre-push

# Build MonkeyMux assets and fetch Dart/Flutter dependencies in parallel
# (they touch disjoint directories: assets/monkeymux/ vs .dart_tool/).
echo 'Building MonkeyMux assets and installing dependencies in parallel...'
(
    cd "$REPO_ROOT"
    scripts/build_monkeymux_assets.sh &
    mux_pid=$!

    flutter pub get &
    pub_pid=$!

    mux_rc=0
    wait "$mux_pid" || mux_rc=$?
    pub_rc=0
    wait "$pub_pid" || pub_rc=$?

    if [ "$mux_rc" -ne 0 ] || [ "$pub_rc" -ne 0 ]; then
        exit 1
    fi
)

echo "Setup complete! You can now run 'flutter run' or './scripts/dev_check.sh'."

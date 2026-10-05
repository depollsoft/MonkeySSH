#!/bin/bash
# Setup script for Flutty development environment

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
HOOKS_DIR=${FLUTTY_HOOKS_DIR:-$(git rev-parse --git-path hooks)}

install_hook() {
    local source_path="$1"
    local hook_name="$2"

    cp "$source_path" "$HOOKS_DIR/$hook_name"
    chmod +x "$HOOKS_DIR/$hook_name"
}

echo 'Setting up Flutty development environment...'

mkdir -p "$HOOKS_DIR"

# Install git hooks
echo "Installing git hooks into $HOOKS_DIR..."
install_hook "$REPO_ROOT/scripts/pre-commit" pre-commit
install_hook "$REPO_ROOT/scripts/pre-push" pre-push

# Get dependencies
echo 'Installing dependencies...'
(
    cd "$REPO_ROOT"
    scripts/build_monkeymux_assets.sh
    flutter pub get
)

# Run code generation (when we add it)
# echo "Running code generation..."
# dart run build_runner build

echo "Setup complete! You can now run 'flutter run' to start the app."

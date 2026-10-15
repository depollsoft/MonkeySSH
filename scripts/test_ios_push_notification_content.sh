#!/usr/bin/env bash
# Compiles the notification service extension's decryption and text code for
# macOS and checks it against docs/push-notification-vectors.json. Needs Xcode
# (CryptoKit); no simulator or signing.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/push-nse-test.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

xcrun swiftc \
  -o "$WORK_DIR/push-notification-presentation-tests" \
  "$REPO_ROOT/ios/NotificationServiceExtension/PushNotificationPresentation.swift" \
  "$REPO_ROOT/ios/NotificationServiceExtensionTests/main.swift"

"$WORK_DIR/push-notification-presentation-tests" \
  "$REPO_ROOT/docs/push-notification-vectors.json"

#!/bin/bash
# Run the real ShelfModel in a fresh home without launching the app or starting its watchers.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$ROOT" --product Qingyan -j 4
BIN="$(swift build --package-path "$ROOT" --show-bin-path)"
HOME_DIR="$(mktemp -d)"
trap 'rm -rf "$HOME_DIR"' EXIT
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -parse-as-library \
  -I "$BIN/Modules" -I "$BIN/AudioCapture.build" \
  "$ROOT/Tests/ShelfImportChecks.swift" "@$BIN/Qingyan.product/Objects.LinkFileList" \
  -o "$HOME_DIR/ShelfImportChecks"
CFFIXED_USER_HOME="$HOME_DIR" HOME="$HOME_DIR" "$HOME_DIR/ShelfImportChecks" "$HOME_DIR"

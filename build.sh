#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
# Which identity signs the app. The repository's build sets its own (the self-signed "input
# signing" certificate, named before the app was renamed put); without one, the Apple Development certificate the app was first developed with.
# Every build a Mac is to update to must carry the same identity as the one installed there:
# macOS ties the app's permissions to it, and the app refuses an update signed by another.
SIGNING_IDENTITY="${SIGNING_IDENTITY:-0E963B03D3A303855B9F48FD499600DA26CC1930}"
# INPUT_BUILD is the build number (the repository's build passes its run number); the version
# shown becomes 0.1.<build>. Without it the bundle keeps what Resources/Info.plist says.
INPUT_BUILD="${INPUT_BUILD:-}"
case "${1:-}" in
  ""|--install) ;;
  *) printf 'Usage: bash build.sh [--install]\n' >&2; exit 1 ;;
esac
# The app was called Qingyan, then input, before it was renamed put; any of those processes may
# still be running. Only an install replaces the bundle a running copy was started from; a plain
# build goes into build/ and is safe beside it (a packaging job may build while put runs).
if [[ "${1:-}" == --install ]] && { /usr/bin/pgrep -x put >/dev/null || /usr/bin/pgrep -x input >/dev/null || /usr/bin/pgrep -x Qingyan >/dev/null; }; then
  printf 'Quit put before replacing its signed app bundle.\n' >&2
  exit 1
fi
# Only the app. The checks reach into the core with a testable import, which a release build does not allow.
swift build --package-path "$ROOT" -c release --product Qingyan
BIN="$(swift build --package-path "$ROOT" -c release --show-bin-path)"
APP="$ROOT/build/put.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Qingyan" "$APP/Contents/MacOS/put"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# The words of the app in Simplified Chinese (QingyanCore's Localization reads zh-Hans.json), and
# the permission prompts' text for macOS in the same language.
cp "$ROOT/Resources/zh-Hans.json" "$APP/Contents/Resources/zh-Hans.json"
cp -R "$ROOT/Resources/zh-Hans.lproj" "$APP/Contents/Resources/zh-Hans.lproj"
if [[ -n "$INPUT_BUILD" ]]; then
  [[ "$INPUT_BUILD" =~ ^[0-9]+$ ]] || { printf 'INPUT_BUILD must be a number.\n' >&2; exit 1; }
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $INPUT_BUILD" -c "Set :CFBundleShortVersionString 0.1.$INPUT_BUILD" "$APP/Contents/Info.plist"
fi
codesign --force --sign "$SIGNING_IDENTITY" --identifier local.hopo.qingyan "$APP"
codesign --verify --strict "$APP"
printf '\nBuilt: %s\n' "$APP"
if [[ "${1:-}" == --install ]]; then
  DEST="/Applications/put.app"
  if [[ -e "$DEST" ]] && [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist")" != local.hopo.qingyan ]]; then
    printf 'The installation path belongs to another app; leaving it unchanged.\n' >&2
    exit 1
  fi
  ditto "$APP" "$DEST"
  codesign --verify --strict "$DEST"
  LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  if ! "$LSREGISTER" -u "$APP"; then
    printf 'Note: development bundle could not be unregistered; registering the installed app.\n' >&2
  fi
  "$LSREGISTER" -f "$DEST"
  # Retire bundles left from the old names so only one app claims the bundle identifier.
  for OLD in "/Applications/input.app" "/Applications/Qingyan.app" "$ROOT/build/input.app" "$ROOT/build/Qingyan.app"; do
    if [[ -d "$OLD" ]] && [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$OLD/Contents/Info.plist" 2>/dev/null)" == local.hopo.qingyan ]]; then
      "$LSREGISTER" -u "$OLD" || true
      rm -rf "$OLD"
      printf 'Removed old bundle: %s\n' "$OLD"
    fi
  done
  printf 'Installed: %s\n' "$DEST"
fi

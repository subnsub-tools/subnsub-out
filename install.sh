#!/bin/sh
# Installs put, or brings it up to date, on this Mac:
#
#   curl -fsSL https://raw.githubusercontent.com/subnsub-tools/subnsub-put/main/install.sh | sh
#
# It reads put.json (the newest build) from this repository's release "builds", or from our site
# when GitHub cannot be reached, downloads the zip it names, checks the zip's size and SHA-256
# against put.json and the app's bundle ID, version and code signature (it must be signed with the
# "input signing (SUB&SUB)" certificate, as every build is), and only then puts it in
# /Applications/put.app and opens it. What curl downloads carries no quarantine mark, so macOS does
# not stop the first launch the way it stops a disk image opened from a browser; the checks here
# are what stands in for that. Run it as yourself (an administrator account), not with sudo: the
# app has to own its bundle to update itself later.
#
# For testing only: PUT_INSTALL_DIR installs elsewhere (a copy outside /Applications does not
# update itself), PUT_FEED_BASE reads put.json and the zip from other places, PUT_NO_OPEN=1 does
# not open the app.
set -eu

# All of it is one function, called on the last line: a script cut off in transit runs nothing.
main() {
  BUNDLE_ID="local.hopo.qingyan"
  REQUIREMENT='identifier "local.hopo.qingyan" and certificate root = H"5f3964801c4df9f728472f64717dbc410f4e00d8"'
  FEEDS="${PUT_FEED_BASE:-https://github.com/subnsub-tools/subnsub-put/releases/download/builds https://dashboard.subnsub.com/api/input}"
  DIR="${PUT_INSTALL_DIR:-/Applications}"
  APP="$DIR/put.app"

  say() { printf '%s\n' "$*"; }
  fail() { printf 'put: %s\n' "$*" >&2; exit 1; }
  plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }
  # Whether a copy of the app is running from this bundle (the process name says nothing: the
  # bundle left as input.app by the rename runs as put too).
  runs_from() { ps -axo args= 2>/dev/null | awk -v p="$1/Contents/MacOS/" 'index($0, p) == 1 { f = 1 } END { exit !f }'; }

  [ "$(uname -s)" = Darwin ] || fail "put runs on macOS only."
  major="$(sw_vers -productVersion | cut -d. -f1)"
  [ "$major" -ge 14 ] 2>/dev/null || fail "put needs macOS 14 or later (this Mac has $(sw_vers -productVersion))."
  [ "$(id -u)" -ne 0 ] || fail "run this as yourself, without sudo: put has to own its app to update itself."

  work="$(mktemp -d)"
  lock=""
  tmp=""
  old=""
  # However this ends: a swap cut short puts the previous copy back, and what was made goes.
  # A failure keeps its exit status.
  cleanup() {
    status=$?
    if [ -n "$old" ] && [ -d "$old" ] && [ ! -e "$APP" ]; then mv "$old" "$APP" 2>/dev/null || true; fi
    if [ -n "$tmp" ]; then rm -rf "$tmp"; fi
    if [ -n "$lock" ]; then rm -rf "$lock"; fi
    rm -rf "$work"
    exit "$status"
  }
  trap cleanup EXIT
  trap 'exit 130' INT TERM HUP

  # The manifest: the first place that answers.
  base=""
  for feed in $FEEDS; do
    if curl -fsSL --proto '=https,file' --max-time 30 --retry 2 -o "$work/put.json" "$feed/put.json" 2>/dev/null; then
      base="$feed"; break
    fi
  done
  [ -n "$base" ] || fail "could not read the list of versions (put.json). Check the network connection."
  field() { /usr/bin/plutil -extract "$1" raw -o - "$work/put.json" 2>/dev/null; }
  version="$(field version)" || fail "put.json cannot be read."
  file="$(field file)" || fail "put.json names no file."
  size="$(field size)" || fail "put.json gives no size."
  sum="$(field sha256)" || fail "put.json gives no checksum."
  sum="$(printf '%s' "$sum" | tr 'A-F' 'a-f')"
  case "$version" in '' | *[!0-9.]*) fail "put.json names no version." ;; esac
  printf '%s' "$version" | grep -Eq '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,6}$' || fail "put.json names no version."
  [ "$file" = "put-$version.zip" ] || fail "put.json names an unexpected file."
  case "$size" in '' | *[!0-9]*) fail "put.json gives an unexpected size." ;; esac
  case "$sum" in '' | *[!0-9a-f]*) fail "put.json gives an unexpected checksum." ;; esac
  [ "${#sum}" -eq 64 ] || fail "put.json gives an unexpected checksum."

  # The zip: from where put.json came, else from the other places. A zip that arrives and fails
  # its checks is the end of it; only one that cannot be fetched moves on.
  say "Downloading put ${version}..."
  order="$base"
  for feed in $FEEDS; do [ "$feed" = "$base" ] || order="$order $feed"; done
  got=""
  for feed in $order; do
    if curl -fsSL --proto '=https,file' --max-time 300 --retry 2 -o "$work/$file" "$feed/$file" 2>/dev/null; then
      got="$feed"; break
    fi
  done
  [ -n "$got" ] || fail "could not download $file. Check the network connection."
  [ "$(stat -f%z "$work/$file")" = "$size" ] || fail "$file does not have the size put.json gives. Nothing was installed."
  [ "$(shasum -a 256 "$work/$file" | cut -d' ' -f1)" = "$sum" ] || fail "$file does not match put.json's checksum. Nothing was installed."

  mkdir "$work/unpacked"
  ditto -x -k "$work/$file" "$work/unpacked" || fail "could not unpack $file."
  new="$work/unpacked/put.app"
  [ -d "$new" ] || fail "$file holds no put.app."
  [ "$(plist "$new" CFBundleIdentifier)" = "$BUNDLE_ID" ] || fail "the app in $file is not put."
  [ "$(plist "$new" CFBundleShortVersionString)" = "$version" ] || fail "the app in $file is not version $version."
  build="$(plist "$new" CFBundleVersion)"
  case "$build" in '' | *[!0-9]*) fail "the app in $file has no build number." ;; esac

  # One install at a time in this folder; a lock left by an install that is gone is taken over.
  [ -d "$DIR" ] && [ -w "$DIR" ] || fail "cannot write to $DIR. Run this from an administrator account."
  if ! mkdir "$DIR/.put-install.lock" 2>/dev/null; then
    other="$(cat "$DIR/.put-install.lock/pid" 2>/dev/null || true)"
    if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then fail "another install of put is running."; fi
    rm -rf "$DIR/.put-install.lock"
    mkdir "$DIR/.put-install.lock" 2>/dev/null || fail "another install of put is running."
  fi
  lock="$DIR/.put-install.lock"
  printf '%s\n' "$$" > "$lock/pid"

  if [ -e "$APP" ]; then
    [ "$(plist "$APP" CFBundleIdentifier)" = "$BUNDLE_ID" ] || fail "$APP belongs to another app; it was left as it is."
    have="$(plist "$APP" CFBundleVersion || true)"
    case "$have" in
      '' | *[!0-9]*) ;;
      *) if [ "$have" -gt "$build" ]; then
           say "put $(plist "$APP" CFBundleShortVersionString) is installed already, newer than $version. Nothing was changed."
           exit 0
         fi ;;
    esac
  fi

  # The copy that goes in is made beside it, in a folder of this install's own, and checked there.
  tmp="$(mktemp -d "$DIR/.put-install.XXXXXX")" || fail "could not prepare $DIR."
  staged="$tmp/put.app"
  ditto "$new" "$staged" || fail "could not copy put into $DIR."
  xattr -dr com.apple.quarantine "$staged" 2>/dev/null || true
  codesign --verify --strict --all-architectures -R="$REQUIREMENT" "$staged" 2>/dev/null \
    || fail "the app in $file is not signed by put's certificate. Nothing was installed."
  running=false
  if runs_from "$APP"; then running=true; fi
  if [ -e "$APP" ]; then
    old="$tmp/previous.app"
    mv "$APP" "$old" || { old=""; fail "could not replace $APP."; }
  fi
  mv "$staged" "$APP" || fail "could not put the app in $DIR."
  say "Installed put $version in $APP."

  # The app was called input before; a copy of it left in Applications goes to the Trash, unless
  # it is running.
  legacy="$DIR/input.app"
  if [ -d "$legacy" ] && [ "$(plist "$legacy" CFBundleIdentifier)" = "$BUNDLE_ID" ]; then
    if runs_from "$legacy"; then
      say "The old input.app is still running: quit it, move it to the Trash, and open put."
      running=true
    elif mv "$legacy" "$HOME/.Trash/input.app.$$" 2>/dev/null; then
      say "Moved the old input.app to the Trash."
    fi
  fi

  if [ "$running" = true ]; then
    say "put was running: quit it and open it again to use $version."
  elif [ "${PUT_NO_OPEN:-}" != 1 ]; then
    if open "$APP"; then
      say "put is open: allow the microphone and Accessibility on its panel, and enter an API key in its Settings."
    else
      say "put could not be opened from here: open $APP yourself."
    fi
  fi
}

main "$@"

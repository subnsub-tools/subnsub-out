#!/bin/sh
# Installs out, or brings it up to date, on this Mac:
#
#   curl -fsSL https://raw.githubusercontent.com/subnsub-tools/subnsub-out/main/install.sh | sh
#
# It reads out.json (the newest build) from this repository's newest release, or from our site
# when GitHub cannot be reached, downloads the zip it names (from that version's own release, or
# from the site), checks the zip's size and SHA-256
# against out.json and the app's bundle ID, version and code signature (it must be signed with the
# "input signing (SUB&SUB)" certificate, as every build is), and only then puts it in
# /Applications/out.app and opens it. What curl downloads carries no quarantine mark, so macOS does
# not stop the first launch the way it stops a disk image opened from a browser; the checks here
# are what stands in for that. Run it as yourself (an administrator account), not with sudo: the
# app has to own its bundle to update itself later.
#
# For testing only: OUT_INSTALL_DIR installs elsewhere (a copy outside /Applications does not
# update itself), OUT_FEED_BASE reads out.json and the zip from other places (folders or addresses
# holding both, separated by spaces), OUT_NO_OPEN=1 does not open the app. The names they had while
# the app was called put (PUT_INSTALL_DIR, PUT_FEED_BASE, PUT_NO_OPEN) work too.
set -eu

# All of it is one function, called on the last line: a script cut off in transit runs nothing.
main() {
  BUNDLE_ID="local.hopo.qingyan"
  REQUIREMENT='identifier "local.hopo.qingyan" and certificate root = H"5f3964801c4df9f728472f64717dbc410f4e00d8"'
  RELEASES="https://github.com/subnsub-tools/subnsub-out/releases"
  SITE="https://dashboard.subnsub.com/api/input"
  # The testing knobs as they were called while the app was put still work.
  FEEDS="${OUT_FEED_BASE:-${PUT_FEED_BASE:-github site}}"
  # Where a feed keeps the manifest, and a version's zip: on GitHub, the newest release's out.json
  # and the zip in that version's own release; elsewhere, side by side.
  manifest_at() { case "$1" in github) echo "$RELEASES/latest/download/out.json" ;; site) echo "$SITE/out.json" ;; *) echo "$1/out.json" ;; esac; }
  zip_at() { case "$1" in github) echo "$RELEASES/download/v$2/$3" ;; site) echo "$SITE/$3" ;; *) echo "$1/$3" ;; esac; }
  DIR="${OUT_INSTALL_DIR:-${PUT_INSTALL_DIR:-/Applications}}"
  NO_OPEN="${OUT_NO_OPEN:-${PUT_NO_OPEN:-}}"
  APP="$DIR/out.app"

  say() { printf '%s\n' "$*"; }
  fail() { printf 'out: %s\n' "$*" >&2; exit 1; }
  plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }
  # Whether a copy of the app is running from this bundle (the process name says nothing: the
  # bundle left as input.app by the rename runs as out too).
  runs_from() { ps -axo args= 2>/dev/null | awk -v p="$1/Contents/MacOS/" 'index($0, p) == 1 { f = 1 } END { exit !f }'; }

  [ "$(uname -s)" = Darwin ] || fail "out runs on macOS only."
  major="$(sw_vers -productVersion | cut -d. -f1)"
  [ "$major" -ge 14 ] 2>/dev/null || fail "out needs macOS 14 or later (this Mac has $(sw_vers -productVersion))."
  [ "$(id -u)" -ne 0 ] || fail "run this as yourself, without sudo: out has to own its app to update itself."

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
    if curl -fsSL --proto '=https,file' --max-time 30 --retry 2 -o "$work/out.json" "$(manifest_at "$feed")" 2>/dev/null; then
      base="$feed"; break
    fi
  done
  [ -n "$base" ] || fail "could not read the list of versions (out.json). Check the network connection."
  field() { /usr/bin/plutil -extract "$1" raw -o - "$work/out.json" 2>/dev/null; }
  version="$(field version)" || fail "out.json cannot be read."
  file="$(field file)" || fail "out.json names no file."
  size="$(field size)" || fail "out.json gives no size."
  sum="$(field sha256)" || fail "out.json gives no checksum."
  sum="$(printf '%s' "$sum" | tr 'A-F' 'a-f')"
  case "$version" in '' | *[!0-9.]*) fail "out.json names no version." ;; esac
  printf '%s' "$version" | grep -Eq '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,6}$' || fail "out.json names no version."
  [ "$file" = "out-$version.zip" ] || fail "out.json names an unexpected file."
  case "$size" in '' | *[!0-9]*) fail "out.json gives an unexpected size." ;; esac
  case "$sum" in '' | *[!0-9a-f]*) fail "out.json gives an unexpected checksum." ;; esac
  [ "${#sum}" -eq 64 ] || fail "out.json gives an unexpected checksum."

  # The zip: from where out.json came, else from the other places. A zip that arrives and fails
  # its checks is the end of it; only one that cannot be fetched moves on.
  say "Downloading out ${version}..."
  order="$base"
  for feed in $FEEDS; do [ "$feed" = "$base" ] || order="$order $feed"; done
  got=""
  for feed in $order; do
    if curl -fsSL --proto '=https,file' --max-time 300 --retry 2 -o "$work/$file" "$(zip_at "$feed" "$version" "$file")" 2>/dev/null; then
      got="$feed"; break
    fi
  done
  [ -n "$got" ] || fail "could not download $file. Check the network connection."
  [ "$(stat -f%z "$work/$file")" = "$size" ] || fail "$file does not have the size out.json gives. Nothing was installed."
  [ "$(shasum -a 256 "$work/$file" | cut -d' ' -f1)" = "$sum" ] || fail "$file does not match out.json's checksum. Nothing was installed."

  mkdir "$work/unpacked"
  ditto -x -k "$work/$file" "$work/unpacked" || fail "could not unpack $file."
  new="$work/unpacked/out.app"
  [ -d "$new" ] || fail "$file holds no out.app."
  [ "$(plist "$new" CFBundleIdentifier)" = "$BUNDLE_ID" ] || fail "the app in $file is not out."
  [ "$(plist "$new" CFBundleShortVersionString)" = "$version" ] || fail "the app in $file is not version $version."
  build="$(plist "$new" CFBundleVersion)"
  case "$build" in '' | *[!0-9]*) fail "the app in $file has no build number." ;; esac

  # One install at a time in this folder; a lock left by an install that is gone is taken over.
  [ -d "$DIR" ] && [ -w "$DIR" ] || fail "cannot write to $DIR. Run this from an administrator account."
  if ! mkdir "$DIR/.out-install.lock" 2>/dev/null; then
    other="$(cat "$DIR/.out-install.lock/pid" 2>/dev/null || true)"
    if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then fail "another install of out is running."; fi
    rm -rf "$DIR/.out-install.lock"
    mkdir "$DIR/.out-install.lock" 2>/dev/null || fail "another install of out is running."
  fi
  lock="$DIR/.out-install.lock"
  printf '%s\n' "$$" > "$lock/pid"

  if [ -e "$APP" ]; then
    [ "$(plist "$APP" CFBundleIdentifier)" = "$BUNDLE_ID" ] || fail "$APP belongs to another app; it was left as it is."
    have="$(plist "$APP" CFBundleVersion || true)"
    case "$have" in
      '' | *[!0-9]*) ;;
      *) if [ "$have" -gt "$build" ]; then
           say "out $(plist "$APP" CFBundleShortVersionString) is installed already, newer than $version. Nothing was changed."
           exit 0
         fi ;;
    esac
  fi

  # The copy that goes in is made beside it, in a folder of this install's own, and checked there.
  tmp="$(mktemp -d "$DIR/.out-install.XXXXXX")" || fail "could not prepare $DIR."
  staged="$tmp/out.app"
  ditto "$new" "$staged" || fail "could not copy out into $DIR."
  xattr -dr com.apple.quarantine "$staged" 2>/dev/null || true
  codesign --verify --strict --all-architectures -R="$REQUIREMENT" "$staged" 2>/dev/null \
    || fail "the app in $file is not signed by out's certificate. Nothing was installed."
  running=false
  if runs_from "$APP"; then running=true; fi
  if [ -e "$APP" ]; then
    old="$tmp/previous.app"
    mv "$APP" "$old" || { old=""; fail "could not replace $APP."; }
  fi
  mv "$staged" "$APP" || fail "could not move the app into $DIR."
  say "Installed out $version in $APP."

  # The app was called put, and input before that; a copy left in Applications under either name
  # goes to the Trash, unless it is running.
  for name in put input; do
    legacy="$DIR/$name.app"
    if [ -d "$legacy" ] && [ "$(plist "$legacy" CFBundleIdentifier)" = "$BUNDLE_ID" ]; then
      if runs_from "$legacy"; then
        say "The old $name.app is still running: quit it, move it to the Trash, and open out."
        running=true
      elif mv "$legacy" "$HOME/.Trash/$name.app.$$" 2>/dev/null; then
        say "Moved the old $name.app to the Trash."
        # Its Open at login names the bundle just moved: the app looks when it starts (Relocation).
        defaults write local.hopo.qingyan relocatedLoginItemCheck -bool true 2>/dev/null || true
      fi
    fi
  done

  if [ "$running" = true ]; then
    say "out was running: quit it and open it again to use $version."
  elif [ "$NO_OPEN" != 1 ]; then
    if open "$APP"; then
      say "out is open: allow the microphone and Accessibility on its panel, and enter an API key in its Settings."
    else
      say "out could not be opened from here: open $APP yourself."
    fi
  fi
}

main "$@"

#!/bin/bash
# Real microphone checks, separate from the unattended core checks. Requires microphone access.
# For the reported crash: select AirPods as the system input, then run
# bash tools/check-audio.sh BuiltInMicrophoneDevice default BuiltInMicrophoneDevice
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$ROOT" --product Qingyan -j 4
BIN="$(swift build --package-path "$ROOT" --show-bin-path)"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -parse-as-library \
  -I "$BIN/Modules" -I "$BIN/AudioCapture.build" -I "$ROOT/Sources/AudioCapture/include" \
  "$ROOT/Tests/AudioRecorderChecks.swift" "$ROOT/Sources/Qingyan/AudioRecorder.swift" \
  "$BIN/QingyanCore.build/"*.swift.o "$BIN/AudioCapture.build/AudioCapture.m.o" \
  -o "$BIN/AudioRecorderChecks"
exec "$BIN/AudioRecorderChecks" "$@"

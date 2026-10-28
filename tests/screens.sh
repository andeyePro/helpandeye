#!/usr/bin/env bash
# Screenshots and Apple's accessibility audit of every app screen, on each simulator, in light and
# dark mode, at the normal and the largest accessibility text size. Run from app/ on a Mac with
# Xcode and XcodeGen:  ../tests/screens.sh [output folder]
# The screenshots must still be looked at by eye: the audit cannot judge everything.
set -uo pipefail
OUT=${1:-/tmp/helpandeye-screens}
# A small and a large iPhone, and a large iPad; the smallest and largest watch. ONE=1 for a quick
# run on the small iPhone only; WATCH_ONLY=1 for the watches only.
IFS=, read -r -a DEVICES <<< "${DEVICES:-iPhone 17e,iPhone 18 Pro Max,iPad Pro 13-inch (M5)}"
IFS=, read -r -a WATCHES <<< "${WATCHES:-Apple Watch SE 3 (40mm),Apple Watch Ultra 4 (49mm)}"
[ -n "${ONE:-}" ] && DEVICES=("${DEVICES[0]}") && WATCHES=()
[ -n "${WATCH_ONLY:-}" ] && DEVICES=()
rm -rf "$OUT" && mkdir -p "$OUT"
xcodegen generate --quiet
[ ${#DEVICES[@]} -gt 0 ] && { xcodebuild build-for-testing -project helpandeye.xcodeproj -scheme helpandeye \
  -destination "platform=iOS Simulator,name=${DEVICES[0]}" -derivedDataPath DerivedData -quiet || exit 1; }
status=0
for device in "${DEVICES[@]}"; do
  id=$(xcrun simctl list devices available | grep -F "    $device (" | head -1 | grep -oE '[0-9A-F-]{36}')
  [ -n "$id" ] || { echo "SKIP $device: no such simulator"; continue; }
  xcrun simctl boot "$id" 2>/dev/null
  for mode in light dark; do
    for size in large accessibility-extra-extra-extra-large; do
      run="$OUT/${device// /_}/$mode-$size"
      mkdir -p "$run"
      xcrun simctl ui "$id" appearance "$mode"
      xcrun simctl ui "$id" content_size "$size"
      xcrun simctl uninstall "$id" com.andeye.help 2>/dev/null
      xcrun simctl keychain "$id" reset
      TEST_RUNNER_SHOTS_DIR="$run" xcodebuild test-without-building -project helpandeye.xcodeproj -scheme helpandeye \
        -destination "id=$id" -derivedDataPath DerivedData -only-testing:helpandeyeUITests \
        -collect-test-diagnostics never -test-timeouts-enabled YES -maximum-test-execution-time-allowance 300 > "$run/log.txt" 2>&1
      result=$?
      grep -h "^AUDIT " "$run/log.txt" | sort -u > "$run/audit.txt"; grep -h "^ADVICE " "$run/log.txt" | sort -u > "$run/advice.txt"
      echo "$device $mode $size: $( [ $result = 0 ] && echo passed || echo FAILED ), $(wc -l < "$run/audit.txt" | tr -d ' ') audit issues, $(ls "$run"/*.png 2>/dev/null | wc -l | tr -d ' ') screens"
      [ $result = 0 ] || status=1
    done
  done
  xcrun simctl shutdown "$id"
done
# The watch is always dark.
[ ${#WATCHES[@]} -gt 0 ] && { xcodebuild build-for-testing -project helpandeye.xcodeproj -scheme helpandeyeWatch \
  -destination "platform=watchOS Simulator,name=${WATCHES[0]}" -derivedDataPath DerivedData -quiet || exit 1; }
for device in "${WATCHES[@]}"; do
  id=$(xcrun simctl list devices available | grep -F "    $device (" | head -1 | grep -oE '[0-9A-F-]{36}')
  [ -n "$id" ] || { echo "SKIP $device: no such simulator"; continue; }
  xcrun simctl boot "$id" 2>/dev/null
  for size in L AccessibilityXXXL; do
    run="$OUT/${device// /_}/$size"
    mkdir -p "$run"
    xcrun simctl uninstall "$id" com.andeye.help.watchkitapp 2>/dev/null
    TEST_RUNNER_SHOTS_DIR="$run" TEST_RUNNER_TEXT_SIZE="UICTContentSizeCategory$size" xcodebuild test-without-building -project helpandeye.xcodeproj -scheme helpandeyeWatch \
      -destination "id=$id" -derivedDataPath DerivedData -only-testing:helpandeyeWatchUITests \
      -collect-test-diagnostics never -test-timeouts-enabled YES -maximum-test-execution-time-allowance 300 > "$run/log.txt" 2>&1
    result=$?
    grep -h "^AUDIT " "$run/log.txt" | sort -u > "$run/audit.txt"; grep -h "^ADVICE " "$run/log.txt" | sort -u > "$run/advice.txt"
    echo "$device $size: $( [ $result = 0 ] && echo passed || echo FAILED ), $(wc -l < "$run/audit.txt" | tr -d ' ') audit issues, $(ls "$run"/*.png 2>/dev/null | wc -l | tr -d ' ') screens"
    [ $result = 0 ] || status=1
  done
  xcrun simctl shutdown "$id"
done
exit $status

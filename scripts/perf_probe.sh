#!/usr/bin/env bash
# Pull the DEBUG preview-cost stats off a physical iPhone in one shot.
#
# The phone MUST be unlocked and awake: `devicectl` installs and launches hang
# (no output, timeout) while the device is locked.
#
#   bash scripts/perf_probe.sh            # uses the Debug build in .derived-device
#   UDID=<udid> bash scripts/perf_probe.sh
set -euo pipefail

UDID="${UDID:-00008140-001E41291A47001C}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.derived-device/Build/Products/Debug-iphoneos/PocketCCD.app"
OUT="${OUT:-/tmp/pccd-docs}"

if [ ! -d "$APP" ]; then
  echo "missing $APP — build it first:"
  echo "  xcodebuild -project PocketCCD.xcodeproj -scheme PocketCCD -configuration Debug \\"
  echo "    -destination 'platform=iOS,id=$UDID' -derivedDataPath .derived-device build"
  exit 1
fi

echo "1/4 install"
timeout 240 xcrun devicectl device install app --device "$UDID" "$APP"

echo "2/4 launch"
timeout 60 xcrun devicectl device process launch --device "$UDID" work.doublenine.pocketccd

echo "3/4 leave the viewfinder on screen for 15 s"
sleep 15

echo "4/4 pull Documents"
rm -rf "$OUT"; mkdir -p "$OUT"
timeout 120 xcrun devicectl device copy from --device "$UDID" \
  --domain-type appDataContainer --domain-identifier work.doublenine.pocketccd \
  --source Documents --destination "$OUT"

for f in preview-stats.json app-launch.txt camera-prepared.txt; do
  if [ -f "$OUT/$f" ]; then
    echo "--- $f"
    cat "$OUT/$f"
    echo
  else
    echo "--- $f MISSING"
  fi
done

echo
echo "read it as: renderAvgMs near 41 ms or a fast-growing skipped → preview is the bottleneck;"
echo "both healthy but still janky → the per-frame GPU→CPU readback / main-thread handoff is next."

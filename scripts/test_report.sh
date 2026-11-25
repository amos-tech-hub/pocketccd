#!/bin/bash
# Runs the PocketCCD test suite and prints executed/skipped/duration.
#
# Why this exists: a run with missing fixtures skips its fixture-dependent
# cases and still reports "0 failures". A 40 s run and a 6 min run both look
# green. Read the duration and the executed count, never the failure count
# alone. The unit suite is fast; if the whole thing finishes in under a minute,
# nothing that touches a real frame ran.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="${1:-platform=iOS Simulator,name=PocketCCD Store iPhone 17 Pro}"
LOG="${TMPDIR:-/tmp}/pocketccd-test-$(date +%Y%m%d-%H%M%S).log"

START=$(date +%s)
# Keep the summary useful on failure, but never mask the xcodebuild status:
# the previous `|| true` made this script exit 0 even when the suite was red.
set +e
xcodebuild test \
  -project PocketCCD.xcodeproj \
  -scheme PocketCCD \
  -destination "$DEST" \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$LOG" | grep -E 'Test Suite|Executed [0-9]+ test|error:|TEST (SUCCEEDED|FAILED)'
RC=${PIPESTATUS[0]}
set -e
END=$(date +%s)

echo
echo "--- summary ---"
# Swift Testing reports "Test run with N tests in M suites"; XCTest reports
# "Executed N tests". The scheme's XCTest suite is empty, so reading only the
# XCTest line says "0 tests" while 92 Swift Testing cases just ran — the exact
# false-green trap this script exists to catch.
SWIFT=$(grep -oE 'Test run with [0-9]+ tests in [0-9]+ suites (passed|failed)' "$LOG" | tail -1 || true)
XCTEST=$(grep -oE 'Executed [0-9]+ tests?, with [0-9]+ failures' "$LOG" | tail -1 || true)
SKIPPED=$(grep -oE 'with [0-9]+ skipped' "$LOG" | tail -1 || true)
echo "executed: ${SWIFT:-${XCTEST:-unknown}}"
echo "skips:    ${SKIPPED:-none reported}"
echo "duration: $((END - START)) s"
echo "log:      $LOG"
if [ "$((END - START))" -lt 60 ]; then
  echo "warning:  under a minute — check that the frame-dependent suites were not skipped"
fi
exit "$RC"

#!/bin/bash
#
# Run LunaTests and report the result the tests actually produced.
#
# Plain `xcodebuild test` lies on this project. After the suite finishes, it
# tries to collect diagnostics from the simulator, that step times out after a
# fixed 600 seconds, and the run is failed on the timeout alone:
#
#     Test Suite 'Selected tests' passed
#     Executed 2182 tests, with 7 tests skipped and 0 failures
#     IDETestOperationsObserverDebug: Failure collecting diagnostics from
#         simulator: Timed out after 600.0 seconds
#     ** TEST FAILED **                       <- exit 65, nothing wrong
#
# It also means a ~105s suite takes ~12 minutes, and that the log sits
# completely silent for ten of them — which reads exactly like the hung-runner
# mode that a fresh simulator fixes, so it invites killing healthy runs.
#
# The scheme now sets systemAttachmentLifetime/userAttachmentLifetime to
# keepNever, which stops the collection being requested in the common case.
# This script is the backstop for when it is requested anyway: it watches for
# the summary line, gives xcodebuild a short grace period to exit on its own,
# and otherwise stops it and reports what the tests said.
#
# Usage:
#   scripts/run_tests.sh                       # pick/create a simulator
#   scripts/run_tests.sh -d <udid>             # use a specific one
#   scripts/run_tests.sh --fresh               # always create a throwaway sim
#   scripts/run_tests.sh -- -only-testing:...  # pass anything else through
#
# Exit status is the suite's: 0 when it reported no failures, 1 when it did,
# 2 when the run never produced a summary at all (a real infrastructure fail).

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRACE=${LUNA_TEST_GRACE:-45}     # seconds to let xcodebuild finish after the summary
DEVICE=""
FRESH=0
EXTRA=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--device) DEVICE="$2"; shift 2 ;;
    --fresh) FRESH=1; shift ;;
    --) shift; EXTRA+=("$@"); break ;;
    *) EXTRA+=("$1"); shift ;;
  esac
done

# ---------------------------------------------------------------- simulator
if [[ $FRESH -eq 1 || -z "$DEVICE" ]]; then
  if [[ $FRESH -eq 1 ]]; then
    RUNTIME=$(xcrun simctl list runtimes -j | python3 -c "
import json,sys
rs=[r for r in json.load(sys.stdin)['runtimes'] if r['isAvailable'] and 'iOS' in r['name']]
rs.sort(key=lambda r: [int(x) for x in r['version'].split('.')])
print(rs[-1]['identifier'] if rs else '')")
    [[ -z "$RUNTIME" ]] && { echo "no available iOS runtime" >&2; exit 2; }
    DEVICE=$(xcrun simctl create "LunaTests-$$" "iPhone 17 Pro" "$RUNTIME") || exit 2
    echo "created throwaway simulator $DEVICE"
    trap 'echo "deleting $DEVICE"; xcrun simctl delete "$DEVICE" >/dev/null 2>&1' EXIT
  else
    DEVICE=$(xcrun simctl list devices available -j | python3 -c "
import json,sys
d=json.load(sys.stdin)['devices']
best=None
for runtime, devices in d.items():
    if 'iOS' not in runtime: continue
    for dev in devices:
        if not dev.get('isAvailable'): continue
        if 'iPhone' not in dev['name']: continue
        # Prefer one already booted; it saves a cold start.
        rank = (dev['state'] != 'Booted', dev['name'])
        if best is None or rank < best[0]: best = (rank, dev['udid'])
print(best[1] if best else '')")
    [[ -z "$DEVICE" ]] && { echo "no available iPhone simulator" >&2; exit 2; }
  fi
fi
echo "simulator: $DEVICE"

LOG="${LUNA_TEST_LOG:-$(mktemp -t lunatests).log}"
echo "log: $LOG"

# ---------------------------------------------------------------------- run
xcodebuild test \
  -scheme Luna \
  -destination "platform=iOS Simulator,id=$DEVICE" \
  -configuration Debug \
  -derivedDataPath "${LUNA_TEST_DD:-$REPO/.build-dd-tests}" \
  DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO \
  "${EXTRA[@]}" > "$LOG" 2>&1 &
XCB=$!

summary_line() {
  grep -oE "Executed [0-9]+ tests?, with ([0-9]+ tests? skipped and )?[0-9]+ failures?" "$LOG" 2>/dev/null | tail -1
}

SEEN=""
while kill -0 "$XCB" 2>/dev/null; do
  if [[ -z "$SEEN" ]]; then
    SEEN="$(summary_line)"
    if [[ -n "$SEEN" ]]; then
      echo "suite finished: $SEEN"
      echo "allowing ${GRACE}s for xcodebuild to wrap up…"
      DEADLINE=$((SECONDS + GRACE))
      while kill -0 "$XCB" 2>/dev/null && (( SECONDS < DEADLINE )); do sleep 2; done
      if kill -0 "$XCB" 2>/dev/null; then
        echo "still busy after ${GRACE}s (diagnostics collection) — stopping it"
        kill -TERM "$XCB" 2>/dev/null
        sleep 3
        kill -9 "$XCB" 2>/dev/null
      fi
      break
    fi
  fi
  sleep 5
done
wait "$XCB" 2>/dev/null
XCB_STATUS=$?

# ------------------------------------------------------------------ verdict
SUMMARY="$(summary_line)"
if [[ -z "$SUMMARY" ]]; then
  echo
  echo "NO TEST SUMMARY — the run never got as far as executing tests."
  echo "That is a real failure (build error, or the runner never connected)."
  grep -E "^(.*error:|\*\* (BUILD|TEST) FAILED)" "$LOG" | sort -u | head -20
  echo "full log: $LOG"
  exit 2
fi

FAILURES=$(sed -E 's/.*and ([0-9]+) failures?.*/\1/' <<<"$SUMMARY")
echo
echo "================ $SUMMARY ================"
if [[ "$FAILURES" != "0" ]]; then
  echo
  echo "Failing tests:"
  grep -E ": error: -\[" "$LOG" | sed 's/^/  /' | head -40
  echo "full log: $LOG"
  exit 1
fi

# Distinguish "xcodebuild agreed" from "we cut it short", so a genuine
# post-test failure is never silently reported as success.
if grep -q "^\*\* TEST SUCCEEDED \*\*" "$LOG"; then
  echo "xcodebuild agreed: TEST SUCCEEDED"
elif [[ $XCB_STATUS -ne 0 ]]; then
  echo "xcodebuild exited $XCB_STATUS after the suite passed — post-test step only:"
  grep -E "Failure collecting diagnostics|Timed out after" "$LOG" | sed 's/^/  /' | head -3
fi
echo "full log: $LOG"
exit 0

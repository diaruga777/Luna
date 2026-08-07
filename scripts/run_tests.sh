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
# The scheme also sets systemAttachmentLifetime/userAttachmentLifetime to
# keepNever. Measured, that did NOT stop the stall on its own — xcodebuild was
# still busy 45s after a clean run — so this script, not the scheme setting, is
# what makes the verdict correct. It waits for the ROOT suite to close, gives
# xcodebuild a grace period to exit by itself, and otherwise stops it and
# reports what the tests said.
#
# Usage:
#   scripts/run_tests.sh                       # pick/create a simulator
#   scripts/run_tests.sh -d <udid>             # use a specific one
#   scripts/run_tests.sh --fresh               # always create a throwaway sim
#   scripts/run_tests.sh --changed [<base>]    # only the tests the diff reaches
#   scripts/run_tests.sh -- -only-testing:...  # pass anything else through
#
# --changed is an INNER-LOOP convenience: it asks
# scripts/select_changed_tests.py which classes a `git diff <base>` can reach
# (default base HEAD, so it covers uncommitted work) and passes them as
# -only-testing flags. When the selector cannot account for a changed file it
# says so and this falls back to the whole suite — it never quietly runs less
# than it should. A green partial run is not a green suite; run the full one
# before calling a task done.
#
# Exit status is the suite's: 0 when it reported no failures, 1 when it did,
# 2 when the run never produced a summary at all (a real infrastructure fail).

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRACE=${LUNA_TEST_GRACE:-45}     # seconds to let xcodebuild finish after the summary
DEVICE=""
FRESH=0
CHANGED=0
CHANGED_BASE="HEAD"
EXTRA=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--device) DEVICE="$2"; shift 2 ;;
    --fresh) FRESH=1; shift ;;
    --changed)
      CHANGED=1; shift
      # An optional base ref, but only if it isn't the next flag.
      if [[ $# -gt 0 && "$1" != -* ]]; then CHANGED_BASE="$1"; shift; fi ;;
    --) shift; EXTRA+=("$@"); break ;;
    *) EXTRA+=("$1"); shift ;;
  esac
done

# ------------------------------------------------------------ test selection
if [[ $CHANGED -eq 1 ]]; then
  echo "selecting tests reachable from a diff against ${CHANGED_BASE}…"
  SELECTION=$("$REPO/scripts/select_changed_tests.py" "$CHANGED_BASE")
  case $? in
    0)
      while IFS= read -r flag; do
        [[ -n "$flag" ]] && EXTRA+=("$flag")
      done <<<"$SELECTION"
      echo "PARTIAL RUN — this is the inner loop, not a verdict on the suite."
      ;;
    3) echo "WARNING: running the FULL suite instead (see the reason above)." ;;
    4) echo "nothing to run."; exit 0 ;;
    *) echo "selector failed — running the full suite." ;;
  esac
fi

# ---------------------------------------------------------------- simulator
if [[ $FRESH -eq 1 || -z "$DEVICE" ]]; then
  if [[ $FRESH -eq 1 ]]; then
    # The newest iOS 26.x, which is what the suite is measured and documented
    # against — NOT simply the newest runtime installed. A throwaway sim built on
    # an iOS 27 beta runtime aborted a full run mid-suite with "libc++abi: Pure
    # virtual function called!" in a WebKit teardown, which reads like a code
    # regression and is not one. Set LUNA_TEST_RUNTIME to a version prefix
    # ("27", "26.2") to pick deliberately; anything else falls back to newest.
    RUNTIME=$(LUNA_TEST_RUNTIME="${LUNA_TEST_RUNTIME:-26}" xcrun simctl list runtimes -j | python3 -c "
import json,os,sys
want = os.environ.get('LUNA_TEST_RUNTIME', '26')
rs=[r for r in json.load(sys.stdin)['runtimes'] if r['isAvailable'] and 'iOS' in r['name']]
rs.sort(key=lambda r: [int(x) for x in r['version'].split('.')])
preferred=[r for r in rs if r['version'] == want or r['version'].startswith(want + '.')]
pick = (preferred or rs)
print(pick[-1]['identifier'] if pick else '')")
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
  ${EXTRA[@]+"${EXTRA[@]}"} > "$LOG" 2>&1 &
XCB=$!

# xcodebuild prints an "Executed N tests…" line for EVERY suite as it goes, so
# the presence of one means nothing. The run is over only once the ROOT suite
# closes; its summary is then the last such line in the log.
root_finished() {
  grep -qE "Test Suite '(All tests|Selected tests|.*\.xctest)' (passed|failed) at" \
    "$LOG" 2>/dev/null
}

summary_line() {
  grep -oE "Executed [0-9]+ tests?, with ([0-9]+ tests? skipped and )?[0-9]+ failures?" \
    "$LOG" 2>/dev/null | tail -1
}

SEEN=""
while kill -0 "$XCB" 2>/dev/null; do
  if [[ -z "$SEEN" ]] && root_finished; then
    SEEN="$(summary_line)"
    if [[ -n "$SEEN" ]]; then
      echo "suite finished: $SEEN"
      echo "allowing ${GRACE}s for xcodebuild to wrap up…"
      DEADLINE=$((SECONDS + GRACE))
      while kill -0 "$XCB" 2>/dev/null && (( SECONDS < DEADLINE )); do sleep 2; done
      if kill -0 "$XCB" 2>/dev/null; then
        echo "xcodebuild still busy ${GRACE}s after the suite closed — stopping it"
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

# "…with 0 failures" and "…with 7 tests skipped and 1 failure" both end in the
# count we want, so take the last "<n> failure(s)" in the line.
FAILURES=$(grep -oE "[0-9]+ failures?" <<<"$SUMMARY" | tail -1 | cut -d' ' -f1)
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
  echo "xcodebuild exited $XCB_STATUS after the suite passed — a post-test step, not the tests:"
  grep -E "Failure collecting diagnostics|Timed out after" "$LOG" | sed 's/^/  /' | head -3
fi
echo "full log: $LOG"
exit 0

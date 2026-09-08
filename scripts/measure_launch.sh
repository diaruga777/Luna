#!/bin/bash
#
# Measure cold-launch time for one Luna app on a physical device, and print the
# numbers the size/refactor work is judged against.
#
# Usage:
#   scripts/measure_launch.sh <Luna|LunaReader> [--device <udid>] [--label <name>]
#
# What it does:
#   1. Terminates any running copy of the app on the device.
#   2. Runs the LaunchPerf test plan in RELEASE configuration.
#   3. Reads the per-iteration launch durations out of the .xcresult.
#   4. Prints mean, standard deviation, min, max and every iteration, for both
#      metrics, and writes the same numbers as JSON.
#
# RELEASE, not Debug. A Debug build links the debug-dylib arrangement and
# compiles at -Onone, so its dyld and first-frame cost do not describe the
# shipping binary. The whole point of this measurement is dyld cost, so Debug
# would measure the wrong thing.
#
# Do NOT add CODE_SIGNING_ALLOWED=NO. It strips the app-group entitlement and
# the app dies at launch on its first container access. Automatic signing with
# team MM5QBNLXR6 is already configured.
#
# The two metrics:
#   testLaunchPerformance             process start -> first frame
#   testLaunchToResponsivePerformance process start -> app answers accessibility
#
# XCTest launches one extra warm-up iteration per metric and drops it, so ten
# iterations are reported.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-26.2.0.app/Contents/Developer}"

OUT_DIR="${LUNA_LAUNCH_OUT:-/private/tmp/claude-501/-Users-hsp-Desktop-Lune/0ce06c9e-b7f9-484a-9547-b90401fbae15/scratchpad/launch}"
DD="$OUT_DIR/dd"

# Harry's iPhone 11, reachable over the local network.
DEVICE="${LUNA_LAUNCH_DEVICE:-5431A3BA-3404-59CA-A867-D94B0C3ED36C}"
LABEL="run"
APP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    -h|--help) sed -n '3,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) APP="$1"; shift ;;
  esac
done

case "$APP" in
  Luna)       TEST_TARGET="LunaLaunchTests";       BUNDLE_ID="com.hsanabria.luna" ;;
  LunaReader) TEST_TARGET="LunaReaderLaunchTests"; BUNDLE_ID="com.hsanabria.luna.reader" ;;
  *) echo "usage: $(basename "$0") <Luna|LunaReader> [--device <udid>] [--label <name>]" >&2; exit 2 ;;
esac

mkdir -p "$OUT_DIR"

# devicectl and xcodebuild name the same phone differently: devicectl uses its
# own identifier (5431A3BA-…), xcodebuild wants the HARDWARE udid
# (00008030-…). Passing the devicectl one gets "Unable to find a device
# matching the provided destination specifier". Resolve both from the device
# list, so either identifier works on the command line.
DC_JSON="$OUT_DIR/devices.json"
xcrun devicectl list devices --quiet --json-output "$DC_JSON" >/dev/null 2>&1
RESOLVED="$(DEVICE="$DEVICE" python3 "$REPO/scripts/resolve_device.py" "$DC_JSON")"
DC_DEVICE="$(cut -f1 <<<"$RESOLVED")"
HW_UDID="$(cut -f2 <<<"$RESOLVED")"
if [[ -z "$HW_UDID" ]]; then
  echo "device $DEVICE is not in \`xcrun devicectl list devices\`." >&2
  echo "The phone must be awake, unlocked and on the same network." >&2
  exit 2
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT="$OUT_DIR/$LABEL-$APP-$STAMP.xcresult"
LOG="$OUT_DIR/$LABEL-$APP-$STAMP.log"
JSON="$OUT_DIR/$LABEL-$APP.json"
rm -rf "$RESULT"

echo "app:      $APP ($BUNDLE_ID)"
echo "device:   $HW_UDID (devicectl $DC_DEVICE)"
echo "label:    $LABEL"
echo "result:   $RESULT"
echo "log:      $LOG"

# ------------------------------------------------------- leave a clean device
# A copy still running would be re-launched rather than cold-started, and the
# first iteration would read low. The test relaunches anyway; this makes it
# certain. Absence of the process is the normal case, so a failure here is not
# an error.
# devicectl reports executable PATHS, not bundle ids, so match the .app.
PIDS="$(xcrun devicectl device info processes --device "$DC_DEVICE" -t 60 2>/dev/null \
        | awk -v needle="/$APP.app/" 'index($2, needle) {print $1}')"
for pid in $PIDS; do
  [[ "$pid" =~ ^[0-9]+$ ]] || continue
  echo "terminating pid $pid"
  xcrun devicectl device process terminate --device "$DC_DEVICE" --pid "$pid" --kill --quiet 2>/dev/null
done

# ------------------------------------------------------------------------ run
run_xcodebuild() {
  xcodebuild test \
    -project "$REPO/Luna.xcodeproj" \
    -scheme "$APP" \
    -testPlan LaunchPerf \
    -only-testing:"$TEST_TARGET" \
    -destination "platform=iOS,id=$HW_UDID" \
    -configuration Release \
    -derivedDataPath "$DD" \
    -resultBundlePath "$RESULT" \
    -allowProvisioningUpdates \
    DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO
}

run_xcodebuild > "$LOG" 2>&1
STATUS=$?

# The device has to be unlocked and trusted to install and launch. Those three
# failures are transient often enough to be worth ONE retry, and never worth a
# loop: after the retry the exact error text is the answer.
if [[ $STATUS -ne 0 ]] && grep -qiE "device is locked|is not unlocked|Unable to install|untrusted|not paired|code ?sign|provisioning profile|Failed to prepare device" "$LOG"; then
  echo "run failed on a device/signing condition — retrying once in 60s"
  grep -iE "error:|Unable to install|device is locked" "$LOG" | sort -u | head -5 | sed 's/^/  /'
  sleep 60
  rm -rf "$RESULT"
  run_xcodebuild > "$LOG" 2>&1
  STATUS=$?
fi

if [[ ! -d "$RESULT" ]] || ! grep -q "Executed [0-9]* test" "$LOG"; then
  echo
  echo "NO MEASUREMENTS — the run never executed a test. xcodebuild exit $STATUS."
  grep -iE "error:|Unable to install|Unable to find a device|device is locked|\*\* (TEST|BUILD) FAILED" "$LOG" | sort -u | head -20
  echo "full log: $LOG"
  exit 3
fi

grep -E "Executed [0-9]+ test" "$LOG" | tail -2

# --------------------------------------------------------------- the numbers
# Pinned for Xcode 26.2 (xcresulttool 24514). `get test-results metrics` is the
# supported reader; the older `get object --legacy` graph walk is deprecated and
# will be removed. --compact keeps the JSON on one line.
METRICS_JSON="$OUT_DIR/$LABEL-$APP-$STAMP.metrics.json"
xcrun xcresulttool get test-results metrics --path "$RESULT" --compact > "$METRICS_JSON" 2>"$METRICS_JSON.err"
if [[ ! -s "$METRICS_JSON" ]]; then
  echo "xcresulttool produced no metrics:"; cat "$METRICS_JSON.err"; exit 3
fi

APP="$APP" LABEL="$LABEL" DEVICE="$HW_UDID" STAMP="$STAMP" \
RESULT="$RESULT" JSON="$JSON" METRICS_JSON="$METRICS_JSON" \
python3 - <<'PY'
import json, os, statistics, sys

raw = json.load(open(os.environ["METRICS_JSON"]))
# The reader has returned either a bare list of TestWithMetrics or a dict with
# one list inside it, depending on point release. Accept both.
if isinstance(raw, dict):
    for key in ("testMetrics", "tests", "metrics", "testsWithMetrics"):
        if isinstance(raw.get(key), list):
            raw = raw[key]
            break
    else:
        raw = next((v for v in raw.values() if isinstance(v, list)), [])

report = {
    "app": os.environ["APP"],
    "label": os.environ["LABEL"],
    "device": os.environ["DEVICE"],
    "timestamp": os.environ["STAMP"],
    "configuration": "Release",
    "resultBundle": os.environ["RESULT"],
    "metrics": [],
}

for test in raw:
    ident = test.get("testIdentifier", "?")
    for run in test.get("testRuns", []):
        for metric in run.get("metrics", []):
            values = [float(v) for v in metric.get("measurements", [])]
            if not values:
                continue
            unit = metric.get("unitOfMeasurement", "")
            scale = 1000.0 if unit in ("s", "seconds") else 1.0
            ms = [v * scale for v in values]
            report["metrics"].append({
                "test": ident,
                "metric": metric.get("displayName", "?"),
                "identifier": metric.get("identifier", ""),
                "unitOfMeasurement": unit,
                "iterations": len(ms),
                "mean_ms": round(statistics.fmean(ms), 2),
                "stddev_ms": round(statistics.stdev(ms), 2) if len(ms) > 1 else 0.0,
                # One stalled iteration moves the mean by several percent. Read
                # the median next to it before calling a change real.
                "median_ms": round(statistics.median(ms), 2),
                "min_ms": round(min(ms), 2),
                "max_ms": round(max(ms), 2),
                "values_ms": [round(v, 2) for v in ms],
                "device": run.get("device", {}).get("deviceName", ""),
            })

if not report["metrics"]:
    print("the result bundle holds no performance measurements", file=sys.stderr)
    print(json.dumps(raw)[:2000], file=sys.stderr)
    sys.exit(3)

for entry in report["metrics"]:
    print()
    print(f"{entry['test']}  [{entry['metric']}, {entry['unitOfMeasurement']}]")
    print(f"  iterations {entry['iterations']}")
    print(f"  mean       {entry['mean_ms']:.2f} ms")
    print(f"  stddev     {entry['stddev_ms']:.2f} ms"
          f"  ({entry['stddev_ms'] / entry['mean_ms'] * 100:.1f}% relative)")
    print(f"  median     {entry['median_ms']:.2f} ms")
    print(f"  min        {entry['min_ms']:.2f} ms")
    print(f"  max        {entry['max_ms']:.2f} ms")
    print("  values     " + ", ".join(f"{v:.1f}" for v in entry["values_ms"]))

path = os.environ["JSON"]
with open(path, "w") as handle:
    json.dump(report, handle, indent=2)
    handle.write("\n")
# Keep the per-run copy too, so a second run under the same label does not
# erase the first.
with open(path.replace(".json", f"-{os.environ['STAMP']}.json"), "w") as handle:
    json.dump(report, handle, indent=2)
    handle.write("\n")
print()
print(f"wrote {path}")
PY
PY_STATUS=$?

echo "full log: $LOG"
exit $(( PY_STATUS != 0 ? PY_STATUS : (STATUS != 0 ? 1 : 0) ))

#!/bin/bash
set -euo pipefail

# Stage 1B harness. Deterministic Vault tests run on the Luna iOS test host;
# no live provider is contacted unless the caller explicitly opts in.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="emulator"
DEVICE=""
PROVIDER="device"
LIVE=0
EXTRA=()

usage() {
  cat <<'USAGE'
Usage: scripts/run_vault_tests.sh [--unit|--emulator|--device UDID]
       [--provider device|icloud|mac] [--live-provider device|icloud|mac] [-- ...]

The iCloud and Mac provider modes require --live-provider explicitly. Device
and deterministic tests never access an external service. Tailscale is not
embedded by this harness; live Mac tests use the separately installed client.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --unit) MODE="unit"; shift ;;
    --emulator) MODE="emulator"; shift ;;
    --device) MODE="device"; DEVICE="${2:?missing UDID}"; shift 2 ;;
    --provider) PROVIDER="${2:?missing provider}"; shift 2 ;;
    --live-provider) PROVIDER="${2:?missing provider}"; LIVE=1; shift 2 ;;
    --) shift; EXTRA+=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$PROVIDER" in
  device|icloud|mac) ;;
  *) echo "unsupported v1 provider '$PROVIDER'; use device, icloud, or mac" >&2; exit 2 ;;
esac
if [[ "$PROVIDER" != "device" && "$LIVE" -ne 1 ]]; then
  echo "provider '$PROVIDER' requires explicit --live-provider consent" >&2
  exit 2
fi

if [[ "$MODE" == "unit" ]]; then
  exec swift build --package-path "$REPO/LunaLibraries" --target VaultTestKit ${EXTRA[@]+"${EXTRA[@]}"}
fi

if [[ "$MODE" == "emulator" ]]; then
  DEVICE=$(xcrun simctl list devices available -j | python3 -c '
import json,sys
data=json.load(sys.stdin)["devices"]
devices_for_runtime=data.get("com.apple.CoreSimulator.SimRuntime.iOS-26-2", [])
for device in devices_for_runtime:
    if device.get("isAvailable") and device.get("state") == "Booted" and "iPhone" in device.get("name", ""):
        print(device["udid"]); raise SystemExit
for device in devices_for_runtime:
    if device.get("isAvailable") and "iPhone" in device.get("name", ""):
        print(device["udid"]); raise SystemExit
for devices in data.values():
    for device in devices:
        if device.get("isAvailable") and device.get("state") == "Booted" and "iPhone" in device.get("name", ""):
            print(device["udid"]); raise SystemExit
')
fi
[[ -n "$DEVICE" ]] || { echo "no iPhone simulator/device available" >&2; exit 2; }

export LUNA_VAULT_TEST_PROVIDER="$PROVIDER"
DESTINATION="platform=iOS Simulator,id=$DEVICE"
[[ "$MODE" == "device" ]] && DESTINATION="platform=iOS,id=$DEVICE"
exec xcodebuild test -scheme Luna \
  -destination "$DESTINATION" \
  -only-testing:LunaTests/VaultScaffoldTests \
  -derivedDataPath "${LUNA_VAULT_TEST_DD:-$REPO/.build-dd-vault}" \
  ${EXTRA[@]+"${EXTRA[@]}"}

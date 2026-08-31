#!/bin/bash
set -euo pipefail

# Stage 1B harness. Deterministic Vault tests run on the Luna iOS test host;
# no live provider is contacted unless the caller explicitly opts in.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="emulator"
DEVICE=""
PROVIDER="device"
LIVE=0
PERFORMANCE=0
TEST_PLAN="LunaVault"
EXTRA=()

usage() {
  cat <<'USAGE'
Usage: scripts/run_vault_tests.sh [--unit|--emulator|--device UDID] [--performance]
       [--provider device|icloud|mac] [--live-provider device|icloud|mac] [-- ...]

The iCloud and Mac provider modes require --live-provider explicitly. Device
and deterministic tests never access an external service and never start the
embedded Tailscale node; live Mac tests need a tailnet login on both devices.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --unit) MODE="unit"; shift ;;
    --emulator) MODE="emulator"; shift ;;
    --device) MODE="device"; DEVICE="${2:?missing UDID}"; shift 2 ;;
    --provider) PROVIDER="${2:?missing provider}"; shift 2 ;;
    --live-provider) PROVIDER="${2:?missing provider}"; LIVE=1; shift 2 ;;
    --performance) PERFORMANCE=1; TEST_PLAN="LunaVaultPerformance"; shift ;;
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
if [[ "$PROVIDER" == "icloud" || "$PROVIDER" == "mac" ]]; then
  echo "NOT IMPLEMENTED: live '$PROVIDER' Vault tests do not exist yet" >&2
  echo "No deterministic substitute was run." >&2
  exit 3
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
if [[ "$PERFORMANCE" -eq 1 ]]; then
  export LUNA_VAULT_PERFORMANCE=1
fi
DESTINATION="platform=iOS Simulator,id=$DEVICE"
[[ "$MODE" == "device" ]] && DESTINATION="platform=iOS,id=$DEVICE"
TIMEOUT_ARGS=()
if [[ "$PERFORMANCE" -eq 1 ]]; then
  # Xcode 26.2 ignores the test-plan JSON allowance for the individual test
  # when an explicit test selector is supplied; pass both XCTest overrides so
  # the performance-only plan gets its documented 20-minute execution cap.
  TIMEOUT_ARGS=(-default-test-execution-time-allowance 1200 -maximum-test-execution-time-allowance 1200)
fi
exec xcodebuild test -scheme LunaVaultTests -testPlan "$TEST_PLAN" \
  -destination "$DESTINATION" \
  -only-testing:LunaTests/VaultScaffoldTests \
  -only-testing:LunaTests/VaultCryptoStorageTests \
  -only-testing:LunaTests/VaultExtractionTests \
  -only-testing:LunaTests/VaultSearchTests \
  -only-testing:LunaTests/VaultBackendTests \
  -only-testing:LunaTests/VaultStage5Tests \
  -only-testing:LunaTests/VaultStage5SetupTests \
  -only-testing:LunaTests/VaultStage5IntegrationTests \
  -derivedDataPath "${LUNA_VAULT_TEST_DD:-$REPO/.build-dd-vault}" \
  ${TIMEOUT_ARGS[@]+"${TIMEOUT_ARGS[@]}"} \
  ${EXTRA[@]+"${EXTRA[@]}"}

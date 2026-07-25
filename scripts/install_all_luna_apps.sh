#!/bin/sh
# Build all four Luna apps and install every one of them on a device or
# simulator in a single command.
#
# The "AllLunaApps" scheme already builds all four in one press, but Xcode's
# Run action only ever *installs* the scheme's runnable (Luna). Installing the
# other three is what this script adds.
#
# Usage:
#   scripts/install_all_luna_apps.sh                  # the booted simulator
#   scripts/install_all_luna_apps.sh <simulator-udid>
#   scripts/install_all_luna_apps.sh <device-udid>    # physical iPhone/iPad
#   scripts/install_all_luna_apps.sh "iPhone 17"      # simulator by name
#
# Pass --no-launch to install without launching the central Luna app at the end.

set -eu

cd "$(dirname "$0")/.."

SCHEME="AllLunaApps"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA="${DERIVED_DATA:-.build-dd-install}"
APPS="Luna LunaReader LunaDownloader LunaPriceTracker"
LAUNCH=1

for arg in "$@"; do
    case "$arg" in
        --no-launch) LAUNCH=0 ;;
        *) TARGET="$arg" ;;
    esac
done

# ── Resolve the destination ────────────────────────────────────────────────
# simctl is authoritative for simulators, so ask it first and treat anything it
# does not recognise as a physical device. Do NOT try to classify by devicectl's
# "connected" column: devicectl reports booted simulators as connected too.
#
# Physical devices carry two different identifiers and both are needed:
#   hardwareProperties.udid  the ECID (00008140-…) that -destination wants
#   identifier               the CoreDevice UUID (ECC34E5E-…) that
#                            `devicectl device install` wants
# They are equal for simulators and differ for real hardware, which is also how
# the two are told apart below.
resolve_simulator() {
    # $1 is a UDID or a device name; echoes the UDID, preferring a booted one.
    xcrun simctl list devices available -j |
        python3 -c '
import json, sys
want = sys.argv[1]
data = json.load(sys.stdin)["devices"]
matches = [d for ds in data.values() for d in ds
           if d["udid"] == want or d["name"] == want]
if not matches:
    sys.exit(1)
matches.sort(key=lambda d: d["state"] != "Booted")
print(matches[0]["udid"])' "$1"
}

booted_simulator() {
    xcrun simctl list devices booted -j |
        python3 -c '
import json, sys
for ds in json.load(sys.stdin)["devices"].values():
    for d in ds:
        print(d["udid"]); sys.exit(0)
sys.exit(1)'
}

resolve_device() {
    # $1 is an ECID, a CoreDevice UUID, or a device name; echoes "<ecid> <uuid>".
    json="$(mktemp)"
    xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || true
    python3 -c '
import json, sys
want = sys.argv[1]
devices = json.load(open(sys.argv[2]))["result"]["devices"]
for d in devices:
    ecid = d.get("hardwareProperties", {}).get("udid")
    uuid = d.get("identifier")
    name = d.get("deviceProperties", {}).get("name")
    if not ecid or ecid == uuid:   # equal identifiers mean this is a simulator
        continue
    if want in (ecid, uuid, name):
        print(ecid, uuid)
        sys.exit(0)
sys.exit(1)' "$1" "$json"
    status=$?
    rm -f "$json"
    return $status
}

list_devices() {
    echo "       Available simulators: xcrun simctl list devices available" >&2
    echo "       Connected devices:" >&2
    xcrun devicectl list devices 2>/dev/null | awk '$NF == "physical" { $NF = ""; print "        " $0 }' >&2
}

KIND=""
if [ -n "${TARGET:-}" ]; then
    if UDID="$(resolve_simulator "$TARGET")"; then
        KIND=simulator
    elif RESOLVED="$(resolve_device "$TARGET")"; then
        KIND=device
        UDID="${RESOLVED% *}"
        DEVICE_UUID="${RESOLVED#* }"
    else
        echo "error: no available simulator or connected device matches '$TARGET'." >&2
        list_devices
        exit 1
    fi
else
    if UDID="$(booted_simulator)"; then
        KIND=simulator
    else
        echo "error: no simulator is booted and no destination was given." >&2
        list_devices
        exit 1
    fi
fi

if [ "$KIND" = device ]; then
    DESTINATION="platform=iOS,id=$UDID"
    PRODUCTS="$DERIVED_DATA/Build/Products/$CONFIGURATION-iphoneos"
else
    DESTINATION="platform=iOS Simulator,id=$UDID"
    PRODUCTS="$DERIVED_DATA/Build/Products/$CONFIGURATION-iphonesimulator"
    xcrun simctl boot "$UDID" 2>/dev/null || true
    xcrun simctl bootstatus "$UDID" -b >/dev/null
fi

echo "▸ Building '$SCHEME' ($CONFIGURATION) for $KIND $UDID"

# DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO silences a known Xcode 26 swift-build
# validator bug (swiftlang/swift-build#975); see CLAUDE.md. It only takes effect
# as a build-invocation override, which is why it lives here and not in an
# xcconfig.
xcodebuild build \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" \
    -allowProvisioningUpdates \
    DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO

for app in $APPS; do
    bundle="$PRODUCTS/$app.app"
    [ -d "$bundle" ] || { echo "error: $bundle was not built." >&2; exit 1; }
    echo "▸ Installing $app.app"
    if [ "$KIND" = device ]; then
        xcrun devicectl device install app --device "$DEVICE_UUID" "$bundle" >/dev/null
    else
        xcrun simctl install "$UDID" "$bundle"
    fi
done

echo "▸ Installed all 4 Luna apps on $KIND $UDID"

if [ "$LAUNCH" = 1 ]; then
    # PRODUCT_BUNDLE_PREFIX lives in Config/Luna.xcconfig; read it rather than
    # hard-coding com.hsanabria.luna, so a namespace rename keeps working.
    prefix="$(xcodebuild -project Luna.xcodeproj -target Luna -showBuildSettings \
        -configuration "$CONFIGURATION" 2>/dev/null |
        awk '$1 == "PRODUCT_BUNDLE_PREFIX" { print $3 }')"
    echo "▸ Launching $prefix"
    if [ "$KIND" = device ]; then
        xcrun devicectl device process launch --device "$DEVICE_UUID" "$prefix" >/dev/null
    else
        xcrun simctl launch "$UDID" "$prefix" >/dev/null
    fi
fi

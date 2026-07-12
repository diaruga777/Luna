#!/bin/sh
# Regenerates the PiP guide clips from the live UIKit onboarding illustration.
#
# This runs before Copy Bundle Resources for every Luna app target. It does no
# work unless OnboardingAnimationView.swift changed (or a generated clip is
# missing), and only attempts recording from a Debug iOS Simulator build. Device
# and Archive builds stay fast and use the last known-good bundled clips.

set -u

if [ "${LUNA_GUIDE_VIDEO_RECORDING:-}" = "1" ]; then
    # The nested xcodebuild test invocation builds the Luna scheme too. Prevent its
    # own build phase from recursively launching another recorder.
    exit 0
fi

if [ "${LUNA_SKIP_GUIDE_VIDEO_RECORDING:-}" = "1" ]; then
    echo "note: Skipping onboarding PiP-guide recording (LUNA_SKIP_GUIDE_VIDEO_RECORDING=1)."
    exit 0
fi

if [ "${CONFIGURATION:-}" != "Debug" ] || [ "${PLATFORM_NAME:-}" != "iphonesimulator" ]; then
    exit 0
fi

SOURCE_FILE="${SRCROOT}/LunaLibraries/Sources/LunaSocialUI/OnboardingAnimationView.swift"
RESOURCE_DIR="${SRCROOT}/Luna/Resources"
STAMP_FILE="${RESOURCE_DIR}/.onboarding-guide-video-source.sha256"
GUIDES="\
SafariExtensionGuideReaderLight.mp4 SafariExtensionGuideReaderDark.mp4 \
SafariExtensionGuideDownloaderLight.mp4 SafariExtensionGuideDownloaderDark.mp4 \
SafariExtensionGuidePriceTrackerLight.mp4 SafariExtensionGuidePriceTrackerDark.mp4 \
ActionButtonGuideReaderLight.mp4 ActionButtonGuideReaderDark.mp4 \
ActionButtonGuideDownloaderLight.mp4 ActionButtonGuideDownloaderDark.mp4 \
ActionButtonGuidePriceTrackerLight.mp4 ActionButtonGuidePriceTrackerDark.mp4"

if [ ! -f "$SOURCE_FILE" ]; then
    echo "warning: Onboarding PiP-guide source is missing: $SOURCE_FILE"
    exit 0
fi

source_hash=$(/usr/bin/shasum -a 256 "$SOURCE_FILE" | /usr/bin/awk '{ print $1 }')

guides_exist() {
    for guide in $GUIDES; do
        [ -s "${RESOURCE_DIR}/${guide}" ] || return 1
    done
    return 0
}

recording_is_current() {
    [ -f "$STAMP_FILE" ] && [ "$(/bin/cat "$STAMP_FILE")" = "$source_hash" ] && guides_exist
}

if recording_is_current; then
    exit 0
fi

# Xcode can build multiple host targets in parallel. Serialize source-resource
# writes, then re-check after acquiring the lock in case another target recorded
# the same source while this process waited.
LOCK_DIR="${TMPDIR:-/tmp}/luna-onboarding-guide-video-recording.lock"
attempt=0
while ! /bin/mkdir "$LOCK_DIR" 2>/dev/null; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 120 ]; then
        echo "warning: Timed out waiting for onboarding PiP-guide recording. Re-run a Debug simulator build or record manually."
        exit 0
    fi
    /bin/sleep 0.5
done

recording_dir=""
cleanup() {
    [ -z "$recording_dir" ] || /bin/rm -rf "$recording_dir"
    /bin/rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

if recording_is_current; then
    exit 0
fi

# iOS 26 is the minimum deployment target. Pick an already booted compatible
# simulator rather than booting or mutating a developer's Simulator state.
SIMULATOR_ID=$(
    /usr/bin/xcrun simctl list devices available | /usr/bin/awk '
        /^-- iOS 2[67]\./ { eligible = 1; next }
        /^-- / { eligible = 0 }
        eligible && /\(Booted\)/ {
            # Device lines contain two parenthesized values: the UDID followed by
            # the state. Taking the first one avoids greedily returning "Booted".
            split($0, fields, "(")
            identifier = fields[2]
            sub(/\).*/, "", identifier)
            print identifier
            exit
        }
    '
)

if [ -z "$SIMULATOR_ID" ]; then
    echo "warning: No booted iOS 26+ simulator; onboarding PiP guides were not re-recorded. Record them manually or build again with a compatible simulator running."
    exit 0
fi

recording_dir=$(/usr/bin/mktemp -d "${TARGET_TEMP_DIR:-${TMPDIR:-/tmp}}/OnboardingGuideVideos.XXXXXX") || {
    echo "warning: Could not create a temporary directory for onboarding PiP-guide recording."
    exit 0
}

derived_data="${recording_dir}/DerivedData"
log_file="${recording_dir}/recording.log"
echo "note: Recording onboarding PiP guides from OnboardingAnimationView.swift for Reader, Downloader, and Price Tracker."

if ! env \
    LUNA_GUIDE_VIDEO_RECORDING=1 \
    TEST_RUNNER_RECORD_GUIDE_VIDEOS=1 \
    TEST_RUNNER_GUIDE_VIDEO_OUTPUT_DIR="$recording_dir" \
    /usr/bin/xcodebuild test \
        -project "${SRCROOT}/Luna.xcodeproj" \
        -scheme Luna \
        -destination "platform=iOS Simulator,id=${SIMULATOR_ID}" \
        -configuration Debug \
        -derivedDataPath "$derived_data" \
        -only-testing:LunaTests/GuideVideoRecorderTests \
        DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO >"$log_file" 2>&1
then
    echo "warning: Could not record onboarding PiP guides. Existing clips remain bundled; record them manually when a compatible Simulator is available."
    /usr/bin/tail -n 30 "$log_file" || true
    exit 0
fi

for guide in $GUIDES; do
    if [ ! -s "${recording_dir}/${guide}" ]; then
        echo "warning: Recorder finished without ${guide}; existing clips remain bundled."
        exit 0
    fi
done

# The test writes to a private directory. Replace source resources only after all
# all twelve clips exist, so a failed recording can never leave a half-updated set.
for guide in $GUIDES; do
    /bin/mv -f "${recording_dir}/${guide}" "${RESOURCE_DIR}/${guide}"
done
/bin/printf '%s\n' "$source_hash" > "$STAMP_FILE"
echo "note: Recorded and embedded current onboarding PiP guides."

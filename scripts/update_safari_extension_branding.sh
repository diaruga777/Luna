#!/bin/sh
set -eu

manifest="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/manifest.json"
[ -f "$manifest" ] || exit 0

case "${PRODUCT_BUNDLE_IDENTIFIER}" in
  *.reader.safari)
    app_name="${DISPLAY_NAME_PREFIX:-Luna} Reader"
    app_icon="AppIconReader"
    ;;
  *.downloader.safari)
    app_name="${DISPLAY_NAME_PREFIX:-Luna} Downloader"
    app_icon="AppIconDownloader"
    ;;
  *.pricetracker.safari)
    app_name="${DISPLAY_NAME_PREFIX:-Luna} Price Tracker"
    app_icon="AppIconPriceTracker"
    ;;
  *)
    app_name="${DISPLAY_NAME_PREFIX:-Luna}"
    app_icon="AppIconLuna"
    ;;
esac

# Xcode's synchronized-group resource copy FLATTENS nested resource folders, so
# the source `_locales/en/messages.json` lands at the bundle root. Rewrite it
# wherever it ended up.
for messages in \
  "${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/_locales/en/messages.json" \
  "${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/messages.json"
do
  if [ -f "$messages" ]; then
    /usr/bin/plutil -replace extensionName.message -string "$app_name" "$messages"
  fi
done

info_plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
if [ -f "$info_plist" ]; then
  /usr/bin/plutil -replace CFBundleDisplayName -string "$app_name" "$info_plist"
  /usr/bin/plutil -replace CFBundleName -string "$app_name" "$info_plist"
fi

resources="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"

# The 1024px masters are not consistently named: most appiconsets use
# "<Name>-1024.png", AppIconLuna uses "<Name>1024.png". Accept either, and FAIL
# rather than skip — a silent `exit 0` here is what let the central app's
# extension ship the Reader's icon unnoticed.
iconset="${SRCROOT}/SharedIconAssets.xcassets/${app_icon}.appiconset"
source_icon=""
for candidate in "${iconset}/${app_icon}-1024.png" "${iconset}/${app_icon}1024.png"; do
  if [ -f "$candidate" ]; then source_icon="$candidate"; break; fi
done
if [ -z "$source_icon" ]; then
  echo "error: no 1024px master for ${app_icon} in ${iconset}" >&2
  exit 1
fi

for size in 48 64 96 128 256 512; do
  /usr/bin/sips -z "$size" "$size" "$source_icon" \
    --out "$resources/extension-icon-${size}.png" >/dev/null
done

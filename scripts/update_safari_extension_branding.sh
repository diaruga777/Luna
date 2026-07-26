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
    app_icon="AppIconReader"
    ;;
esac

messages="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/_locales/en/messages.json"
if [ -f "$messages" ]; then
  /usr/bin/plutil -replace extensionName.message -string "$app_name" "$messages"
fi

info_plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
if [ -f "$info_plist" ]; then
  /usr/bin/plutil -replace CFBundleDisplayName -string "$app_name" "$info_plist"
  /usr/bin/plutil -replace CFBundleName -string "$app_name" "$info_plist"
fi

resources="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
source_icon="${SRCROOT}/SharedIconAssets.xcassets/${app_icon}.appiconset/${app_icon}-1024.png"
[ -f "$source_icon" ] || exit 0

for size in 48 64 96 128 256 512; do
  /usr/bin/sips -z "$size" "$size" "$source_icon" --out "$resources/icon-${size}.png" >/dev/null
done

#!/bin/sh
set -eu

manifest="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/manifest.json"
[ -f "$manifest" ] || exit 0

case "${PRODUCT_BUNDLE_IDENTIFIER}" in
  *.reader.safari)
    app_name="${DISPLAY_NAME_PREFIX:-Luna} Reader"
    icon_name="Luna Reader"
    ;;
  *.downloader.safari)
    app_name="${DISPLAY_NAME_PREFIX:-Luna} Downloader"
    icon_name="Luna Downloader"
    ;;
  *.pricetracker.safari)
    app_name="${DISPLAY_NAME_PREFIX:-Luna} Price Tracker"
    icon_name="Luna Price Tracker"
    ;;
  *)
    app_name="${DISPLAY_NAME_PREFIX:-Luna}"
    icon_name="Luna Reader"
    ;;
esac

/usr/bin/plutil -replace name -string "$app_name" "$manifest"

info_plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
if [ -f "$info_plist" ]; then
  /usr/bin/plutil -replace CFBundleDisplayName -string "$app_name" "$info_plist"
  /usr/bin/plutil -replace CFBundleName -string "$app_name" "$info_plist"
fi

resources="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
icon_export="${TARGET_TEMP_DIR}/SafariWebExtensionIconExport"
/bin/rm -rf "$icon_export"
/bin/mkdir -p "$icon_export"

if /usr/bin/xcrun actool "${SRCROOT}/${icon_name}.icon" \
  --compile "$icon_export" \
  --output-format human-readable-text \
  --notices \
  --warnings \
  --output-partial-info-plist "${icon_export}/Info.plist" \
  --app-icon "$icon_name" \
  --compress-pngs \
  --enable-on-demand-resources NO \
  --development-region "${DEVELOPMENT_LANGUAGE:-en}" \
  --target-device iphone \
  --target-device ipad \
  --minimum-deployment-target "${IPHONEOS_DEPLOYMENT_TARGET}" \
  --platform "${PLATFORM_NAME}" >/dev/null; then
  compiled_icon="$(/usr/bin/find "$icon_export" -maxdepth 1 -type f -name "${icon_name}*.png" -print | /usr/bin/sort -r | /usr/bin/head -n 1 || true)"
else
  compiled_icon=""
fi

[ -n "$compiled_icon" ] || exit 0

for size in 48 64 96 128 256 512; do
  /usr/bin/sips -z "$size" "$size" "$compiled_icon" --out "$resources/icon-${size}.png" >/dev/null
done

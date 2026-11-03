#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
case "$MODE" in
  run|--build-only|--verify|verify|--debug|debug|--logs|logs|--telemetry|telemetry) ;;
  *) echo "usage: $0 [run|--build-only|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="${LUNA_MAC_APP_BUNDLE:-/Applications/Luna Vault.app}"
APP_NAME="LunaVaultMacCompanion"
# Pin the installed client's exact certificate, including worktree builds.
SIGNING_IDENTITY="${LUNA_MAC_SIGNING_IDENTITY:-$("$ROOT_DIR/script/install_vault_mac.py" "$BUNDLE" --identity)}"
if [[ -z "${DEVELOPER_DIR:-}" && ! -x "$(xcode-select -p)/usr/bin/xcodebuild" ]]; then
  XCODE_APP="$(mdfind 'kMDItemCFBundleIdentifier == "com.apple.dt.Xcode"' | head -1)"
  [[ -z "$XCODE_APP" ]] || export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
fi
DERIVED_DATA="${LUNA_MAC_DERIVED_DATA:-$ROOT_DIR/.build-vault-mac/DerivedData}"
ARGS=(-project "$ROOT_DIR/Luna.xcodeproj" -scheme LunaVaultMac -configuration Debug
  -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA"
  "CODE_SIGN_IDENTITY=$SIGNING_IDENTITY")
if [[ -n "${LUNA_MAC_BUNDLE_ID:-}" ]]; then ARGS+=("PRODUCT_BUNDLE_IDENTIFIER=$LUNA_MAC_BUNDLE_ID"); fi
xcodebuild "${ARGS[@]}" build
"$ROOT_DIR/script/install_vault_mac.py" "$DERIVED_DATA/Build/Products/Debug/Luna Vault.app" "$BUNDLE"
codesign -dv --verbose=2 "$BUNDLE"
case "$MODE" in
  --build-only) exit 0 ;;
  run) open "$BUNDLE" ;;
  --verify|verify) open "$BUNDLE"; sleep 2; pgrep -x "$APP_NAME" >/dev/null ;;
  --debug|debug) lldb -- "$BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs|logs|--telemetry|telemetry)
    open "$BUNDLE"
    /usr/bin/log stream --info --style compact --predicate 'process == "LunaVaultMacCompanion"'
    ;;
esac

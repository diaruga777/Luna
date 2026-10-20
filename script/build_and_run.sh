#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="LunaVaultMacCompanion"
BUNDLE="$ROOT_DIR/.build-vault-mac/Luna Mac.app"
# When supplied, keep macOS privacy grants tied to a certificate-backed app
# identity across rebuilds. Resolve only valid identities; expired certificates
# can share a name.
SIGNING_IDENTITY="${LUNA_MAC_SIGNING_IDENTITY:--}"
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  SIGNING_MATCHES="$(security find-identity -v -p codesigning | awk -F '"' -v requested="$SIGNING_IDENTITY" '
    { split($1, fields, " "); if (fields[2] == requested || $2 == requested) print fields[2] }
  ')"
  if [[ -z "$SIGNING_MATCHES" || "$SIGNING_MATCHES" == *$'\n'* ]]; then
    echo "No unique valid signing identity matches: $SIGNING_IDENTITY" >&2
    echo "Set LUNA_MAC_SIGNING_IDENTITY to an exact certificate name or SHA-1 from: security find-identity -v -p codesigning" >&2
    exit 1
  fi
  SIGNING_IDENTITY="$SIGNING_MATCHES"
fi
cd "$ROOT_DIR/LunaVaultTailscale"
swift build --product "$APP_NAME"
BUILD_DIR="$(swift build --show-bin-path)"
# Build the pinned Mac-only Apple adapter before touching the existing app.
# No pairing records are queried by compilation or notice collection.
APPLE_HELPER="$BUILD_DIR/luna-code-apple-adapter"
go -C "$ROOT_DIR/tools/code-apple-adapter" build -trimpath -o "$APPLE_HELPER" ./cmd/luna-code-apple-adapter
python3 "$ROOT_DIR/tools/code-apple-adapter/notices/collect.py" "$BUILD_DIR/apple-adapter-notices"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
# Stop only after the replacement binary has built successfully.
if [[ "$MODE" != "--build-only" ]]; then pkill -x "$APP_NAME" >/dev/null 2>&1 || true; fi
cp "$BUILD_DIR/$APP_NAME" "$BUNDLE/Contents/MacOS/$APP_NAME"
mkdir -p "$BUNDLE/Contents/Helpers" "$BUNDLE/Contents/Resources/AppleAdapterNotices"
cp "$APPLE_HELPER" "$BUNDLE/Contents/Helpers/luna-code-apple-adapter"
cp -R "$BUILD_DIR/apple-adapter-notices/." "$BUNDLE/Contents/Resources/AppleAdapterNotices/"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$BUNDLE/Contents/Helpers/luna-code-apple-adapter"
# The Code bridge checks application resources before the SwiftPM build path.
for resource in "$BUILD_DIR"/*.bundle; do
  [[ -d "$resource" ]] && cp -R "$resource" "$BUNDLE/Contents/Resources/"
done
# The installation enrollment service may touch only this configured app container.
# Derive the default from the same namespace as Xcode; never accept it from RPCs.
CODE_NAMESPACE=$(awk -F ' = ' '/^LUNA_NAMESPACE = / {print $2; exit}' "$ROOT_DIR/Config/Luna.xcconfig")
CODE_COMPANY=$(awk -F ' = ' '/^COMPANY_PREFIX = / {print $2; exit}' "$ROOT_DIR/Config/Luna.xcconfig")
CODE_INSTALL_BUNDLE_ID=${LUNA_CODE_BUNDLE_ID:-$CODE_COMPANY.$CODE_NAMESPACE.code}
[[ "$CODE_INSTALL_BUNDLE_ID" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "Invalid Luna Code bundle identifier" >&2; exit 1; }
cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LunaVaultMacCompanion</string>
<key>CFBundleIdentifier</key><string>${LUNA_MAC_BUNDLE_ID:-com.hsanabria.luna.vault.mac}</string>
<key>LunaCodeBundleIdentifier</key><string>${CODE_INSTALL_BUNDLE_ID}</string>
<key>CFBundleName</key><string>Luna Mac</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSLocalNetworkUsageDescription</key><string>Luna Mac connects to Luna Vault and Luna Code on your paired iPhone.</string>
</dict></plist>
PLIST
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$BUNDLE"
codesign --verify --deep --strict "$BUNDLE"
case "$MODE" in
  --build-only) exit 0 ;;
  run) open -n "$BUNDLE" ;;
  --verify|verify) open -n "$BUNDLE"; sleep 2; pgrep -x "$APP_NAME" >/dev/null ;;
  --debug|debug) lldb -- "$BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs|logs|--telemetry|telemetry)
    open -n "$BUNDLE"
    /usr/bin/log stream --info --style compact --predicate 'process == "LunaVaultMacCompanion"'
    ;;
  *) echo "usage: $0 [run|--build-only|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac

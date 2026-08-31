#!/bin/zsh
# Rebuilds LunaVaultTailscale/Vendor/LibTailscale.xcframework from source.
#
# The xcframework is COMMITTED, so this script runs only when updating the
# pinned libtailscale revision. Requires a Go toolchain and Xcode.
#
# Slices: ios-arm64 (device), ios-arm64-simulator, macos-arm64.
# After running, update the commit hash in
# LunaVaultTailscale/Sources/TailscaleKit/VENDORED.md and re-apply the marked
# Luna changes to any vendored Swift file upstream touched.
set -euo pipefail

LIBTAILSCALE_COMMIT="${LIBTAILSCALE_COMMIT:-80771313ac4127973677c993889fe215abcf1fbd}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$REPO_ROOT/LunaVaultTailscale/Vendor"
WORK_DIR="$(mktemp -d /tmp/libtailscale-build.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

command -v go >/dev/null || { echo "Go toolchain is required (brew install go)."; exit 1; }

echo "Cloning tailscale/libtailscale at $LIBTAILSCALE_COMMIT…"
git clone https://github.com/tailscale/libtailscale.git "$WORK_DIR/libtailscale"
cd "$WORK_DIR/libtailscale"
git checkout --quiet "$LIBTAILSCALE_COMMIT"

echo "Building macOS arm64 archive…"
MACOSX_DEPLOYMENT_TARGET=15.0 CGO_ENABLED=1 \
  CGO_CFLAGS="-mmacos-version-min=15.0" CGO_LDFLAGS="-mmacos-version-min=15.0" \
  go build -ldflags "-w" -buildmode=c-archive -o libtailscale_macos.a

echo "Building iOS device archive…"
CGO_ENABLED=1 GOOS=ios GOARCH=arm64 CC="$PWD/swift/script/clangwrap-ios.sh" \
  go build -ldflags -w -tags ios -buildmode=c-archive -o libtailscale_ios.a

echo "Building iOS simulator arm64 archive…"
CGO_ENABLED=1 GOOS=ios GOARCH=arm64 CC="$PWD/swift/script/clangwrap-ios-sim-arm.sh" \
  go build -ldflags -w -tags ios -buildmode=c-archive -o libtailscale_ios_sim_arm64.a

for slice in ios sim macos; do
  mkdir -p "include-$slice"
  cp tailscale.h "include-$slice/"
  printf 'module LibTailscale {\n    header "tailscale.h"\n    export *\n}\n' \
    > "include-$slice/module.modulemap"
done

rm -rf "$VENDOR_DIR/LibTailscale.xcframework"
xcodebuild -create-xcframework \
  -library libtailscale_ios.a -headers include-ios \
  -library libtailscale_ios_sim_arm64.a -headers include-sim \
  -library libtailscale_macos.a -headers include-macos \
  -output "$VENDOR_DIR/LibTailscale.xcframework"

du -sh "$VENDOR_DIR/LibTailscale.xcframework"
echo "Done. Commit the updated xcframework together with the VENDORED.md hash."

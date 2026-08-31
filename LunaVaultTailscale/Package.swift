// swift-tools-version: 6.2
import PackageDescription

// Embedded Tailscale (tsnet) transport for Luna Vault's Mac backend.
//
// This package is deliberately separate from LunaLibraries: it carries the
// committed LibTailscale.xcframework binary (~80 MB, built from source by
// scripts/build_libtailscale.sh), and only the Luna Vault app target and the
// Mac companion link it. LunaLibraries stays binary-free for the other four
// apps and their extensions.
let package = Package(
    name: "LunaVaultTailscale",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "LunaVaultTailscale", targets: ["LunaVaultTailscale"]),
        .executable(name: "LunaVaultMacCompanion", targets: ["LunaVaultMacCompanion"]),
    ],
    dependencies: [
        .package(path: "../LunaLibraries"),
    ],
    targets: [
        // The Go tsnet core, prebuilt as static archives. Go's darwin runtime
        // and Tailscale's TLS stack need Security and libresolv at link time.
        .binaryTarget(name: "LibTailscale", path: "Vendor/LibTailscale.xcframework"),
        .target(name: "TailscaleKit",
                dependencies: ["LibTailscale"],
                exclude: ["LICENSE", "VENDORED.md"],
                linkerSettings: [
                    .linkedFramework("Security"),
                    .linkedLibrary("resolv"),
                ]),
        .target(name: "LunaVaultTailscale", dependencies: [
            "TailscaleKit",
            .product(name: "LunaVaultBackend", package: "LunaLibraries"),
        ]),
        .executableTarget(name: "LunaVaultMacCompanion", dependencies: [
            "LunaVaultTailscale",
            .product(name: "LunaVaultMac", package: "LunaLibraries"),
            .product(name: "LunaVaultBackend", package: "LunaLibraries"),
            .product(name: "LunaVaultCrypto", package: "LunaLibraries"),
        ]),
    ],
    // Swift 5 language mode to match LunaLibraries and the app targets.
    swiftLanguageModes: [.v5]
)

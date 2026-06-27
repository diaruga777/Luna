// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ClipLibraries",
    // macOS support exists solely so the pure-library test suite can run in CI;
    // products are consumed by the iOS app and its extensions.
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "ClipModels", targets: ["ClipModels"]),
        .library(name: "ClipURLClassification", targets: ["ClipURLClassification"]),
        .library(name: "ClipHTMLClassification", targets: ["ClipHTMLClassification"]),
        .library(name: "ClipPaywallBypass", targets: ["ClipPaywallBypass"]),
        .library(name: "ClipPriceMetadata", targets: ["ClipPriceMetadata"]),
        .library(name: "ClipContentRendering", targets: ["ClipContentRendering"]),
    ],
    targets: [
        .target(name: "ClipModels"),
        .target(name: "ClipURLClassification", dependencies: ["ClipModels"]),
        .target(name: "ClipHTMLClassification"),
        .target(name: "ClipPaywallBypass"),
        .target(name: "ClipPriceMetadata"),
        .target(name: "ClipContentRendering"),
        .testTarget(name: "ClipModelsTests", dependencies: ["ClipModels"]),
        .testTarget(name: "ClipURLClassificationTests", dependencies: ["ClipURLClassification"]),
        .testTarget(name: "ClipHTMLClassificationTests", dependencies: ["ClipHTMLClassification"]),
        .testTarget(name: "ClipPaywallBypassTests", dependencies: ["ClipPaywallBypass"]),
        .testTarget(name: "ClipPriceMetadataTests", dependencies: ["ClipPriceMetadata"]),
    ]
)

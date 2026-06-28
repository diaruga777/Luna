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
        .library(name: "ClipFetch", targets: ["ClipFetch"]),
        .library(name: "ClipIngest", targets: ["ClipIngest"]),
        .library(name: "ClipStorage", targets: ["ClipStorage"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
    ],
    targets: [
        .target(name: "ClipModels"),
        .target(name: "ClipURLClassification", dependencies: ["ClipModels"]),
        .target(name: "ClipHTMLClassification", dependencies: [
            "ClipModels", "ClipURLClassification", "ClipPriceMetadata",
            .product(name: "SwiftSoup", package: "SwiftSoup"),
        ]),
        .target(name: "ClipPaywallBypass", dependencies: [
            "ClipModels", "ClipURLClassification", "ClipHTMLClassification", "ClipFetch",
            .product(name: "SwiftSoup", package: "SwiftSoup"),
        ]),
        .target(name: "ClipPriceMetadata"),
        .target(name: "ClipContentRendering"),
        .target(name: "ClipFetch", dependencies: ["ClipModels", "ClipURLClassification", "ClipHTMLClassification"]),
        .target(name: "ClipIngest", dependencies: [
            "ClipModels", "ClipURLClassification", "ClipHTMLClassification", "ClipFetch", "ClipPaywallBypass",
        ]),
        .target(name: "ClipStorage", dependencies: ["ClipModels", "ClipURLClassification"]),
        .testTarget(name: "ClipModelsTests", dependencies: ["ClipModels"]),
        .testTarget(name: "ClipURLClassificationTests", dependencies: ["ClipURLClassification"]),
        .testTarget(name: "ClipHTMLClassificationTests", dependencies: ["ClipHTMLClassification"]),
        .testTarget(name: "ClipPaywallBypassTests", dependencies: ["ClipPaywallBypass"]),
        .testTarget(name: "ClipPriceMetadataTests", dependencies: ["ClipPriceMetadata"]),
    ],
    // Swift 5 language mode to match the app target — this is a structural
    // extraction, not a Swift 6 strict-concurrency migration (a separate effort).
    // Keeps behavior identical to the pre-extraction app module.
    swiftLanguageModes: [.v5]
)

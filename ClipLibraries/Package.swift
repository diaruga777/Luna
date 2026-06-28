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
        .library(name: "ClipDocuments", targets: ["ClipDocuments"]),
        .library(name: "ClipEpub", targets: ["ClipEpub"]),
        .library(name: "ClipSend", targets: ["ClipSend"]),
        .library(name: "ClipMail", targets: ["ClipMail"]),
        .library(name: "ClipDesignSystem", targets: ["ClipDesignSystem"]),
        .library(name: "ClipPlatforms", targets: ["ClipPlatforms"]),
        .library(name: "ClipMediaDownload", targets: ["ClipMediaDownload"]),
        .library(name: "ClipSocial", targets: ["ClipSocial"]),
        .library(name: "ClipSemantic", targets: ["ClipSemantic"]),
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
        .target(name: "ClipDocuments", dependencies: ["ClipModels"]),
        .target(name: "ClipEpub", dependencies: ["ClipModels"]),
        .target(name: "ClipSend", dependencies: ["ClipModels", "ClipStorage", "ClipEpub"]),
        .target(name: "ClipMail", dependencies: ["ClipModels", "ClipHTMLClassification", "ClipStorage"]),
        .target(name: "ClipDesignSystem", dependencies: ["ClipModels"]),
        .target(name: "ClipPlatforms", dependencies: ["ClipModels", "ClipURLClassification", "ClipHTMLClassification", "ClipFetch", "ClipStorage", "ClipDesignSystem"]),
        .target(name: "ClipMediaDownload", dependencies: ["ClipModels", "ClipURLClassification"]),
        .target(name: "ClipSocial", dependencies: ["ClipModels", "ClipStorage"]),
        .target(name: "ClipSemantic", dependencies: ["ClipModels", "ClipStorage", "ClipSocial"]),
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

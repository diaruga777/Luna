// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ClipLibraries",
    // macOS support exists solely so the pure-library test suite can run in CI;
    // products are consumed by the iOS app and its extensions.
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "ClipAppConfig", targets: ["ClipAppConfig"]),
        .library(name: "ClipModels", targets: ["ClipModels"]),
        .library(name: "ClipURLClassification", targets: ["ClipURLClassification"]),
        .library(name: "ClipHTMLClassification", targets: ["ClipHTMLClassification"]),
        .library(name: "ClipPaywallBypass", targets: ["ClipPaywallBypass"]),
        .library(name: "ClipPriceMetadata", targets: ["ClipPriceMetadata"]),
        .library(name: "ClipContentRendering", targets: ["ClipContentRendering"]),
        .library(name: "ClipTransitions", targets: ["ClipTransitions"]),
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
        .library(name: "ClipReaderEngine", targets: ["ClipReaderEngine"]),
        .library(name: "ClipArchiveReader", targets: ["ClipArchiveReader"]),
        .library(name: "ClipReaderUI", targets: ["ClipReaderUI"]),
        .library(name: "ClipPriceUI", targets: ["ClipPriceUI"]),
        .library(name: "ClipShareSurface", targets: ["ClipShareSurface"]),
        .library(name: "ClipYouTubeAPI", targets: ["ClipYouTubeAPI"]),
        .library(name: "ClipReadingList", targets: ["ClipReadingList"]),
        .library(name: "ClipSocialUI", targets: ["ClipSocialUI"]),
        .library(name: "ClipIntents", targets: ["ClipIntents"]),
        .library(name: "ClipReadingListUI", targets: ["ClipReadingListUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
    ],
    targets: [
        // Single source of truth for the shared App Group / iCloud container ids,
        // read from build-injected Info.plist keys (see Config/Quartz.xcconfig).
        .target(name: "ClipAppConfig"),
        .target(name: "ClipModels"),
        .target(name: "ClipURLClassification", dependencies: ["ClipModels"]),
        .target(name: "ClipHTMLClassification", dependencies: [
            "ClipModels", "ClipURLClassification", "ClipPriceMetadata",
            .product(name: "SwiftSoup", package: "SwiftSoup"),
        ]),
        .target(name: "ClipPaywallBypass", dependencies: [
            "ClipAppConfig", "ClipModels", "ClipURLClassification", "ClipHTMLClassification", "ClipFetch",
            .product(name: "SwiftSoup", package: "SwiftSoup"),
        ]),
        .target(name: "ClipPriceMetadata"),
        .target(name: "ClipContentRendering"),
        // Shared UIKit transition facade: wraps the ClipContentRendering Metal engine
        // (Dot Matrix pixel-wipe) behind UIViewControllerAnimatedTransitioning, nav/modal
        // delegates, an in-place crossfade, and a table batch helper. Linked by the app
        // and the action extension so both get the same global transitions.
        .target(name: "ClipTransitions", dependencies: ["ClipContentRendering", "ClipDesignSystem"]),
        .target(name: "ClipFetch", dependencies: ["ClipModels", "ClipURLClassification", "ClipHTMLClassification"]),
        .target(name: "ClipIngest", dependencies: [
            "ClipModels", "ClipURLClassification", "ClipHTMLClassification", "ClipFetch", "ClipPaywallBypass",
        ]),
        .target(name: "ClipStorage", dependencies: ["ClipAppConfig", "ClipModels", "ClipURLClassification"]),
        .target(name: "ClipDocuments", dependencies: ["ClipModels"]),
        .target(name: "ClipEpub", dependencies: ["ClipModels"]),
        .target(name: "ClipSend", dependencies: ["ClipModels", "ClipStorage", "ClipEpub"]),
        .target(name: "ClipMail", dependencies: ["ClipModels", "ClipHTMLClassification", "ClipStorage"]),
        .target(name: "ClipDesignSystem", dependencies: ["ClipAppConfig", "ClipModels"]),
        .target(name: "ClipPlatforms", dependencies: ["ClipModels", "ClipURLClassification", "ClipHTMLClassification", "ClipFetch", "ClipStorage", "ClipDesignSystem"]),
        .target(name: "ClipMediaDownload", dependencies: ["ClipAppConfig", "ClipModels", "ClipURLClassification"]),
        .target(name: "ClipSocial", dependencies: ["ClipAppConfig", "ClipModels", "ClipStorage"]),
        .target(name: "ClipSemantic", dependencies: ["ClipModels", "ClipStorage", "ClipSocial"]),
        .target(name: "ClipReaderEngine", dependencies: ["ClipModels"]),
        .target(name: "ClipArchiveReader", dependencies: ["ClipModels", "ClipURLClassification", "ClipHTMLClassification", "ClipFetch", "ClipPaywallBypass", "ClipStorage", "ClipDesignSystem", "ClipTransitions"]),
        .target(name: "ClipReaderUI", dependencies: ["ClipAppConfig", "ClipModels", "ClipReaderEngine", "ClipDesignSystem", "ClipStorage", "ClipHTMLClassification", "ClipFetch", "ClipPaywallBypass", "ClipArchiveReader", "ClipIngest", "ClipURLClassification", "ClipPlatforms", "ClipTransitions"]),
        .target(name: "ClipPriceUI", dependencies: ["ClipModels", "ClipDesignSystem", "ClipHTMLClassification", "ClipStorage", "ClipFetch", "ClipURLClassification", "ClipIngest", "ClipReaderUI", "ClipTransitions"]),
        .target(name: "ClipShareSurface", dependencies: ["ClipAppConfig", "ClipModels", "ClipStorage", "ClipIngest", "ClipURLClassification", "ClipDesignSystem", "ClipReaderUI", "ClipArchiveReader", "ClipPriceUI", "ClipMediaDownload", "ClipPlatforms", "ClipTransitions"]),
        .target(name: "ClipYouTubeAPI", dependencies: ["ClipModels", "ClipStorage", "ClipURLClassification", "ClipDesignSystem", "ClipTransitions"]),
        .target(name: "ClipSocialUI", dependencies: ["ClipModels", "ClipStorage", "ClipDesignSystem", "ClipReaderUI", "ClipReadingList", "ClipSemantic", "ClipSocial"]),
        .target(name: "ClipIntents", dependencies: ["ClipModels", "ClipStorage", "ClipURLClassification", "ClipPlatforms", "ClipReadingList", "ClipSocial", "ClipYouTubeAPI"]),
        .target(name: "ClipReadingListUI", dependencies: ["ClipModels", "ClipStorage", "ClipDesignSystem", "ClipPlatforms", "ClipMediaDownload", "ClipSemantic", "ClipReaderUI", "ClipSend"]),
        .target(name: "ClipReadingList", dependencies: ["ClipModels", "ClipStorage", "ClipIngest", "ClipURLClassification", "ClipHTMLClassification", "ClipFetch", "ClipPaywallBypass", "ClipDesignSystem", "ClipDocuments", "ClipEpub", "ClipSend", "ClipMail", "ClipMediaDownload", "ClipPlatforms", "ClipPriceUI", "ClipReaderUI", "ClipArchiveReader", "ClipSemantic", "ClipSocial", "ClipYouTubeAPI"]),
        .testTarget(name: "ClipAppConfigTests", dependencies: ["ClipAppConfig"]),
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

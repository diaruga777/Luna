// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LunaLibraries",
    // macOS support exists solely so the pure-library test suite can run in CI;
    // products are consumed by the iOS app and its extensions.
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "LunaAppConfig", targets: ["LunaAppConfig"]),
        .library(name: "LunaModels", targets: ["LunaModels"]),
        .library(name: "LunaURLClassification", targets: ["LunaURLClassification"]),
        .library(name: "LunaHTMLClassification", targets: ["LunaHTMLClassification"]),
        .library(name: "LunaPaywallBypass", targets: ["LunaPaywallBypass"]),
        .library(name: "LunaPriceMetadata", targets: ["LunaPriceMetadata"]),
        .library(name: "LunaContentRendering", targets: ["LunaContentRendering"]),
        .library(name: "LunaTransitions", targets: ["LunaTransitions"]),
        .library(name: "LunaFetch", targets: ["LunaFetch"]),
        .library(name: "LunaIngest", targets: ["LunaIngest"]),
        .library(name: "LunaStorage", targets: ["LunaStorage"]),
        .library(name: "LunaDocuments", targets: ["LunaDocuments"]),
        .library(name: "LunaEpub", targets: ["LunaEpub"]),
        .library(name: "LunaSend", targets: ["LunaSend"]),
        .library(name: "LunaMail", targets: ["LunaMail"]),
        .library(name: "LunaMailAccount", targets: ["LunaMailAccount"]),
        .library(name: "LunaMailTransport", targets: ["LunaMailTransport"]),
        .library(name: "LunaDesignSystem", targets: ["LunaDesignSystem"]),
        .library(name: "LunaPlatforms", targets: ["LunaPlatforms"]),
        .library(name: "LunaMediaDownload", targets: ["LunaMediaDownload"]),
        .library(name: "LunaSocial", targets: ["LunaSocial"]),
        .library(name: "LunaSemantic", targets: ["LunaSemantic"]),
        .library(name: "LunaReaderEngine", targets: ["LunaReaderEngine"]),
        .library(name: "LunaArchiveReader", targets: ["LunaArchiveReader"]),
        .library(name: "LunaReaderUI", targets: ["LunaReaderUI"]),
        .library(name: "LunaPriceUI", targets: ["LunaPriceUI"]),
        .library(name: "LunaShareSurface", targets: ["LunaShareSurface"]),
        .library(name: "LunaYouTubeAPI", targets: ["LunaYouTubeAPI"]),
        .library(name: "LunaReadingList", targets: ["LunaReadingList"]),
        .library(name: "LunaSocialUI", targets: ["LunaSocialUI"]),
        .library(name: "LunaIntents", targets: ["LunaIntents"]),
        .library(name: "LunaReadingListUI", targets: ["LunaReadingListUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
    ],
    targets: [
        // Single source of truth for the shared App Group / iCloud container ids,
        // read from build-injected Info.plist keys (see Config/Luna.xcconfig).
        .target(name: "LunaAppConfig"),
        .target(name: "LunaModels"),
        .target(name: "LunaURLClassification", dependencies: ["LunaModels"]),
        .target(name: "LunaHTMLClassification", dependencies: [
            "LunaModels", "LunaURLClassification", "LunaPriceMetadata",
            .product(name: "SwiftSoup", package: "SwiftSoup"),
        ]),
        .target(name: "LunaPaywallBypass", dependencies: [
            "LunaAppConfig", "LunaModels", "LunaURLClassification", "LunaHTMLClassification", "LunaFetch",
            .product(name: "SwiftSoup", package: "SwiftSoup"),
        ], resources: [.process("Resources/site_unlock_rules.json")]),
        .target(name: "LunaPriceMetadata"),
        .target(name: "LunaContentRendering"),
        // Shared UIKit transition facade: wraps the LunaContentRendering Metal engine
        // (Dot Matrix pixel-wipe) behind UIViewControllerAnimatedTransitioning, nav/modal
        // delegates, an in-place crossfade, and a table batch helper. Linked by the app
        // and the action extension so both get the same global transitions.
        .target(name: "LunaTransitions", dependencies: ["LunaContentRendering", "LunaDesignSystem"]),
        .target(name: "LunaFetch", dependencies: ["LunaModels", "LunaURLClassification", "LunaHTMLClassification"]),
        .target(name: "LunaIngest", dependencies: [
            "LunaModels", "LunaURLClassification", "LunaHTMLClassification", "LunaFetch", "LunaPaywallBypass",
        ]),
        .target(name: "LunaStorage", dependencies: ["LunaAppConfig", "LunaModels", "LunaURLClassification"]),
        .target(name: "LunaDocuments", dependencies: ["LunaModels"]),
        .target(name: "LunaEpub", dependencies: ["LunaModels"]),
        .target(name: "LunaSend", dependencies: ["LunaModels", "LunaStorage", "LunaEpub"]),
        .target(name: "LunaMail", dependencies: ["LunaModels", "LunaHTMLClassification", "LunaStorage"]),
        .target(name: "LunaMailAccount", dependencies: ["LunaAppConfig", "LunaModels"]),
        // IMAP/SMTP engine for the multi-provider email account, built on
        // URLSessionStreamTask (implicit TLS + STARTTLS for iCloud) — no external
        // deps. Reuses LunaMail's MIME parsers. Linked by the app, not extensions.
        .target(name: "LunaMailTransport", dependencies: ["LunaMailAccount", "LunaMail", "LunaSend"]),
        .target(name: "LunaDesignSystem", dependencies: ["LunaAppConfig", "LunaModels"]),
        .target(name: "LunaPlatforms", dependencies: ["LunaModels", "LunaURLClassification", "LunaHTMLClassification", "LunaFetch", "LunaStorage", "LunaDesignSystem"]),
        .target(name: "LunaMediaDownload", dependencies: ["LunaAppConfig", "LunaModels", "LunaURLClassification"]),
        .target(name: "LunaSocial", dependencies: ["LunaAppConfig", "LunaModels", "LunaStorage"]),
        .target(name: "LunaSemantic", dependencies: ["LunaModels", "LunaStorage", "LunaSocial"]),
        .target(name: "LunaReaderEngine", dependencies: ["LunaModels"]),
        .target(name: "LunaArchiveReader", dependencies: ["LunaModels", "LunaURLClassification", "LunaHTMLClassification", "LunaFetch", "LunaPaywallBypass", "LunaStorage", "LunaDesignSystem", "LunaTransitions"]),
        .target(name: "LunaReaderUI", dependencies: ["LunaAppConfig", "LunaModels", "LunaReaderEngine", "LunaDesignSystem", "LunaStorage", "LunaHTMLClassification", "LunaFetch", "LunaPaywallBypass", "LunaArchiveReader", "LunaIngest", "LunaURLClassification", "LunaPlatforms", "LunaTransitions"]),
        .target(name: "LunaPriceUI", dependencies: ["LunaModels", "LunaDesignSystem", "LunaHTMLClassification", "LunaStorage", "LunaFetch", "LunaURLClassification", "LunaIngest", "LunaReaderUI", "LunaTransitions"]),
        .target(name: "LunaShareSurface", dependencies: ["LunaAppConfig", "LunaModels", "LunaStorage", "LunaIngest", "LunaURLClassification", "LunaDesignSystem", "LunaReaderUI", "LunaArchiveReader", "LunaPriceUI", "LunaMediaDownload", "LunaPlatforms", "LunaTransitions"]),
        .target(name: "LunaYouTubeAPI", dependencies: ["LunaModels", "LunaStorage", "LunaURLClassification", "LunaDesignSystem", "LunaTransitions"]),
        .target(name: "LunaSocialUI", dependencies: ["LunaModels", "LunaStorage", "LunaDesignSystem", "LunaReaderUI", "LunaReadingList", "LunaSemantic", "LunaSocial"]),
        .target(name: "LunaIntents", dependencies: ["LunaModels", "LunaStorage", "LunaURLClassification", "LunaPlatforms", "LunaReadingList", "LunaSocial", "LunaYouTubeAPI"]),
        .target(name: "LunaReadingListUI", dependencies: ["LunaModels", "LunaStorage", "LunaDesignSystem", "LunaPlatforms", "LunaMediaDownload", "LunaSemantic", "LunaReaderUI", "LunaSend"]),
        .target(name: "LunaReadingList", dependencies: ["LunaModels", "LunaStorage", "LunaIngest", "LunaURLClassification", "LunaHTMLClassification", "LunaFetch", "LunaPaywallBypass", "LunaDesignSystem", "LunaDocuments", "LunaEpub", "LunaSend", "LunaMail", "LunaMailAccount", "LunaMailTransport", "LunaMediaDownload", "LunaPlatforms", "LunaPriceUI", "LunaReaderUI", "LunaArchiveReader", "LunaSemantic", "LunaSocial", "LunaYouTubeAPI"]),
        .testTarget(name: "LunaAppConfigTests", dependencies: ["LunaAppConfig"]),
        .testTarget(name: "LunaModelsTests", dependencies: ["LunaModels"]),
        .testTarget(name: "LunaURLClassificationTests", dependencies: ["LunaURLClassification"]),
        .testTarget(name: "LunaHTMLClassificationTests", dependencies: ["LunaHTMLClassification"]),
        .testTarget(name: "LunaPaywallBypassTests", dependencies: ["LunaPaywallBypass"]),
        .testTarget(name: "LunaPriceMetadataTests", dependencies: ["LunaPriceMetadata"]),
        .testTarget(name: "LunaMailAccountTests", dependencies: ["LunaMailAccount"]),
    ],
    // Swift 5 language mode to match the app target — this is a structural
    // extraction, not a Swift 6 strict-concurrency migration (a separate effort).
    // Keeps behavior identical to the pre-extraction app module.
    swiftLanguageModes: [.v5]
)

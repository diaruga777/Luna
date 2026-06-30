// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LuneLibraries",
    // macOS support exists solely so the pure-library test suite can run in CI;
    // products are consumed by the iOS app and its extensions.
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "LuneAppConfig", targets: ["LuneAppConfig"]),
        .library(name: "LuneModels", targets: ["LuneModels"]),
        .library(name: "LuneURLClassification", targets: ["LuneURLClassification"]),
        .library(name: "LuneHTMLClassification", targets: ["LuneHTMLClassification"]),
        .library(name: "LunePaywallBypass", targets: ["LunePaywallBypass"]),
        .library(name: "LunePriceMetadata", targets: ["LunePriceMetadata"]),
        .library(name: "LuneContentRendering", targets: ["LuneContentRendering"]),
        .library(name: "LuneTransitions", targets: ["LuneTransitions"]),
        .library(name: "LuneFetch", targets: ["LuneFetch"]),
        .library(name: "LuneIngest", targets: ["LuneIngest"]),
        .library(name: "LuneStorage", targets: ["LuneStorage"]),
        .library(name: "LuneDocuments", targets: ["LuneDocuments"]),
        .library(name: "LuneEpub", targets: ["LuneEpub"]),
        .library(name: "LuneSend", targets: ["LuneSend"]),
        .library(name: "LuneMail", targets: ["LuneMail"]),
        .library(name: "LuneDesignSystem", targets: ["LuneDesignSystem"]),
        .library(name: "LunePlatforms", targets: ["LunePlatforms"]),
        .library(name: "LuneMediaDownload", targets: ["LuneMediaDownload"]),
        .library(name: "LuneSocial", targets: ["LuneSocial"]),
        .library(name: "LuneSemantic", targets: ["LuneSemantic"]),
        .library(name: "LuneReaderEngine", targets: ["LuneReaderEngine"]),
        .library(name: "LuneArchiveReader", targets: ["LuneArchiveReader"]),
        .library(name: "LuneReaderUI", targets: ["LuneReaderUI"]),
        .library(name: "LunePriceUI", targets: ["LunePriceUI"]),
        .library(name: "LuneShareSurface", targets: ["LuneShareSurface"]),
        .library(name: "LuneYouTubeAPI", targets: ["LuneYouTubeAPI"]),
        .library(name: "LuneReadingList", targets: ["LuneReadingList"]),
        .library(name: "LuneSocialUI", targets: ["LuneSocialUI"]),
        .library(name: "LuneIntents", targets: ["LuneIntents"]),
        .library(name: "LuneReadingListUI", targets: ["LuneReadingListUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
    ],
    targets: [
        // Single source of truth for the shared App Group / iCloud container ids,
        // read from build-injected Info.plist keys (see Config/Lune.xcconfig).
        .target(name: "LuneAppConfig"),
        .target(name: "LuneModels"),
        .target(name: "LuneURLClassification", dependencies: ["LuneModels"]),
        .target(name: "LuneHTMLClassification", dependencies: [
            "LuneModels", "LuneURLClassification", "LunePriceMetadata",
            .product(name: "SwiftSoup", package: "SwiftSoup"),
        ]),
        .target(name: "LunePaywallBypass", dependencies: [
            "LuneAppConfig", "LuneModels", "LuneURLClassification", "LuneHTMLClassification", "LuneFetch",
            .product(name: "SwiftSoup", package: "SwiftSoup"),
        ]),
        .target(name: "LunePriceMetadata"),
        .target(name: "LuneContentRendering"),
        // Shared UIKit transition facade: wraps the LuneContentRendering Metal engine
        // (Dot Matrix pixel-wipe) behind UIViewControllerAnimatedTransitioning, nav/modal
        // delegates, an in-place crossfade, and a table batch helper. Linked by the app
        // and the action extension so both get the same global transitions.
        .target(name: "LuneTransitions", dependencies: ["LuneContentRendering", "LuneDesignSystem"]),
        .target(name: "LuneFetch", dependencies: ["LuneModels", "LuneURLClassification", "LuneHTMLClassification"]),
        .target(name: "LuneIngest", dependencies: [
            "LuneModels", "LuneURLClassification", "LuneHTMLClassification", "LuneFetch", "LunePaywallBypass",
        ]),
        .target(name: "LuneStorage", dependencies: ["LuneAppConfig", "LuneModels", "LuneURLClassification"]),
        .target(name: "LuneDocuments", dependencies: ["LuneModels"]),
        .target(name: "LuneEpub", dependencies: ["LuneModels"]),
        .target(name: "LuneSend", dependencies: ["LuneModels", "LuneStorage", "LuneEpub"]),
        .target(name: "LuneMail", dependencies: ["LuneModels", "LuneHTMLClassification", "LuneStorage"]),
        .target(name: "LuneDesignSystem", dependencies: ["LuneAppConfig", "LuneModels"]),
        .target(name: "LunePlatforms", dependencies: ["LuneModels", "LuneURLClassification", "LuneHTMLClassification", "LuneFetch", "LuneStorage", "LuneDesignSystem"]),
        .target(name: "LuneMediaDownload", dependencies: ["LuneAppConfig", "LuneModels", "LuneURLClassification"]),
        .target(name: "LuneSocial", dependencies: ["LuneAppConfig", "LuneModels", "LuneStorage"]),
        .target(name: "LuneSemantic", dependencies: ["LuneModels", "LuneStorage", "LuneSocial"]),
        .target(name: "LuneReaderEngine", dependencies: ["LuneModels"]),
        .target(name: "LuneArchiveReader", dependencies: ["LuneModels", "LuneURLClassification", "LuneHTMLClassification", "LuneFetch", "LunePaywallBypass", "LuneStorage", "LuneDesignSystem", "LuneTransitions"]),
        .target(name: "LuneReaderUI", dependencies: ["LuneAppConfig", "LuneModels", "LuneReaderEngine", "LuneDesignSystem", "LuneStorage", "LuneHTMLClassification", "LuneFetch", "LunePaywallBypass", "LuneArchiveReader", "LuneIngest", "LuneURLClassification", "LunePlatforms", "LuneTransitions"]),
        .target(name: "LunePriceUI", dependencies: ["LuneModels", "LuneDesignSystem", "LuneHTMLClassification", "LuneStorage", "LuneFetch", "LuneURLClassification", "LuneIngest", "LuneReaderUI", "LuneTransitions"]),
        .target(name: "LuneShareSurface", dependencies: ["LuneAppConfig", "LuneModels", "LuneStorage", "LuneIngest", "LuneURLClassification", "LuneDesignSystem", "LuneReaderUI", "LuneArchiveReader", "LunePriceUI", "LuneMediaDownload", "LunePlatforms", "LuneTransitions"]),
        .target(name: "LuneYouTubeAPI", dependencies: ["LuneModels", "LuneStorage", "LuneURLClassification", "LuneDesignSystem", "LuneTransitions"]),
        .target(name: "LuneSocialUI", dependencies: ["LuneModels", "LuneStorage", "LuneDesignSystem", "LuneReaderUI", "LuneReadingList", "LuneSemantic", "LuneSocial"]),
        .target(name: "LuneIntents", dependencies: ["LuneModels", "LuneStorage", "LuneURLClassification", "LunePlatforms", "LuneReadingList", "LuneSocial", "LuneYouTubeAPI"]),
        .target(name: "LuneReadingListUI", dependencies: ["LuneModels", "LuneStorage", "LuneDesignSystem", "LunePlatforms", "LuneMediaDownload", "LuneSemantic", "LuneReaderUI", "LuneSend"]),
        .target(name: "LuneReadingList", dependencies: ["LuneModels", "LuneStorage", "LuneIngest", "LuneURLClassification", "LuneHTMLClassification", "LuneFetch", "LunePaywallBypass", "LuneDesignSystem", "LuneDocuments", "LuneEpub", "LuneSend", "LuneMail", "LuneMediaDownload", "LunePlatforms", "LunePriceUI", "LuneReaderUI", "LuneArchiveReader", "LuneSemantic", "LuneSocial", "LuneYouTubeAPI"]),
        .testTarget(name: "LuneAppConfigTests", dependencies: ["LuneAppConfig"]),
        .testTarget(name: "LuneModelsTests", dependencies: ["LuneModels"]),
        .testTarget(name: "LuneURLClassificationTests", dependencies: ["LuneURLClassification"]),
        .testTarget(name: "LuneHTMLClassificationTests", dependencies: ["LuneHTMLClassification"]),
        .testTarget(name: "LunePaywallBypassTests", dependencies: ["LunePaywallBypass"]),
        .testTarget(name: "LunePriceMetadataTests", dependencies: ["LunePriceMetadata"]),
    ],
    // Swift 5 language mode to match the app target — this is a structural
    // extraction, not a Swift 6 strict-concurrency migration (a separate effort).
    // Keeps behavior identical to the pre-extraction app module.
    swiftLanguageModes: [.v5]
)

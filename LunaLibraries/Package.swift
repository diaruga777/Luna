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
        .library(name: "LunaTransitions", targets: ["LunaTransitions"]),
        .library(name: "LunaFetch", targets: ["LunaFetch"]),
        .library(name: "LunaIngest", targets: ["LunaIngest"]),
        .library(name: "LunaArticleIngest", targets: ["LunaArticleIngest"]),
        .library(name: "LunaPriceIngest", targets: ["LunaPriceIngest"]),
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
        .library(name: "LunaReaderEngine", targets: ["LunaReaderEngine"]),
        .library(name: "LunaAudioPlayback", targets: ["LunaAudioPlayback"]),
        .library(name: "LunaArchiveReader", targets: ["LunaArchiveReader"]),
        .library(name: "LunaReaderUI", targets: ["LunaReaderUI"]),
        .library(name: "LunaPriceUI", targets: ["LunaPriceUI"]),
        .library(name: "LunaShareSurface", targets: ["LunaShareSurface"]),
        .library(name: "LunaURLRescue", targets: ["LunaURLRescue"]),
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
        .target(name: "LunaModels", resources: [.process("Resources")]),
        .target(name: "LunaURLClassification", dependencies: ["LunaModels"]),
        .target(name: "LunaHTMLClassification", dependencies: [
            "LunaModels", "LunaURLClassification", "LunaPriceMetadata",
            .product(name: "SwiftSoup", package: "SwiftSoup"),
        ]),
        .target(name: "LunaPaywallBypass", dependencies: [
            "LunaModels", "LunaURLClassification", "LunaHTMLClassification", "LunaFetch",
            .product(name: "SwiftSoup", package: "SwiftSoup"),], resources: [.process("Resources/site_unlock_rules.json")]),
        .target(name: "LunaPriceMetadata"),
        .target(name: "LunaTransitions", dependencies: ["LunaDesignSystem"]),
        .target(name: "LunaFetch", dependencies: ["LunaModels", "LunaURLClassification", "LunaHTMLClassification", "LunaPriceMetadata", .product(name: "SwiftSoup", package: "SwiftSoup")]),
        // The ONE shared classification pipeline every app bundles: unwrap +
        // classify (URL table + HTML heuristics) + the per-kind PROCESSOR
        // REGISTRY. The actual per-kind processing lives in the link-optional
        // LunaArticleIngest / LunaPriceIngest modules below, so a
        // single-content app never ships another kind's handling code.
        .target(name: "LunaIngest", dependencies: [
            "LunaModels", "LunaURLClassification", "LunaHTMLClassification", "LunaFetch", "LunaAppConfig", "LunaPriceMetadata", .product(name: "SwiftSoup", package: "SwiftSoup"),]),
        // Article-kind pipeline processing (resolver + silent bypass plan) —
        // linked ONLY by article-handling targets (Reader + central Luna).
        .target(name: "LunaArticleIngest", dependencies: [
            "LunaIngest", "LunaPaywallBypass", "LunaFetch", "LunaHTMLClassification", "LunaModels"]),
        // Product-kind pipeline processing (mandatory-price metadata
        // extraction) — linked ONLY by product-handling targets
        // (Price Tracker + central Luna).
        .target(name: "LunaPriceIngest", dependencies: [
            "LunaIngest", "LunaHTMLClassification", "LunaPriceMetadata", "LunaURLClassification", "LunaModels", .product(name: "SwiftSoup", package: "SwiftSoup")]),
        .target(name: "LunaStorage", dependencies: ["LunaAppConfig", "LunaModels", "LunaURLClassification"]),
        .target(name: "LunaDocuments", dependencies: ["LunaModels"]),
        .target(name: "LunaEpub", dependencies: ["LunaModels"]),
        .target(name: "LunaSend", dependencies: ["LunaModels", "LunaStorage", "LunaEpub", "LunaMailAccount", "LunaAppConfig", "LunaURLClassification"]),
        .target(name: "LunaMail", dependencies: ["LunaModels", "LunaHTMLClassification", "LunaStorage", "LunaPriceMetadata", "LunaURLClassification", .product(name: "SwiftSoup", package: "SwiftSoup")]),
        .target(name: "LunaMailAccount", dependencies: ["LunaAppConfig", "LunaModels", "LunaStorage"]),
        // IMAP/SMTP engine for the multi-provider email account, built on
        // URLSessionStreamTask (implicit TLS + STARTTLS for iCloud) — no external
        // deps. Reuses LunaMail's MIME parsers. Linked by the app, not extensions.
        .target(name: "LunaMailTransport", dependencies: ["LunaMailAccount", "LunaMail", "LunaSend", "LunaAppConfig", "LunaHTMLClassification", "LunaModels", "LunaPriceMetadata", "LunaURLClassification", .product(name: "SwiftSoup", package: "SwiftSoup")]),
        // Resources: every Luna app's icon artwork (`LunaAppIconImage`). A target
        // only gets its OWN appiconset at runtime, and the unsupported-save card
        // has to show whichever SIBLING app owns a dropped link — so the four
        // icons ship here, on every app's and extension's link path.
        .target(
            name: "LunaDesignSystem",
            dependencies: ["LunaAppConfig", "LunaModels"],
            resources: [.process("Resources")]),
        // LunaMediaDownload: the media ingest handler (`PlatformItemIngestor`)
        // hands recognized items to the auto-download pipeline.
        .target(name: "LunaPlatforms", dependencies: ["LunaModels", "LunaURLClassification", "LunaHTMLClassification", "LunaFetch", "LunaStorage", "LunaDesignSystem", "LunaAppConfig", "LunaPriceMetadata", "LunaMediaDownload", .product(name: "SwiftSoup", package: "SwiftSoup")]),
        // LunaDesignSystem: the extension's saved-non-textual screen
        // (`SavedNonTextualViewController`) + `ExtensionMediaPresenter` live
        // here with the download machinery they present.
        .target(
            name: "LunaMediaDownload",
            dependencies: ["LunaAppConfig", "LunaModels", "LunaURLClassification", "LunaStorage", "LunaDesignSystem", "LunaShareSurface"],
            resources: [.process("Resources")]),
        .target(name: "LunaSocial", dependencies: ["LunaAppConfig", "LunaModels", "LunaStorage", "LunaURLClassification"]),
        .target(name: "LunaReaderEngine", dependencies: ["LunaModels"]),
        // Offline speech rendering (AVSpeechSynthesizer.write -> PCM) + a long-lived
        // AVAudioEngine playback graph, plus (Phase 2) the app-wide playback center,
        // Now Playing/remote-command integration, session policy, and App-Group
        // settings/position persistence — see claudedocs/audio-playback-plan.md.
        // LunaAppConfig (App-Group id) and LunaStorage (ReadingListStore access,
        // behind the ReadingListPlaybackStore seam) are Phase 2 additions; UI wiring
        // (mini-player, settings screen) is still later phases.
        .target(name: "LunaAudioPlayback", dependencies: ["LunaModels", "LunaAppConfig", "LunaStorage", "LunaDesignSystem"], resources: [
            .copy("Resources/ChimeTransition.caf"),
            .copy("Resources/ChimeFinal.caf"),
        ]),
        .target(name: "LunaArchiveReader", dependencies: ["LunaModels", "LunaURLClassification", "LunaHTMLClassification", "LunaFetch", "LunaPaywallBypass", "LunaStorage", "LunaDesignSystem", "LunaAppConfig", "LunaPriceMetadata", .product(name: "SwiftSoup", package: "SwiftSoup")], resources: [.process("Resources/site_cleanup_scripts.json")]),
        // LunaAudioPlayback: the Phase-3 reroute seam (`ReaderAudioLauncher`) — the shared
        // readers hand read-aloud to the app-wide `AudioPlaybackCenter` when the app shell
        // installs it, and keep the legacy self-contained SpeechController path when it's
        // absent (the share/action extensions never install it).
        .target(name: "LunaReaderUI", dependencies: ["LunaAppConfig", "LunaModels", "LunaReaderEngine", "LunaDesignSystem", "LunaStorage", "LunaHTMLClassification", "LunaFetch", "LunaPaywallBypass", "LunaArchiveReader", "LunaIngest", "LunaURLClassification", "LunaPriceMetadata", "LunaAudioPlayback", "LunaDocuments", "LunaArticleIngest", "LunaShareSurface", .product(name: "SwiftSoup", package: "SwiftSoup")]),
        // LunaSocial: `PriceRefreshCoordinator` posts price-drop local
        // notifications through LunaSocial's `NotificationManager`. No reader
        // modules: product-kind UI stands alone so the Price Tracker
        // extensions don't drag the whole reader stack in.
        .target(name: "LunaPriceUI", dependencies: ["LunaModels", "LunaDesignSystem", "LunaHTMLClassification", "LunaStorage", "LunaFetch", "LunaURLClassification", "LunaIngest", "LunaPriceIngest", "LunaAppConfig", "LunaPriceMetadata", "LunaSocial", "LunaShareSurface", .product(name: "SwiftSoup", package: "SwiftSoup")]),
        // KIND-NEUTRAL extension surface: the share/action host chrome, the
        // `ShareSurfaceDriver` ingest+present flow, and the `ShareKindPresenters`
        // registry. The kind-specific presentation (readers, saved-media screen,
        // price editor) lives in LunaReaderUI / LunaMediaDownload / LunaPriceUI
        // behind the registry, registered per target by the `ShareEntry+*` /
        // `ActionEntry+*` composition roots — so a single-content app's
        // extensions never link another kind's UI.
        .target(name: "LunaShareSurface", dependencies: ["LunaAppConfig", "LunaModels", "LunaStorage", "LunaIngest", "LunaURLClassification", "LunaHTMLClassification", "LunaDesignSystem"]),
        // The LLM URL-rescue engine (see claudedocs/url-rescue.md): when primary
        // ingestion fails, an Apple FoundationModels pass (on-device iOS 26 baseline,
        // Private Cloud Compute opportunistically on iOS 27/Xcode 27 builds) proposes
        // a final payload / reroute / WKWebView-JS directive that is validated and
        // applied by re-entering the raw IngestPipeline exactly once. MAIN-APP ONLY —
        // never link this into the share/action extensions (WKWebView runner, long
        // budgets, FoundationModels). Same tier as LunaPriceUI.
        // LunaMediaDownload: the engine's media-directive application resolves
        // assets through `SocialMediaResolving` — a behavioral dependency, not
        // just a payload type (the payload, `MediaAsset`, lives in LunaModels).
        // Known follow-up: article/product-only apps still BUILD the media
        // module through this edge.
        .target(name: "LunaURLRescue", dependencies: [
            "LunaAppConfig", "LunaModels", "LunaURLClassification", "LunaHTMLClassification",
            "LunaFetch", "LunaPaywallBypass", "LunaIngest", "LunaStorage",
            .product(name: "SwiftSoup", package: "SwiftSoup"),
        ]),
        .target(name: "LunaSocialUI", dependencies: ["LunaModels", "LunaStorage", "LunaDesignSystem", "LunaReadingList", "LunaSocial"]),
        .target(name: "LunaIntents", dependencies: ["LunaModels", "LunaStorage", "LunaURLClassification", "LunaHTMLClassification", "LunaIngest", "LunaFetch", "LunaReadingList", "LunaSocial"]),
        // Kind-neutral list UI (cells, sectioning, diff, subtitle assembly,
        // status pill): no per-kind modules — the kind-specific list behavior
        // lives behind the app shells' `ListKindSupport` seams.
        .target(name: "LunaReadingListUI", dependencies: ["LunaModels", "LunaDesignSystem"]),
        // Universal ingest orchestration linked by EVERY app: no kind-specific
        // modules here. Per-kind persistence lives behind `IngestorKindHandlers`
        // (implementations in LunaReaderUI / LunaPlatforms / LunaPriceUI),
        // registered by each app's `KindWiring` composition root.
        .target(name: "LunaReadingList", dependencies: ["LunaModels", "LunaStorage", "LunaIngest", "LunaURLClassification", "LunaHTMLClassification", "LunaFetch", "LunaMail", "LunaMailAccount", "LunaMailTransport", "LunaSocial"]),
        .testTarget(name: "LunaAppConfigTests", dependencies: ["LunaAppConfig"]),
        .testTarget(name: "LunaModelsTests", dependencies: ["LunaModels"]),
        .testTarget(name: "LunaURLClassificationTests", dependencies: ["LunaURLClassification"]),
        .testTarget(name: "LunaHTMLClassificationTests", dependencies: ["LunaHTMLClassification", "LunaModels"]),
        .testTarget(name: "LunaPaywallBypassTests", dependencies: ["LunaPaywallBypass", "LunaFetch"]),
        .testTarget(name: "LunaPriceMetadataTests", dependencies: ["LunaPriceMetadata"]),
        .testTarget(name: "LunaMailAccountTests", dependencies: ["LunaMailAccount"]),
    ],
    // Swift 5 language mode to match the app target — this is a structural
    // extraction, not a Swift 6 strict-concurrency migration (a separate effort).
    // Keeps behavior identical to the pre-extraction app module.
    swiftLanguageModes: [.v5]
)

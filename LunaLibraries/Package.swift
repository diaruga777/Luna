// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LunaLibraries",
    defaultLocalization: "en",
    // macOS support exists solely so the pure-library test suite can run in CI;
    // products are consumed by the iOS app and its extensions.
    // macOS 15 for `Synchronization.Mutex` (`OneShotLatch`,
    // `InMemoryCredentialStorage`). Nothing ships to macOS — the floor exists so
    // a `swift build` on the Mac still compiles the Foundation-only tiers.
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        // MARK: - Per-app kits
        //
        // One dynamic kit per content app. The app, every one of its
        // extensions, and the test bundle hosted on it link the kit and
        // NOTHING else from this package: a client that also links a static
        // product sharing targets with the kit makes Xcode promote every
        // doubly reached target into a framework of its own. The app target
        // embeds the kit once (its "Embed Frameworks" phase); the extensions
        // resolve it through their `@executable_path/../../Frameworks` rpath
        // and carry no copy. `scripts/link_app_kits.rb` owns those link edges.
        //
        // Each kit lists every target its app group reaches directly.
        // Transitive dependencies come along on their own.
        .library(name: "LunaKit", type: .dynamic, targets: [
            "LunaAppConfig", "LunaArchiveReader", "LunaArticleIngest", "LunaAudioPlayback",
            "LunaBundledPlugins", "LunaDesignSystem", "LunaDocuments", "LunaEpub",
            "LunaFetch", "LunaGaze", "LunaHTMLClassification", "LunaIngest",
            "LunaIntents", "LunaMailAccount", "LunaMailTransport", "LunaMediaDownload",
            "LunaMediaResolve", "LunaModels", "LunaPaywallBypass", "LunaPlatforms",
            "LunaPluginExport", "LunaPluginIngest", "LunaPluginKit", "LunaPluginRuntime",
            "LunaPluginTransport", "LunaPluginUI", "LunaPriceCompare", "LunaPriceIngest",
            "LunaPriceMetadata", "LunaPriceUI", "LunaReaderEngine", "LunaReaderUI",
            "LunaSaves", "LunaSavesUI", "LunaSend", "LunaShareSurface",
            "LunaSocial", "LunaSocialUI", "LunaStorage", "LunaTranscribe",
            "LunaTransitions", "LunaURLClassification", "LunaURLRescue", "LunaWeekly",
            // `LunaWriterModels` rides along under `LunaGaze`, which the
            // central app's Reader eye tracking uses. The rest of the Writer
            // tier is in the `LunaWriter` app and `LunaWriterTests` alone.
            "LunaWriterModels",
        ]),
        .library(name: "LunaReaderKit", type: .dynamic, targets: [
            "LunaAppConfig", "LunaArchiveReader", "LunaArticleIngest", "LunaAudioPlayback",
            "LunaDesignSystem", "LunaDocuments", "LunaEpub", "LunaFetch",
            "LunaHTMLClassification", "LunaIngest", "LunaIntents", "LunaMailAccount",
            "LunaMailTransport", "LunaMediaResolve", "LunaModels", "LunaPaywallBypass",
            "LunaPriceCompare", "LunaPriceMetadata", "LunaReaderEngine", "LunaReaderUI",
            "LunaSaves", "LunaSavesUI", "LunaSend", "LunaShareSurface",
            "LunaSocial", "LunaSocialUI", "LunaStorage", "LunaTransitions",
            "LunaURLClassification", "LunaURLRescue", "LunaWeekly",
        ]),
        .library(name: "LunaDownloaderKit", type: .dynamic, targets: [
            "LunaAppConfig", "LunaDesignSystem", "LunaFetch", "LunaHTMLClassification",
            "LunaIngest", "LunaIntents", "LunaMailAccount", "LunaMailTransport",
            "LunaMediaDownload", "LunaMediaResolve", "LunaModels", "LunaPlatforms",
            "LunaPriceCompare", "LunaPriceMetadata", "LunaSaves", "LunaSavesUI",
            "LunaShareSurface", "LunaSocial", "LunaSocialUI", "LunaStorage",
            "LunaTransitions", "LunaURLClassification", "LunaURLRescue", "LunaWeekly",
        ]),
        .library(name: "LunaPriceTrackerKit", type: .dynamic, targets: [
            "LunaAppConfig", "LunaDesignSystem", "LunaFetch", "LunaHTMLClassification",
            "LunaIngest", "LunaIntents", "LunaMailAccount", "LunaMailTransport",
            "LunaMediaResolve", "LunaModels", "LunaPriceCompare", "LunaPriceIngest",
            "LunaPriceMetadata", "LunaPriceUI", "LunaSaves", "LunaSavesUI",
            "LunaShareSurface", "LunaSocial", "LunaSocialUI", "LunaStorage",
            "LunaTransitions", "LunaURLClassification", "LunaURLRescue", "LunaWeekly",
        ]),
        // MARK: - Static products
        //
        // `LunaVault`, `LunaWriter`, their test bundles and the
        // `LunaVaultTailscale` package link these directly.
        .library(name: "LunaAppConfig", targets: ["LunaAppConfig"]),
        .library(name: "LunaModels", targets: ["LunaModels"]),
        .library(name: "LunaURLClassification", targets: ["LunaURLClassification"]),
        .library(name: "LunaHTMLClassification", targets: ["LunaHTMLClassification"]),
        .library(name: "LunaPaywallBypass", targets: ["LunaPaywallBypass"]),
        .library(name: "LunaPriceMetadata", targets: ["LunaPriceMetadata"]),
        .library(name: "LunaPriceCompare", targets: ["LunaPriceCompare"]),
        .library(name: "LunaTransitions", targets: ["LunaTransitions"]),
        .library(name: "LunaFetch", targets: ["LunaFetch"]),
        .library(name: "LunaIngest", targets: ["LunaIngest"]),
        .library(name: "LunaArticleIngest", targets: ["LunaArticleIngest"]),
        .library(name: "LunaPriceIngest", targets: ["LunaPriceIngest"]),
        .library(name: "LunaStorage", targets: ["LunaStorage"]),
        .library(name: "LunaDocuments", targets: ["LunaDocuments"]),
        .library(name: "LunaEpub", targets: ["LunaEpub"]),
        .library(name: "LunaSend", targets: ["LunaSend"]),
        .library(name: "LunaMailAccount", targets: ["LunaMailAccount"]),
        .library(name: "LunaMailTransport", targets: ["LunaMailTransport"]),
        .library(name: "LunaDesignSystem", targets: ["LunaDesignSystem"]),
        .library(name: "LunaPlatforms", targets: ["LunaPlatforms"]),
        .library(name: "LunaMediaResolve", targets: ["LunaMediaResolve"]),
        .library(name: "LunaMediaDownload", targets: ["LunaMediaDownload"]),
        .library(name: "LunaSocial", targets: ["LunaSocial"]),
        .library(name: "LunaWeekly", targets: ["LunaWeekly"]),
        .library(name: "LunaReaderEngine", targets: ["LunaReaderEngine"]),
        .library(name: "LunaAudioPlayback", targets: ["LunaAudioPlayback"]),
        .library(name: "LunaArchiveReader", targets: ["LunaArchiveReader"]),
        .library(name: "LunaReaderUI", targets: ["LunaReaderUI"]),
        .library(name: "LunaPriceUI", targets: ["LunaPriceUI"]),
        .library(name: "LunaShareSurface", targets: ["LunaShareSurface"]),
        .library(name: "LunaURLRescue", targets: ["LunaURLRescue"]),
        .library(name: "LunaSaves", targets: ["LunaSaves"]),
        .library(name: "LunaSocialUI", targets: ["LunaSocialUI"]),
        .library(name: "LunaIntents", targets: ["LunaIntents"]),
        .library(name: "LunaSavesUI", targets: ["LunaSavesUI"]),
        .library(name: "LunaPluginKit", targets: ["LunaPluginKit"]),
        .library(name: "LunaPluginRuntime", targets: ["LunaPluginRuntime"]),
        .library(name: "LunaPluginIngest", targets: ["LunaPluginIngest"]),
        .library(name: "LunaPluginExport", targets: ["LunaPluginExport"]),
        .library(name: "LunaPluginTransport", targets: ["LunaPluginTransport"]),
        .library(name: "LunaPluginUI", targets: ["LunaPluginUI"]),
        .library(name: "LunaBundledPlugins", targets: ["LunaBundledPlugins"]),
        .library(name: "LunaTranscribe", targets: ["LunaTranscribe"]),
        .library(name: "LunaVaultModels", targets: ["LunaVaultModels"]),
        .library(name: "LunaVaultBEP", targets: ["LunaVaultBEP"]),
        .library(name: "LunaVaultStore", targets: ["LunaVaultStore"]),
        .library(name: "LunaVaultMacPeer", targets: ["LunaVaultMacPeer"]),
        .library(name: "LunaVaultCrypto", targets: ["LunaVaultCrypto"]),
        .library(name: "LunaVaultStorage", targets: ["LunaVaultStorage"]),
        .library(name: "LunaVaultIndexExtraction", targets: ["LunaVaultIndexExtraction"]),
        .library(name: "LunaVaultEmbeddings", targets: ["LunaVaultEmbeddings"]),
        .library(name: "LunaVaultSearch", targets: ["LunaVaultSearch"]),
        .library(name: "LunaVaultBackend", targets: ["LunaVaultBackend"]),
        .library(name: "LunaVaultSync", targets: ["LunaVaultSync"]),
        .library(name: "LunaVaultSetup", targets: ["LunaVaultSetup"]),
        .library(name: "LunaVaultUI", targets: ["LunaVaultUI"]),
        .library(name: "LunaVaultMac", targets: ["LunaVaultMac"]),
        .library(name: "VaultTestKit", targets: ["VaultTestKit"]),
        // Luna Writer (claudedocs/plans/writer-app.md) and the gaze tracking it
        // shares with the Reader's RSVP eye tracking.
        .library(name: "LunaGaze", targets: ["LunaGaze"]),
        .library(name: "LunaWriterModels", targets: ["LunaWriterModels"]),
        .library(name: "LunaWriterText", targets: ["LunaWriterText"]),
        .library(name: "LunaWriterStorage", targets: ["LunaWriterStorage"]),
        .library(name: "LunaWriterVoice", targets: ["LunaWriterVoice"]),
        .library(name: "LunaWriterEditor", targets: ["LunaWriterEditor"]),
        .library(name: "LunaWriterReadAlong", targets: ["LunaWriterReadAlong"]),
        .library(name: "LunaWriterLibraryUI", targets: ["LunaWriterLibraryUI"]),
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
        // Alternative-seller price comparison (claudedocs/price-comparison.md):
        // the bundled seller directory, the local candidate ranking, a regex-only
        // page parser, and the fan-out orchestrator. DELIBERATELY LEAN — Models +
        // URLClassification + PriceMetadata and nothing else, all Foundation-only,
        // because the fan-out also runs inside the four Safari appexes, under a
        // hard memory ceiling and with no UI tier (`LunaMediaResolve` is the
        // precedent). No SwiftSoup, no UIKit, no LunaFetch: every network call and
        // the optional rich page resolution are INJECTED closures, so the app can
        // route them through the shared pipeline while the appex uses URLSession +
        // the regex parser.
        .target(
            name: "LunaPriceCompare",
            dependencies: ["LunaModels", "LunaURLClassification", "LunaPriceMetadata"],
            resources: [.process("Resources")]),
        .target(name: "LunaTransitions", dependencies: ["LunaDesignSystem"]),
        // LunaAppConfig: the Firecrawl search cooldown is App-Group state, so
        // every process that spends the one per-IP keyless budget reads the
        // same refusal.
        .target(name: "LunaFetch", dependencies: ["LunaModels", "LunaURLClassification", "LunaHTMLClassification", "LunaPriceMetadata", "LunaAppConfig", .product(name: "SwiftSoup", package: "SwiftSoup")]),
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
        // LunaStorage: every product page the pipeline classifies is recorded
        // in the shared SQLite snapshot table, in whichever process did the
        // classifying (app, share extension, action extension).
        .target(name: "LunaPriceIngest", dependencies: [
            "LunaIngest", "LunaHTMLClassification", "LunaPriceMetadata", "LunaURLClassification", "LunaModels", "LunaPriceCompare", "LunaStorage", .product(name: "SwiftSoup", package: "SwiftSoup")]),
        .target(name: "LunaStorage", dependencies: ["LunaAppConfig", "LunaModels", "LunaURLClassification"]),
        // SwiftSoup: EPUB and `.docx` are markup in a zip, and the `.html`
        // import is markup outright. Adds no link edge in practice — every
        // target that links LunaDocuments already links SwiftSoup.
        .target(name: "LunaDocuments", dependencies: ["LunaModels", .product(name: "SwiftSoup", package: "SwiftSoup")]),
        .target(name: "LunaEpub", dependencies: ["LunaModels"]),
        .target(name: "LunaSend", dependencies: ["LunaModels", "LunaStorage", "LunaEpub", "LunaMailAccount", "LunaAppConfig", "LunaURLClassification"]),
        .target(name: "LunaMailAccount", dependencies: ["LunaAppConfig", "LunaModels", "LunaStorage"]),
        // IMAP/SMTP engine for the multi-provider email account, built on
        // URLSessionStreamTask (implicit TLS + STARTTLS for iCloud) — no external
        // deps. Also holds the MIME/RFC822 parsers (`IMAPParsing`, `MIMEBody`),
        // the mail→article builder and `IncomingMailSettings`. Linked by the app,
        // not extensions.
        .target(name: "LunaMailTransport", dependencies: ["LunaMailAccount", "LunaSend", "LunaAppConfig", "LunaHTMLClassification", "LunaModels", "LunaStorage", "LunaPriceMetadata", "LunaURLClassification", .product(name: "SwiftSoup", package: "SwiftSoup")]),
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
        // Post-URL media RESOLUTION only (post URL → direct CDN asset), split out
        // of LunaMediaDownload so the Safari extension can call it without the
        // download machinery: resolution is Foundation + URLSession, while the
        // machinery around it pulls UIKit / Photos / ActivityKit / SwiftSoup, none
        // of which an appex under a hard memory ceiling can run.
        // LunaMediaDownload re-exports it, so no call site names the split
        // (`claudedocs/safari-extension.md`).
        .target(name: "LunaMediaResolve", dependencies: ["LunaModels", "LunaURLClassification"]),
        .target(
            name: "LunaMediaDownload",
            dependencies: ["LunaAppConfig", "LunaModels", "LunaURLClassification", "LunaMediaResolve", "LunaStorage", "LunaDesignSystem", "LunaShareSurface"],
            resources: [.process("Resources")]),
        .target(name: "LunaSocial", dependencies: ["LunaAppConfig", "LunaModels", "LunaStorage", "LunaURLClassification"]),
        // Save of the Week (claudedocs/save-of-the-week.md): the signed,
        // CloudKit-public-database-backed weekly pick, its local mirror, and the
        // proposal channel. Linked by the four APPS only — no extension writes
        // or reads it. CloudKit/CryptoKit/UserNotifications are system
        // frameworks, so there is nothing to declare here for them; the concrete
        // CloudKit client hides behind `WeeklyCloudDatabase` so tests never
        // touch a container.
        .target(name: "LunaWeekly", dependencies: ["LunaAppConfig", "LunaModels", "LunaStorage"]),
        .target(name: "LunaReaderEngine", dependencies: ["LunaModels"]),
        // Offline speech rendering (AVSpeechSynthesizer.write -> PCM) + a long-lived
        // AVAudioEngine playback graph, plus (Phase 2) the app-wide playback center,
        // Now Playing/remote-command integration, session policy, and App-Group
        // settings/position persistence — see claudedocs/audio-playback-plan.md.
        // LunaAppConfig (App-Group id) and LunaStorage (SavesStore access,
        // behind the SavesPlaybackStore seam) are Phase 2 additions; UI wiring
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
        .target(name: "LunaReaderUI", dependencies: ["LunaAppConfig", "LunaModels", "LunaGaze", "LunaReaderEngine", "LunaDesignSystem", "LunaStorage", "LunaHTMLClassification", "LunaFetch", "LunaPaywallBypass", "LunaArchiveReader", "LunaIngest", "LunaURLClassification", "LunaPriceMetadata", "LunaAudioPlayback", "LunaDocuments", "LunaArticleIngest", "LunaShareSurface", .product(name: "SwiftSoup", package: "SwiftSoup")]),
        // LunaSocial: `PriceRefreshCoordinator` posts price-drop local
        // notifications through LunaSocial's `NotificationManager`. No reader
        // modules: product-kind UI stands alone so the Price Tracker
        // extensions don't drag the whole reader stack in.
        .target(name: "LunaPriceUI", dependencies: ["LunaModels", "LunaDesignSystem", "LunaHTMLClassification", "LunaStorage", "LunaFetch", "LunaURLClassification", "LunaIngest", "LunaPriceIngest", "LunaPriceCompare", "LunaAppConfig", "LunaPriceMetadata", "LunaSocial", "LunaShareSurface", .product(name: "SwiftSoup", package: "SwiftSoup")]),
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
        .target(name: "LunaSocialUI", dependencies: ["LunaModels", "LunaStorage", "LunaDesignSystem", "LunaSaves", "LunaSocial"]),
        .target(name: "LunaIntents", dependencies: ["LunaModels", "LunaStorage", "LunaURLClassification", "LunaHTMLClassification", "LunaIngest", "LunaFetch", "LunaSaves", "LunaSocial"]),
        // Kind-neutral list UI (cells, sectioning, diff, subtitle assembly,
        // status pill): no per-kind modules — the kind-specific list behavior
        // lives behind the app shells' `ListKindSupport` seams.
        .target(name: "LunaSavesUI", dependencies: ["LunaModels", "LunaDesignSystem"]),
        // Universal ingest orchestration linked by EVERY app: no kind-specific
        // modules here. Per-kind persistence lives behind `IngestorKindHandlers`
        // (implementations in LunaReaderUI / LunaPlatforms / LunaPriceUI),
        // registered by each app's `KindWiring` composition root.
        .target(name: "LunaSaves", dependencies: ["LunaModels", "LunaStorage", "LunaIngest", "LunaURLClassification", "LunaHTMLClassification", "LunaFetch", "LunaMailAccount", "LunaMailTransport", "LunaSocial"]),
        // On-device transcription of a plugin's recording into a reader
        // article (claudedocs/plans/transcription-plugins.md §5). Linked by the
        // central Luna app and LunaTests only; AVFoundation + Speech, no UIKit.
        .target(name: "LunaTranscribe", dependencies: ["LunaModels", "LunaStorage", "LunaAppConfig", "LunaSaves"]),
        // The plugin platform (claudedocs/plans/plugin-platform.md §2.2). One
        // JavaScript file extends ingest and export; render stays native. Only
        // the CENTRAL Luna app and its extensions link any of this — the three
        // sibling apps are untouched by the pivot.
        //
        // Foundation-only floor: the manifest and its parser, the plugin store in
        // the App Group, the bundled catalog reader, and the App-Group-backed
        // fetch / kv / secrets / browser-request / pending-model stores. The
        // central Safari appex runs it, so it carries no UIKit and no
        // JavaScriptCore.
        .target(name: "LunaPluginKit", dependencies: [
            "LunaAppConfig", "LunaModels", "LunaStorage", "LunaURLClassification",
        ]),
        // The JavaScriptCore host: one context per loaded plugin, hook invocation,
        // result decoding, and the bridges a hook may call. SwiftSoup backs
        // `luna.html`; JavaScriptCore is a system framework, so it is linked
        // rather than declared as a package dependency.
        .target(
            name: "LunaPluginRuntime",
            dependencies: [
                "LunaPluginKit", "LunaStorage",
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            linkerSettings: [.linkedFramework("JavaScriptCore")]),
        // The classify + ingest walk that runs BEFORE the Swift classifier, the
        // Model decoding and adoption, and the browser deferral.
        .target(name: "LunaPluginIngest", dependencies: [
            "LunaPluginRuntime", "LunaIngest", "LunaFetch", "LunaURLRescue",
        ]),
        // The export stage, the export-input producers and plugin destinations.
        // App only: the mail transport and the share sheet do not exist in an
        // extension.
        .target(name: "LunaPluginExport", dependencies: [
            "LunaPluginRuntime", "LunaSend", "LunaEpub", "LunaMailAccount",
        ]),
        // `luna.bluetooth` and `luna.wifi`. CoreBluetooth, AccessorySetupKit and
        // NetworkExtension are system frameworks; AccessorySetupKit needs iOS 18,
        // which is the package's floor.
        .target(
            name: "LunaPluginTransport",
            dependencies: ["LunaPluginRuntime", "LunaSend"],
            linkerSettings: [
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("AccessorySetupKit"),
                .linkedFramework("NetworkExtension"),
            ]),
        // Settings -> Plugins, import and consent, the settings-schema renderer,
        // the prompts and the browser lock modal.
        .target(name: "LunaPluginUI", dependencies: [
            "LunaPluginRuntime", "LunaPluginIngest", "LunaPluginExport",
            "LunaDesignSystem", "LunaSavesUI", "LunaArchiveReader",
        ]),
        // Resources only: the plugins Luna ships with. `.copy` keeps the
        // directory shape, so the catalog enumerates one folder rather than a
        // flattened bundle root. The folder is NOT named `Resources`: a
        // directory by that name at a bundle's root makes `codesign` read the
        // bundle as a framework layout and refuse it as "bundle format
        // unrecognized, invalid, or unsuitable".
        .target(name: "LunaBundledPlugins", resources: [.copy("Plugins")]),
        // Luna Vault is deliberately layered independently from the legacy
        // URL-save graph. The extraction, embedding and search tiers have no
        // dependency path to a backend or networking target, so their work can
        // remain provably on-device as later implementations land.
        .target(name: "LunaVaultModels"),
        // Syncthing's Block Exchange Protocol (claudedocs/vault-bep-reference.md):
        // hand-written protobuf, framing, LZ4 block decoding, device IDs,
        // version vectors, block hashing, and the connection state machine.
        // Foundation + CryptoKit only. The iPhone and the Mac companion both
        // speak through it; the TLS transport underneath is the Go layer in
        // the LunaVaultTailscale package, reached through the `VaultPeer*`
        // protocol seams declared here.
        .target(name: "LunaVaultBEP"),
        // The Syncthing-era folder mirror and durable local-change/cache
        // state. Kept separate from the legacy encrypted storage module so
        // the migration can land without making the Vault share extension
        // depend on the network runtime.
        .target(
            name: "LunaVaultStore",
            dependencies: ["LunaAppConfig", "LunaVaultBEP"],
            linkerSettings: [.linkedLibrary("sqlite3")]),
        // The Mac companion's peer logic: folder scanner, `companion.sqlite`
        // index, BEP server sessions, pairing window, discovery announce loop.
        // Depends on LunaVaultBEP alone so it runs against fake transports in
        // LunaVaultTests; FSEvents is behind `#if os(macOS)`. The executable in
        // the LunaVaultTailscale package wires the real listeners.
        .target(name: "LunaVaultMacPeer", dependencies: ["LunaVaultBEP"]),
        .target(name: "LunaVaultCrypto", dependencies: [
            "LunaVaultModels", "LunaAppConfig",
        ]),
        .target(name: "LunaVaultStorage", dependencies: [
            "LunaVaultModels", "LunaVaultCrypto", "LunaAppConfig",
        ]),
        .target(name: "LunaVaultIndexExtraction", dependencies: [
            "LunaVaultModels", "LunaDocuments",
        ]),
        .target(name: "LunaVaultEmbeddings", dependencies: [
            "LunaVaultModels",
        ]),
        .target(name: "LunaVaultSearch", dependencies: [
            "LunaVaultModels", "LunaVaultCrypto", "LunaVaultStorage", "LunaVaultEmbeddings",
            "LunaVaultIndexExtraction",
        ]),
        .target(name: "LunaVaultBackend", dependencies: [
            "LunaVaultModels", "LunaVaultCrypto", "LunaVaultStorage",
        ]),
        .target(name: "LunaVaultSync", dependencies: [
            "LunaVaultModels", "LunaVaultCrypto", "LunaVaultStorage",
            "LunaVaultBackend", "LunaVaultBEP", "LunaVaultStore",
        ]),
        .target(name: "LunaVaultSetup", dependencies: [
            "LunaVaultModels", "LunaVaultCrypto",
            "LunaVaultStorage", "LunaVaultIndexExtraction", "LunaVaultEmbeddings",
            "LunaVaultSearch",
        ]),
        .target(name: "LunaVaultUI", dependencies: [
            "LunaDesignSystem", "LunaAppConfig", "LunaVaultModels", "LunaVaultCrypto",
            "LunaVaultStorage", "LunaVaultIndexExtraction",
            "LunaVaultEmbeddings", "LunaVaultSearch", "LunaVaultBackend",
            "LunaVaultSync", "LunaVaultSetup",
        ]),
        // The companion library is macOS-only by product usage. It is
        // Foundation/Network based and keeps all transport state behind the
        // Vault backend protocol; iOS never links this product. The companion
        // executable lives in the LunaVaultTailscale package, which carries
        // the embedded-Tailscale binary this package must stay free of.
        .target(name: "LunaVaultMac", dependencies: [
            "LunaVaultModels", "LunaVaultCrypto", "LunaVaultBackend",
        ]),
        // Test support is a product so the existing app-hosted LunaTests bundle
        // can exercise the same public seams. Production targets never link it.
        .target(name: "VaultTestKit", dependencies: [
            "LunaVaultModels", "LunaVaultCrypto", "LunaVaultStorage",
            "LunaVaultIndexExtraction", "LunaVaultEmbeddings",
            "LunaVaultSearch", "LunaVaultBackend", "LunaVaultSync",
            "LunaVaultSetup",
        ]),
        // LunaGaze: ARKit face-tracking gaze samples, screen projection, bias
        // calibration and the pure reading tracker. Shared by LunaReaderUI (RSVP
        // eye tracking, which re-exports it) and Luna Writer's read-along.
        // Depends on LunaWriterModels for SentenceLayout/WordLayout alone — the
        // ARKit-facing half stays gated by `#if canImport(ARKit)` inside the
        // module, so this dependency is the only reason a non-Apple-platform
        // `swift build` of LunaGaze needs anything beyond Foundation.
        .target(name: "LunaGaze", dependencies: ["LunaWriterModels"]),
        // Luna Writer tiers, bottom up. Foundation-only through LunaWriterVoice;
        // UIKit from LunaWriterEditor up. See claudedocs/plans/writer-app.md §2.
        .target(name: "LunaWriterModels"),
        .target(name: "LunaWriterText", dependencies: ["LunaWriterModels"]),
        .target(name: "LunaWriterStorage", dependencies: ["LunaWriterModels", "LunaWriterText", "LunaModels"]),
        .target(name: "LunaWriterVoice", dependencies: ["LunaWriterModels"]),
        .target(name: "LunaWriterEditor", dependencies: [
            "LunaWriterModels", "LunaWriterText", "LunaWriterStorage", "LunaDesignSystem", "LunaModels",
        ]),
        .target(name: "LunaWriterReadAlong", dependencies: [
            "LunaWriterModels", "LunaWriterText", "LunaWriterStorage", "LunaWriterEditor",
            "LunaWriterVoice", "LunaGaze", "LunaDesignSystem", "LunaModels",
        ]),
        .target(name: "LunaWriterLibraryUI", dependencies: [
            "LunaWriterModels", "LunaWriterText", "LunaWriterStorage", "LunaWriterEditor",
            "LunaWriterReadAlong", "LunaDesignSystem", "LunaModels",
        ]),
    ],
    // Swift 5 language mode to match the app target — this is a structural
    // extraction, not a Swift 6 strict-concurrency migration (a separate effort).
    // Keeps behavior identical to the pre-extraction app module.
    swiftLanguageModes: [.v5]
)

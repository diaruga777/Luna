//
//  SafariWebExtensionHandler.swift
//  LunaSafari
//

import LunaAppConfig
import LunaMediaResolve
import LunaModels
import LunaPriceCompare
import LunaStorage
import LunaURLClassification
import SafariServices

/// The plugin platform's message-handling seam
/// (`claudedocs/plans/plugin-platform.md` §13.1). Only the central Luna app
/// runs any plugin platform at all, and this file is the ONE shared source
/// built into all four Safari appexes — so it names no plugin-runtime module
/// at the source level, and it never guards on the compiler's module-
/// visibility check (that check resolves per this file's own compilation and
/// is not a reliable per-TARGET signal; see CLAUDE.md). `SafariPluginMessages
/// .handler` is the real per-target answer instead: the central appex
/// compiles `SafariPluginMessages+Luna.swift` (a genuine implementation), and
/// the other three compile `SafariPluginMessages+None.swift` (`nil`) — a
/// membership-exception split, the same mechanism
/// `KindWiring+Luna.swift`/`KindWiring+Reader.swift` use.
protocol SafariPluginMessaging: AnyObject {
    /// Whether this host offers plugins at all — `buttonContext`'s
    /// `supportsPlugins` field.
    var supportsPlugins: Bool { get }
    /// Handles one `plugins.*` message, completing `context` itself (directly
    /// or from a Task) when it returns `true`. `false` means this handler did
    /// not recognize `type` — the caller then answers `{"error":"unsupported"}`.
    func handle(type: String, message: [String: Any]?, context: NSExtensionContext) -> Bool
}

/// Receives native messages from the extension's JavaScript. It stores the active
/// Safari URL for the SaveLink intent, answers the button-visibility and
/// paywall-unlock questions the scripts ask, stores already-unlocked article HTML
/// so the app can render it without a re-fetch, and — for the two media-handling
/// hosts — resolves a social post's playable video for the in-page player.
///
/// Every branch here is an ADAPTER: parse the message, call shared package code,
/// serialize the answer. No extraction, classification, or parsing logic lives in
/// this file — see the "Where the work runs" section of
/// `claudedocs/safari-extension.md`.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    private static let appGroupID = AppConfig.appGroupID
    private static let suggestionModeKey = "safariSuggestionMode"
    /// The in-page player's off switch, written by the two media apps' Settings
    /// (`SafariSuggestionSettings.videoPlayerKey`, pinned by
    /// `SafariVideoOverlayContractTests`). Absent means ON — the player is the
    /// shipped behavior, and a user who never opened Settings has written
    /// nothing.
    private static let videoPlayerKey = "safariVideoPlayerEnabled"
    /// The annoyance layer's cookie auto-decline off switch, written by the two
    /// ARTICLE apps' Settings (`SafariSuggestionSettings.cookieAutoDeclineKey`,
    /// pinned by `SafariAnnoyanceGateContractTests`). Absent means ON — answering
    /// "necessary cookies only" is the shipped behavior, and a user who never
    /// opened Settings has written nothing.
    private static let cookieAutoDeclineKey = "safariCookieAutoDeclineEnabled"

    /// A resolve is several chained network fetches (YouTube's is four), so it
    /// needs a real budget — but an appex that never completes its request wedges
    /// the page's `sendMessage` promise forever. The JS side sets a slightly
    /// longer one of its own so a killed appex degrades too.
    private static let resolveTimeout: TimeInterval = 20
    /// A Safari → app → Safari bounce can recreate the content-script DOM even
    /// though it is still the same page. Reuse the resolve from moments ago so
    /// the replacement player receives its source immediately instead of
    /// reopening at the default shape while another network ladder runs.
    private static let playbackResolveReuseLifetime: TimeInterval = 10 * 60
    /// Long enough for a cold containing-app launch and its Live Activity to be
    /// created, but short enough that a responder-chain open which never lands
    /// cannot bounce a manual app launch back to an old Safari page tomorrow.
    private static let downloadReturnHandoffLifetime: TimeInterval = 60

    func beginRequest(with context: NSExtensionContext) {
        let surface = Self.host.storageIdentifier
        let scheme = Self.hostScheme
        LunaSetupStatusStore.shared.recordSafariExtensionRun(for: Self.host)
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        var payload: [String: Any] = ["ok": true]

        switch message?["type"] as? String {
        case "buttonMode", "buttonContext":
            // The app writes SafariSuggestionMode's rawValue (default "all") into
            // the App-Group defaults every host reads. A non-article host must not
            // receive it: its own "never"/"onlyLocked" would silence the
            // Downloader's and Price Tracker's pills too. Only Reader and the
            // central app expose the setting (`ShortcutSettingsScreen
            // .visibleSections`), and it gates only the article branch of
            // `offerLunaButton` — this mirrors that gate on the native side.
            if Self.hostHandlesArticles {
                payload["mode"] = UserDefaults(suiteName: Self.appGroupID)?
                    .string(forKey: Self.suggestionModeKey) ?? "all"
            }
            // The pill deep-links ONLY into this extension's own containing app,
            // and only for the content kinds that app handles: the central Luna
            // app handles everything; each single-content app handles one kind.
            payload["scheme"] = scheme
            // Which app's chrome the page renders. The setup confirmation belongs
            // to the app, not to any page kind, so it takes the app's own identity
            // colour. A pill never asks this — it takes the colour of the kind it
            // saves (see `KIND_TINTS` in content.js).
            payload["surface"] = surface
            payload["supportsArticles"] = Self.hostHandlesArticles
            payload["supportsMedia"] = Self.hostHandlesMedia
            payload["supportsProducts"] = Self.hostHandlesProducts
            // Only the central app's extension runs the plugin walk: the three
            // single-kind apps keep their fixed Swift heuristics.
            payload["supportsPlugins"] = SafariPluginMessages.handler?.supportsPlugins ?? false
            // Whether a media page opens the in-page player. It rides the context
            // the page already asks for; a non-media host never sends it, since its
            // pages have no player to suppress. An absent key means ON.
            if Self.hostHandlesMedia {
                payload["videoPlayer"] = UserDefaults(suiteName: Self.appGroupID)?
                    .object(forKey: Self.videoPlayerKey) as? Bool ?? true
            }
            // Rides the context the content script already asks for, so the
            // celebration decision costs no extra round trip. The script
            // suppresses its pill for the confirmation's lifetime.
            payload["celebrateSetup"] = LunaSetupStatusStore.shared
                .shouldCelebrateSafariSetup(for: Self.host)
            payload["appName"] = LunaSetupStatusStore.shared
                .safariSetupTapAppName(for: Self.host) ?? Self.hostDisplayName
        case "annoyanceSettings":
            // The document_start annoyance script's one gate, asked through
            // background.js before it touches a cookie dialog. This is a separate
            // message, not a rider on `buttonContext`, because content.js sends
            // that one at document_idle — a whole page load too late to decide
            // whether a banner may be clicked.
            //
            // The key lives in the App-Group suite all four apps share. Only the
            // two article apps expose the control: a non-article host must not
            // read it at all, or a Reader "off" would silence the Downloader's and
            // Price Tracker's always-on suppression too. Same shape as the `mode`
            // gate above.
            payload["cookieAutoDecline"] = Self.hostHandlesArticles
                ? (UserDefaults(suiteName: Self.appGroupID)?
                    .object(forKey: Self.cookieAutoDeclineKey) as? Bool ?? true)
                : true
        case "setupCelebrationShown":
            // Written when the overlay renders, not when the decision is made: a
            // context request whose page never showed one must stay eligible.
            LunaSetupStatusStore.shared.recordSafariCelebrationShown(for: Self.host)
        case "bypassEnabled":
            // On-device unlocking is article handling. Only article-capable hosts
            // (Reader and the central app) enable the Referer ruleset and the
            // in-page reveal; the receiving Luna surface decides how to present
            // the captured article.
            payload["enabled"] = Self.hostHandlesArticles && SafariPluginMessages.handler == nil
        case "saveContent":
            // The content script hands over the already-unlocked article HTML. The
            // app renders it as prefetched content instead of re-fetching a page
            // that would re-lock outside Safari.
            if let urlString = message?["url"] as? String, urlString.hasPrefix("http"),
               let html = message?["html"] as? String {
                SafariContentStore.record(urlString, html: html)
            }
        case "resolveMedia":
            guard SafariPluginMessages.handler == nil else { break }
            // The in-page player's one round trip. It resolves this post to a
            // direct CDN asset with the same `SocialMediaResolver` the app and the
            // share/action extensions run, caches the full result for a possible
            // download, and answers with just the URL a `<video>` can stream.
            // Completes from a Task — see `resolveMedia(…)`.
            resolveMedia(message: message, context: context)
            return
        case "queueResolvedDownload":
            guard SafariPluginMessages.handler == nil else { break }
            // "Download what you resolved for this page." The assets never left
            // Swift (`ResolvedMediaCache`), so the page hands back only its own
            // URL. The app drains the queue on the deep link that follows.
            payload["queued"] = queueResolvedDownload(message: message)
        case "productSnapshot":
            guard SafariPluginMessages.handler == nil else { break }
            // Passive product-page data. It is persisted (Feature 1: seeds a
            // tracker's history at save time) and answered against the
            // app-written tracker rows and snapshot tables (Feature 3: the
            // "Was $X" history pill) in the same round trip — one page-side
            // extraction, one message. This never saves anything: nothing here
            // schedules a refresh or writes a save row.
            if Self.hostHandlesProducts, let snapshot = message?["snapshot"] as? [String: Any] {
                let now = Date()
                ProductSnapshotStore.shared.record(payload: snapshot, now: now)
                if let record = ProductSnapshotStore.makeSnapshot(fromPayload: snapshot, now: now) {
                    let answer = SharedProductMatching.historyAnswer(forPageSnapshot: record)
                    payload["isTracked"] = answer.isTracked
                    payload["hasHistory"] = answer.hasHistory
                    payload["amount"] = answer.amount
                    payload["currency"] = answer.currency
                    payload["day"] = answer.day
                }
            }
        case "comparableSellers":
            guard SafariPluginMessages.handler == nil else { break }
            // "Is this cheaper somewhere else, right now?" Asked once per product
            // page, after `productSnapshot` has already recorded it. This is a
            // second round trip, not a rider on the first, because the answer may
            // take seconds (a live fan-out) while the history pill's does not — a
            // page should not wait to learn what it already knows. Completes from
            // a Task — see `comparableSellers(…)`.
            comparableSellers(message: message, context: context)
            return
        case let type? where type.hasPrefix("plugins."):
            // Every `plugins.*` message goes through the per-target seam:
            // a real answer from the central host
            // (`SafariPluginMessages+Luna.swift`), or nothing from the other
            // three (`SafariPluginMessages+None.swift`, `handler == nil`).
            if let handler = SafariPluginMessages.handler,
               handler.handle(type: type, message: message, context: context) {
                return
            }
            payload["error"] = "unsupported"
        default:
            if let urlString = message?["url"] as? String, urlString.hasPrefix("http") {
                SafariURLStore.record(urlString)
                SafariRecentHistoryStore.shared.record(urlString)
            }
        }

        complete(context, with: payload)
    }

    private func complete(_ context: NSExtensionContext, with payload: [String: Any]) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: payload]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    // MARK: - In-page video (media hosts only)

    /// Resolves the post at `url` and answers the page with a streamable URL.
    ///
    /// The one asynchronous branch. It retains `self` and the context in the Task
    /// — an `NSExtensionContext` may outlive `beginRequest` as long as it
    /// completes exactly once. Every path below completes exactly once, including
    /// the timeout, so the page's promise always settles.
    private func resolveMedia(message: [String: Any]?, context: NSExtensionContext) {
        guard Self.hostHandlesMedia else {
            complete(context, with: ["unsupported": true])
            return
        }
        guard let urlString = message?["url"] as? String, urlString.hasPrefix("http"),
              let url = URL(string: urlString) else {
            complete(context, with: ["assets": []])
            return
        }
        let title = (message?["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let cached = ResolvedMediaCache.shared.record(forURLString: urlString),
           Date().timeIntervalSince(cached.dateWritten) < Self.playbackResolveReuseLifetime {
            let playable = cached.assets.filter(\.isDirectlyPlayable)
            complete(context, with: ["assets": playable.map(Self.messageDictionary(for:))])
            return
        }
        Task {
            let assets = await Self.resolveWithinBudget(url)
            if !assets.isEmpty {
                ResolvedMediaCache.shared.store(ResolvedMediaRecord(
                    sourceURLString: urlString, title: title, assets: assets,
                    dateWritten: Date()))
            }
            // Only what the page can actually stream. `isDirectlyPlayable` is
            // LunaMediaResolve's rule — no separate audio track to mux, not a
            // still — rather than a platform list. That is why Reddit's split
            // DASH streams answer empty here, with no need to name Reddit in
            // this file.
            let playable = assets.filter(\.isDirectlyPlayable)
            self.complete(context, with: ["assets": playable.map(Self.messageDictionary(for:))])
        }
    }

    /// JSON-safe projection of an asset for the page: what to play, and what to
    /// show while it loads. It carries only what the page needs, not the whole
    /// `MediaAsset` — the page has no use for a byte estimate or a DASH
    /// manifest, and anything it never receives cannot corrupt on the way back.
    private static func messageDictionary(for asset: MediaAsset) -> [String: Any] {
        var dictionary: [String: Any] = [
            "url": asset.url.absoluteString,
            "kind": asset.kind.rawValue,
        ]
        if let thumbnail = asset.thumbnailURL { dictionary["thumbnailURL"] = thumbnail.absoluteString }
        // The clip's shape, as far as the resolve knows it (LunaMediaResolve
        // reads it; nothing is parsed here). It arrives a whole network round
        // trip before the element's own metadata, so the panel opens at the
        // right height instead of reshaping itself once the stream loads.
        if let size = asset.declaredPixelSize {
            dictionary["width"] = size.width
            dictionary["height"] = size.height
        }
        return dictionary
    }

    /// `SocialMediaResolver` under a wall-clock budget. A resolve that overruns
    /// is abandoned — the page falls back to handing the link to the app —
    /// instead of leaving the request, and the page, hanging.
    private static func resolveWithinBudget(_ url: URL) async -> [MediaAsset] {
        await TimeLimit.run(resolveTimeout) {
            await SocialMediaResolver().resolveAssets(for: url)
        } ?? []
    }

    // MARK: - Alternative sellers (product hosts only)

    /// Answers the page with the lowest current price for this product on
    /// another retailer, or with nothing.
    ///
    /// The second asynchronous branch, with the same contract as `resolveMedia`:
    /// the context outlives `beginRequest`, and every path completes it exactly
    /// once. `ComparableSellerFinder` carries its own wall-clock budget, so even
    /// a fan-out that never lands settles the page's promise.
    private func comparableSellers(message: [String: Any]?, context: NSExtensionContext) {
        guard Self.hostHandlesProducts,
              let snapshot = message?["snapshot"] as? [String: Any],
              let record = ProductSnapshotStore.makeSnapshot(fromPayload: snapshot, now: Date())
        else {
            complete(context, with: ComparableSellerFinder.messagePayload(for: nil))
            return
        }
        Task {
            let answer = await ComparableSellerFinder.answer(forPageSnapshot: record)
            self.complete(context, with: ComparableSellerFinder.messagePayload(for: answer))
        }
    }

    /// Promotes this page's cached resolve into the app's download queue.
    /// Returns whether anything was queued: an expired resolve, or a page that
    /// was never resolved, leaves the page to fall back to the plain hand-off.
    /// It queues the full asset set, including a split audio stream the in-page
    /// player could not use — the app can mux; the browser can't.
    private func queueResolvedDownload(message: [String: Any]?) -> Bool {
        guard Self.hostHandlesMedia,
              let urlString = message?["url"] as? String, urlString.hasPrefix("http"),
              let record = ResolvedMediaCache.shared.record(forURLString: urlString)
        else { return false }
        PendingResolvedMediaStore.shared.append(ResolvedMediaRecord(
            sourceURLString: record.sourceURLString, title: record.title,
            assets: record.assets, dateWritten: record.dateWritten,
            returnToSourceUntil: Date().addingTimeInterval(
                Self.downloadReturnHandoffLifetime)))
        return !record.assets.isEmpty
    }

    /// Fallback name for the "Return to …" button when no app stamped one at its
    /// setup tap. `scripts/update_safari_extension_branding.sh` rewrites this
    /// extension's own display name to its host app's at build time, so it
    /// already reads "Luna Reader", "Luna Price Tracker", and so on.
    private static var hostDisplayName: String {
        let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? ""
        return name.isEmpty ? "Luna" : name
    }

    /// This extension's containing app. An extension's bundle id is its host
    /// app's id plus `.safari`, which `LunaApp` resolves the same way from
    /// inside any other Luna extension. Its `storageIdentifier` is the surface
    /// name the App-Group setup keys are built from, so the two halves of the
    /// Safari hand-off meet by construction.
    private static let host = LunaApp.detect(bundleIdentifier: Bundle.main.bundleIdentifier)

    /// The URL scheme this extension's page buttons deep-link into. Always the
    /// containing app's own scheme — an extension may only hand content to the
    /// app it is embedded in.
    private static let hostScheme = LunaDeepLink.appScheme(
        forBundleIdentifier: Bundle.main.bundleIdentifier) ?? LunaDeepLink.lunaScheme

    /// Per-kind capability of this extension's containing app, from the bundle
    /// id suffix. The central Luna app's extension has the bare
    /// `<prefix>.safari` id (no content suffix) and handles every kind.
    private static var isCentralLunaHost: Bool {
        !isHost(appSuffix: ".reader") && !isHost(appSuffix: ".downloader")
            && !isHost(appSuffix: ".pricetracker")
    }

    private static var hostHandlesArticles: Bool {
        isCentralLunaHost || isHost(appSuffix: ".reader")
    }

    private static var hostHandlesMedia: Bool {
        isCentralLunaHost || isHost(appSuffix: ".downloader")
    }

    private static var hostHandlesProducts: Bool {
        isCentralLunaHost || isHost(appSuffix: ".pricetracker")
    }

    private static func isHost(appSuffix: String) -> Bool {
        (Bundle.main.bundleIdentifier ?? "").hasSuffix(appSuffix + ".safari")
    }
}

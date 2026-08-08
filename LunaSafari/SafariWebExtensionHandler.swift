//
//  SafariWebExtensionHandler.swift
//  LunaSafari
//

import LunaMediaResolve
import LunaModels
import LunaStorage
import SafariServices

/// Receives native messages from the extension's JavaScript: persists the active
/// Safari URL (for the SaveLink intent), answers the "Read in Luna" button-visibility
/// and paywall-unlock settings the scripts ask for, stashes the already-unlocked
/// article HTML so the app can render it without re-fetching, and — for the two
/// media-handling hosts — resolves a social post's playable video for the in-page
/// player.
///
/// Every branch here is an ADAPTER: parse the message, call shared package code,
/// serialize the answer. No extraction, classification or parsing logic lives in
/// this file — see the "Where the work runs" section of
/// `claudedocs/safari-extension.md`.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    private static let appGroupID = SafariAppGroup.id
    private static let suggestionModeKey = "safariSuggestionMode"

    /// A resolve is several chained network fetches (YouTube's is four), so it
    /// needs a real budget — but an appex that never completes its request wedges
    /// the page's `sendMessage` promise forever. The JS side sets a slightly
    /// longer one of its own so a killed appex degrades too.
    private static let resolveTimeout: TimeInterval = 20

    func beginRequest(with context: NSExtensionContext) {
        let (surface, scheme) = SharedSurfaceScheme.currentSurfaceAndScheme
        SharedSafariURL.recordExtensionRun(
            isCentral: Self.isCentralLunaHost, surface: surface)
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        var payload: [String: Any] = ["ok": true]

        switch message?["type"] as? String {
        case "buttonMode", "buttonContext":
            // The app stores SafariSuggestionMode's rawValue here (default "all"),
            // in the App-Group-shared defaults every host reads — so a non-article
            // host must not receive it: its own "never"/"onlyLocked" would
            // otherwise silence the Downloader/Price Tracker pills too. The
            // setting itself is exposed only in Reader and the central app's
            // Settings (`ShortcutSettingsScreen.visibleSections`), and its mode
            // only ever gates the article branch of `offerLunaButton` — this
            // mirrors that here, on the native side.
            if Self.hostHandlesArticles {
                payload["mode"] = UserDefaults(suiteName: Self.appGroupID)?
                    .string(forKey: Self.suggestionModeKey) ?? "all"
            }
            // The pill deep-links ONLY into this extension's own containing app,
            // and only for the content kinds that app handles: the central Luna
            // app handles everything; each single-content app handles one kind.
            payload["scheme"] = scheme
            payload["supportsArticles"] = Self.hostHandlesArticles
            payload["supportsMedia"] = Self.hostHandlesMedia
            payload["supportsProducts"] = Self.hostHandlesProducts
            // Rides the context the content script already asks for, so deciding
            // whether to congratulate the user costs no extra round trip. The
            // script suppresses its pill for the confirmation's lifetime.
            payload["celebrateSetup"] = SharedSafariURL.shouldCelebrateSetup(surface: surface)
            payload["appName"] = SharedSafariURL.setupTapAppName(surface: surface)
                ?? Self.hostDisplayName
        case "setupCelebrationShown":
            // Written when the overlay renders, not when the decision is made: a
            // context request whose page never showed one must stay eligible.
            SharedSafariURL.recordCelebrationShown(surface: surface)
        case "bypassEnabled":
            // On-device unlocking is article handling, so only article-capable
            // hosts (Reader and the central Luna app) enable the Referer
            // ruleset + in-page reveal; the receiving Luna surface decides how
            // to present the captured article.
            payload["enabled"] = Self.hostHandlesArticles
        case "saveContent":
            // The content script hands over the already-unlocked article HTML so the
            // app can render it as prefetched content (never re-fetching a page that
            // would re-lock outside Safari).
            if let urlString = message?["url"] as? String, urlString.hasPrefix("http"),
               let html = message?["html"] as? String {
                SharedSafariURL.recordUnlockedContent(urlString, html: html)
            }
        case "resolveMedia":
            // The in-page player's one round trip: resolve this post to a direct
            // CDN asset with the SAME `SocialMediaResolver` the app and the
            // share/action extensions run, cache the full result for a possible
            // download, and answer with just the URL a `<video>` can stream.
            // Completes from a Task — see `resolveMedia(…)`.
            resolveMedia(message: message, context: context)
            return
        case "queueResolvedDownload":
            // "Download what you resolved for this page." The assets never left
            // Swift (`ResolvedMediaCache`), so the page hands back nothing but
            // its own URL; the app drains the queue on the deep link that follows.
            payload["queued"] = queueResolvedDownload(message: message)
        case "productSnapshot":
            // Passive product-page data: persisted (Feature 1, seeds a tracker's
            // history at save time) and answered against the app-written tracked
            // index + the snapshot file (Feature 3, the "Was $X" history pill) in
            // the SAME round trip — one page-side extraction, one message. Never a
            // save: nothing here schedules a refresh or writes a reading-list row.
            if Self.hostHandlesProducts, let snapshot = message?["snapshot"] as? [String: Any] {
                SharedProductSnapshots.record(snapshot)
                if let record = SharedProductSnapshots.makeRecord(from: snapshot, now: Date()) {
                    let answer = SharedProductMatching.historyAnswer(forPageSnapshot: record)
                    payload["isTracked"] = answer.isTracked
                    payload["hasHistory"] = answer.hasHistory
                    payload["amount"] = answer.amount
                    payload["currency"] = answer.currency
                    payload["day"] = answer.day
                }
            }
        case "comparableSellers":
            // "Is this cheaper somewhere else, right now?" — asked once per
            // product page, after `productSnapshot` has already recorded it.
            // A second round trip rather than a rider on the first because the
            // answer may take seconds (a live fan-out) while the history pill's
            // does not, and a page should not wait to learn what it already
            // knows. Completes from a Task — see `comparableSellers(…)`.
            comparableSellers(message: message, context: context)
            return
        default:
            if let urlString = message?["url"] as? String, urlString.hasPrefix("http") {
                SharedSafariURL.record(urlString)
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
    /// The ONE asynchronous branch: it retains `self` and the context in the Task
    /// (an `NSExtensionContext` outliving `beginRequest` is legal as long as it is
    /// completed exactly once), and every path below completes exactly once —
    /// including the timeout, so the page's promise always settles.
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
        Task {
            let assets = await Self.resolveWithinBudget(url)
            if !assets.isEmpty {
                ResolvedMediaCache.shared.store(ResolvedMediaRecord(
                    sourceURLString: urlString, title: title, assets: assets,
                    dateWritten: Date()))
            }
            // Only what the page can actually stream. `isDirectlyPlayable` is
            // LunaMediaResolve's rule (no separate audio track to mux, not a
            // still) rather than a platform list — which is why Reddit's split
            // DASH streams answer empty here without this file naming Reddit.
            let playable = assets.filter(\.isDirectlyPlayable)
            self.complete(context, with: ["assets": playable.map(Self.messageDictionary(for:))])
        }
    }

    /// JSON-safe projection of an asset for the page: what to play, and what to
    /// show while it loads. Deliberately NOT the whole `MediaAsset` — the page
    /// has no use for a byte estimate or a DASH manifest, and anything it does
    /// not receive it cannot corrupt on the way back.
    private static func messageDictionary(for asset: MediaAsset) -> [String: Any] {
        var dictionary: [String: Any] = [
            "url": asset.url.absoluteString,
            "kind": asset.kind.rawValue,
        ]
        if let thumbnail = asset.thumbnailURL { dictionary["thumbnailURL"] = thumbnail.absoluteString }
        return dictionary
    }

    /// `SocialMediaResolver` under a wall-clock budget. A resolve that overruns
    /// is abandoned (the page falls back to handing the link to the app) rather
    /// than leaving the request — and the page — hanging.
    private static func resolveWithinBudget(_ url: URL) async -> [MediaAsset] {
        await withTaskGroup(of: [MediaAsset]?.self) { group in
            group.addTask { await SocialMediaResolver().resolveAssets(for: url) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(resolveTimeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }

    // MARK: - Alternative sellers (product hosts only)

    /// Answers the page with the lowest CURRENT price for this product on
    /// another retailer, or with nothing.
    ///
    /// The second asynchronous branch, and the same contract as `resolveMedia`:
    /// the context outlives `beginRequest` and every path completes it exactly
    /// once — `ComparableSellerFinder` carries its own wall-clock budget, so
    /// even a fan-out that never lands settles the page's promise.
    private func comparableSellers(message: [String: Any]?, context: NSExtensionContext) {
        guard Self.hostHandlesProducts,
              let snapshot = message?["snapshot"] as? [String: Any],
              let record = SharedProductSnapshots.makeRecord(from: snapshot, now: Date())
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
    /// Returns whether anything was queued — a resolve that expired, or a page
    /// that was never resolved, leaves the page to fall back to the plain
    /// hand-off. The FULL asset set is queued, including a split audio stream
    /// the in-page player could not use: the app can mux, the browser can't.
    private func queueResolvedDownload(message: [String: Any]?) -> Bool {
        guard Self.hostHandlesMedia,
              let urlString = message?["url"] as? String, urlString.hasPrefix("http"),
              let record = ResolvedMediaCache.shared.record(forURLString: urlString)
        else { return false }
        PendingResolvedMediaStore.shared.append(record)
        return !record.assets.isEmpty
    }

    /// Fallback name for the "Return to …" button when no app stamped one with its
    /// setup tap. `scripts/update_safari_extension_branding.sh` rewrites this
    /// extension's OWN display name to its host app's at build time, so it already
    /// reads "Luna Reader" / "Luna Price Tracker" / …
    private static var hostDisplayName: String {
        let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? ""
        return name.isEmpty ? "Luna" : name
    }

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

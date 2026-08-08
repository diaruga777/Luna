//
//  AppDelegate.swift
//  Luna
//

import LunaReadingList
import LunaIngest
import LunaSocial
import LunaSocialUI
import LunaMailAccount
import LunaDesignSystem
import LunaStorage
import LunaWeekly
import BackgroundTasks
import UIKit
import UserNotifications
import os
import LunaModels

@main
final class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    private let logger = Logger(subsystem: "com.hsanabria.luna", category: "push")
    /// Periodic task (~twice daily) that reads new mail: imports recognized Luna
    /// shares (adding new senders to Contacts) and matched newsletters, so
    /// shares arrive even if the app is never opened.
    private static let mailFetchTaskID = "com.hsanabria.luna.mailFetch"
    private static let mailFetchInterval: TimeInterval = 12 * 60 * 60
    /// Periodic task (~every 12h) that re-fetches every non-archived price
    /// tracker's store prices and fires a local notification on a first drop past
    /// threshold. Processing-class (needs network) like the mail fetch.
    private static let priceRefreshTaskID = "com.hsanabria.luna.priceRefresh"
    private static let priceRefreshInterval: TimeInterval = 12 * 60 * 60
    private var readingListObserver: NSObjectProtocol?
    private var wifiAvailableObserver: NSObjectProtocol?
    /// Price trackers surface only in product-handling apps (Price Tracker and
    /// the central Luna app), so only those install a refresh runner — and only
    /// a target with a runner registers and schedules the price-refresh job.
    /// Otherwise every app redundantly refreshes the shared store's trackers.
    private var schedulesPriceRefresh: Bool { KindWiring.priceRefreshRunner != nil }
    /// Whether this app does email at all — gates the mail-fetch background task
    /// (and its scheduling) the same way `schedulesPriceRefresh` gates the price
    /// job. Downloader and Price Tracker connect no account, so there is nothing
    /// for a mail fetch to read.
    private var sharesByEmail: Bool { LunaApp.current.sharesByEmail }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        #if DEBUG
        // FIRST, before anything resolves a store: a staged launch points the
        // whole App Group container at a throwaway directory and suite, so
        // everything below — including this app's own launch bookkeeping —
        // writes to scratch (`claudedocs/staging.md`). No-op without
        // `-LunaStage`.
        LunaStage.prepareIfNeeded()
        #endif
        DiagnosticLog.shared.record("app launch", category: "lifecycle")
        // Register this app's per-kind pipeline processors, handlers, and UI
        // seams FIRST — everything below (launch re-ingest, intents, list UI)
        // consults the registries. Exactly one KindWiring variant is compiled
        // per app target; kind-specific launch work (audio wiring, pending-
        // completion promotion, transport injection) lives in its `install()`.
        KindWiring.install()
        // Onboarding's own launch bookkeeping, before any root reads its state:
        // stamp the start of a first run (or of the run a reset just began), then
        // latch completion if a save has arrived since — a save from ANY surface
        // answers the first-run card, and the latch survives deleting it.
        AppOnboardingStore.shared.beginOnboardingIfNeeded()
        AppOnboardingStore.shared.markCompletedIfSavedSinceOnboardingStart()
        // A setup button that is genuinely done stops being offered — here for
        // one finished in an earlier session, and again on the way to the
        // background for one finished in this one. Skipped legs keep their
        // button. See `claudedocs/util-card.md`.
        AppOnboardingStore.shared.retireCompletedSetupButtons()
        UtilCardContentViewController.setupJourneyLauncher = { presenter, source in
            AppOnboardingViewController.presentSetupReplay(
                source,
                from: presenter,
                makeCompletedRootViewController:
                    KindWiring.makeSetupReplayRootViewController)
        }
        // Move reader settings into the App Group so the share-extension reader
        // honors them (WPM, font, highlight color, …).
        ReaderSettings.migrateFromStandardIfNeeded()
        // Mark this surface installed so any Safari extension host knows which
        // sibling Luna apps its page buttons can deep-link into.
        InstalledAppMarkers.recordCurrentApp()
        // Diagnostic-only: the account address just feeds a log line, so defer the
        // Keychain read off the launch frame (a just-rebooted device's Keychain
        // query can be slow).
        DispatchQueue.global(qos: .utility).async {
            let account = EmailAccountStore.shared.account?.address ?? "none"
            DiagnosticLog.shared.record("email account: \(account)", category: "mail")
        }

        // Unsupported-kind error for dropped INTERACTIVE in-app saves:
        // LunaReadingList can't present UI, so the app shell installs the
        // presenter (same injected-closure pattern as
        // PriceTrackingViewController.intelligentPriceResolver above). Presents
        // over whatever is frontmost — the SAME card the share/action extensions
        // show, full screen so it reads as one of the deck's own cards rather
        // than a system alert.
        ReadingListIngestor.unsupportedSavePresenter = { owner in
            guard let presenter = Self.frontmostViewController() else { return }
            let card = UnsupportedSaveCardViewController(owner: owner)
            card.modalPresentationStyle = .fullScreen
            card.onDone = { [weak card] in card?.dismiss(animated: true) }
            presenter.present(card, animated: true)
        }

        // Save of the Week (claudedocs/save-of-the-week.md): LunaWeekly can't see
        // the ingest pipeline, so the shell hands it the one metadata read the
        // row needs. `.luna` deliberately — a faceted app must be able to render
        // whichever kind it fetched, and it only ever fetches its own.
        WeeklySaveRefresher.metadataFetcher = { urlString in
            guard let preview = await RecentURLMatcher.evaluate(
                urlString: urlString, surface: .luna)
            else { return nil }
            let host = URL(string: preview.urlString)?.host
                ?? preview.subtitle ?? preview.urlString
            return (title: preview.title, host: host, imageData: preview.imageData)
        }

        // The weekly pull starts NOW, not with the end-of-launch housekeeping:
        // the util card wants its Save of the Week row the moment the deck
        // appears, and the fetch is a network round-trip that only gets slower
        // the later it leaves. The task body still runs off the launch frame
        // (the main actor is busy until didFinishLaunching returns).
        if !LunaStage.isActive {
            Task(priority: .userInitiated) { @MainActor in
                await WeeklySaveRefresher.shared.refreshWeeklySaves()
            }
        }

        // Diagnostics export header shows the connected email account (which lives
        // above LunaStorage), injected here.
        DiagnosticLog.exportIdentityProvider = {
            EmailAccountStore.shared.account?.address ?? "none"
        }

        // Phase 7 (Siri): keep ArticleEntity's Spotlight index in sync with the
        // reading list so saved articles are semantically discoverable and
        // Siri can resolve "my article about …"/"from …" without the app
        // running. Main app only (extensions don't index).
        if !LunaStage.isActive { ArticleSpotlightIndexWiring.install() }

        // URL Rescue (claudedocs/url-rescue.md): install the LLM-fallback engine
        // bridge + coordinator (all three apps; main-app only — extensions never
        // link the engine). Must precede ingestAllPending() so the ingestor's
        // rescueTrigger is set before the launch re-ingest can surface failures.
        URLRescueWiring.install()

        // Warm the Wi-Fi reachability monitor (background preloads are Wi-Fi-gated) and
        // run the one-time image-ownership backfill so images shared with pre-existing
        // saves/preloads are reference-counted before any preload release could delete one.
        if !LunaStage.isActive {
            DispatchQueue.global(qos: .utility).async {
                _ = NetworkReachability.shared
                ImageReferenceStore.shared.backfillIfNeeded(readingList: .shared, preloads: .shared)
            }
        }

        // Retry any items whose content download didn't finish (e.g. saved from the
        // background intent without network time).
        // Both are skipped in staged mode: the re-ingest would resolve the very
        // saves a stage froze mid-fetch, and the launch sweep would purge the
        // media a stage just seeded. This is what makes a staged screen HOLD.
        if !LunaStage.isActive {
            ReadingListIngestor.shared.ingestAllPending()
            // Kind-specific launch resumption: orphaned-media sweep + Live Activity
            // reattachment (media apps), pending ereader-send retry (article apps).
            KindWiring.appDidLaunch()
        }

        // Local notifications: show as banners while open. Launch does NOT ask for
        // authorization — a fresh install has nothing to notify anyone about, so the
        // prompt would arrive before its reason exists. Every posting feature asks
        // at the moment the user opts into it instead, and there are exactly three:
        // pasting the Save of the Week key (`DiagnosticsViewController`), connecting
        // a sending account (`CredentialViewController`), and committing a price
        // alert threshold (the two price editors). `requestAuthorization` is a no-op
        // once the choice has been made, so each of those may ask unconditionally.
        UNUserNotificationCenter.current().delegate = self

        // Mail fetch only where there's a mailbox to read: Downloader and Price
        // Tracker share by plain URL and connect no account (see `sharesByEmail`).
        if sharesByEmail {
            BGTaskScheduler.shared.register(
                forTaskWithIdentifier: Self.mailFetchTaskID, using: nil
            ) { [weak self] task in
                self?.handleMailFetch(task as? BGProcessingTask)
            }
        }
        // Registered unconditionally: an identifier must be claimed before
        // launch returns, and this device can become a key-holder later in the
        // same session. Both the scheduler and the handler no-op without a key.
        WeeklyProposalBackgroundCheck.register()
        // Price refresh only on the Price Tracker surface (see schedulesPriceRefresh).
        if schedulesPriceRefresh {
            BGTaskScheduler.shared.register(
                forTaskWithIdentifier: Self.priceRefreshTaskID, using: nil
            ) { [weak self] task in
                self?.handlePriceRefresh(task as? BGProcessingTask)
            }
        }
        readingListObserver = NotificationCenter.default.addObserver(
            forName: .readingListChanged, object: nil, queue: .main
        ) { [weak self] _ in
            // Deliberately bundles two unrelated follow-ups on one notification: neither
            // has its own natural trigger, and "the reading list just changed" is a
            // good-enough proxy for both "some activity happened, take out the trash"
            // (purge expired saved media) and "prices may be worth checking again soon"
            // (reschedule the price refresh) — not a sign this observer needs splitting.
            //
            KindWiring.readingListDidChange()
            self?.schedulePriceRefresh(reason: "reading list changed")
        }
        // Resume whatever a Wi-Fi-only network policy deferred, the instant
        // Wi-Fi reconnects — the app-launch/foreground and background-refresh
        // resumes below cover the other two triggers. What resumes is a kind
        // decision (media downloads / article link preloads).
        wifiAvailableObserver = NotificationCenter.default.addObserver(
            forName: NetworkReachability.wifiAvailableNotification, object: nil, queue: nil
        ) { _ in
            KindWiring.wifiBecameAvailable()
        }

        // Read incoming mail (Luna shares + newsletters).
        if sharesByEmail && !LunaStage.isActive {
            Task { await IncomingMailImporter.shared.importNewMail() }
            scheduleMailFetch()
        }
        // Both calls start with a full readingList.json decode
        // (priceTrackersStalestFirst() -> items()); defer that store read off the
        // launch frame. BGTaskScheduler and DiagnosticLog are thread-safe, and
        // each call still runs exactly once per launch — just not synchronously
        // before didFinishLaunching returns.
        if schedulesPriceRefresh && !LunaStage.isActive {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.schedulePriceRefresh(reason: "launch")
                self?.refreshOverduePriceTrackersOnLaunch()
            }
        }
        // Off the launch frame too: the proposal check is key-holder-only
        // housekeeping no visible surface is waiting on. (The weekly pull
        // itself starts earlier, at user-initiated priority — the card's row
        // is waiting on that one.)
        if !LunaStage.isActive {
            DispatchQueue.global(qos: .utility).async {
                WeeklyProposalBackgroundCheck.schedule(reason: "launch")
                Task { @MainActor in
                    await WeeklySaveRefresher.shared.checkProposalsIfKeyHolder()
                }
            }
        }
        #if DEBUG
        // LAST, once every catalog has been installed above: answer
        // `-LunaStageList` with the manifest and exit. Never reached without it.
        LunaStage.finishLaunchIfNeeded()
        #endif
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // A staged run backgrounds and returns during a screenshot pass; none of
        // this housekeeping should be allowed to reflow the screen it captured
        // (retiring a setup button is exactly that).
        guard !LunaStage.isActive else { return }
        // Kind-specific background work: pending-completion promotion + send
        // retry (article apps), Live Activity reattachment (media apps).
        KindWiring.appDidEnterBackground()
        // The util card reflows behind the user's back: a setup button finished
        // in this session is retired now, freeing its slot for the email nudge.
        AppOnboardingStore.shared.retireCompletedSetupButtons()
        scheduleMailFetch()
        schedulePriceRefresh(reason: "entered background")
        WeeklyProposalBackgroundCheck.schedule(reason: "entered background")
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // Background URLSessions belong to the media download manager; apps
        // without the media kind complete the callback immediately.
        KindWiring.attachBackgroundURLSessionHandler(completionHandler)
    }

    private func scheduleMailFetch() {
        // Reached from the background handlers too, so guard here rather than at
        // every call site (see `sharesByEmail`).
        guard sharesByEmail else { return }
        let request = BGProcessingTaskRequest(identifier: Self.mailFetchTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.mailFetchInterval)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.error("Couldn't schedule mail fetch: \(String(describing: error), privacy: .public)")
        }
    }

    private func handleMailFetch(_ task: BGProcessingTask?) {
        guard let task else { return }
        DiagnosticLog.shared.record("mail-fetch task fired", category: "mail")
        scheduleMailFetch() // chain the next one (~twice daily)
        // Expiration handler installed BEFORE the work starts, and an expired
        // run reports failure — mirrors handlePriceRefresh, so the scheduler's
        // model of this task stays honest.
        var work: Task<Void, Never>?
        task.expirationHandler = {
            DiagnosticLog.shared.record("mail-fetch task expired", category: "mail")
            work?.cancel()
        }
        work = Task {
            await IncomingMailImporter.shared.importNewMail()
            KindWiring.retryPendingArticleSends()
            // Overnight backstop for every unfinished media job, including a
            // transfer whose server supplied resume data after an interruption.
            // The background URLSession continues after this processing task
            // exits. (No-op outside the Downloader app.)
            await KindWiring.resumeUnfinishedMediaDownloads()
            task.setTaskCompleted(success: !Task.isCancelled)
        }
    }

    private func schedulePriceRefresh(reason: String) {
        // Reached from the reading-list observer and background handlers too, so
        // guard here rather than at every call site (see schedulesPriceRefresh).
        guard schedulesPriceRefresh else { return }
        let trackers = ReadingListStore.shared.priceTrackersStalestFirst()
        let activeTrackers = trackers.count
        guard activeTrackers > 0 else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.priceRefreshTaskID)
            return
        }
        // IDEMPOTENT scheduling. We are called on many events (launch, foreground,
        // EVERY reading-list change, after a run); the old code cancelled and
        // resubmitted the request each time. Repeatedly cancelling+resubmitting a
        // BGTask churns it so iOS never lets it mature/run — the "never fires" bug.
        // So if a request is ALREADY pending, leave it untouched; only submit when
        // nothing is pending (the first tracker, or after a run/expiration consumed
        // it). The earliest date is derived from the oldest actual refresh (not now),
        // so a never-refreshed tracker still fires ASAP. The next run reschedules.
        BGTaskScheduler.shared.getPendingTaskRequests { [weak self] pending in
            guard let self else { return }
            if pending.contains(where: { $0.identifier == Self.priceRefreshTaskID }) {
                return  // already pending — leave it to mature (see idempotency note)
            }
            let request = BGProcessingTaskRequest(identifier: Self.priceRefreshTaskID)
            let oldestRefresh = trackers
                .map { ReadingListStore.stalestRefresh($0.priceTracker) }
                .min() ?? .distantPast
            let dueDate = oldestRefresh.addingTimeInterval(Self.priceRefreshInterval)
            request.earliestBeginDate = max(Date(), dueDate)
            request.requiresNetworkConnectivity = true
            request.requiresExternalPower = false
            do {
                try BGTaskScheduler.shared.submit(request)
                DiagnosticLog.shared.record(
                    "price refresh: scheduled \(activeTrackers) active tracker(s), earliest=\(request.earliestBeginDate?.description ?? "unknown") (\(reason))",
                    category: "price")
            } catch {
                self.logger.error("Couldn't schedule price refresh: \(String(describing: error), privacy: .public)")
                DiagnosticLog.shared.record(
                    "price refresh: schedule FAILED (\(reason)): \(error)", category: "price")
            }
        }
    }

    /// iOS decides when a BGProcessingTask actually runs, and it may defer it
    /// for power or scheduling reasons. When the user opens the app with a stale
    /// tracker, make that missed background work up immediately rather than
    /// leaving the displayed price stale until the OS grants another launch.
    private func refreshOverduePriceTrackersOnLaunch() {
        guard let runner = KindWiring.priceRefreshRunner else { return }
        let trackers = ReadingListStore.shared.priceTrackersStalestFirst()
        guard let oldest = trackers
            .map({ ReadingListStore.stalestRefresh($0.priceTracker) })
            .min(),
              oldest.addingTimeInterval(Self.priceRefreshInterval) <= Date()
        else { return }

        DiagnosticLog.shared.record(
            "price refresh: launch fallback started for \(trackers.count) overdue active tracker(s)",
            category: "price")
        Task { [weak self] in
            let processed = await runner()
            DiagnosticLog.shared.record(
                "price refresh: launch fallback completed, processed=\(processed)",
                category: "price")
            self?.schedulePriceRefresh(reason: "launch fallback completion")
        }
    }

    private func handlePriceRefresh(_ task: BGProcessingTask?) {
        guard let task else {
            DiagnosticLog.shared.record("price refresh: handler received wrong task type", category: "price")
            return
        }
        DiagnosticLog.shared.record("price refresh: background task started", category: "price")
        // Expiration handler installed BEFORE the work starts, and an expired run
        // reports failure — mirrors handleMailFetch, so an expiration landing
        // immediately never finds the task without a handler.
        var work: Task<Void, Never>?
        task.expirationHandler = {
            // The refresher persists each tracker as it finishes and processes
            // stalest-first, so a cancelled run still made progress.
            DiagnosticLog.shared.record("price refresh: background task expired", category: "price")
            work?.cancel()
            self.schedulePriceRefresh(reason: "background expiration")
        }
        work = Task { [weak self] in
            // The handler is only registered when a runner exists (see
            // schedulesPriceRefresh), so the fallback 0 is unreachable.
            let processed = await KindWiring.priceRefreshRunner?() ?? 0
            KindWiring.retryPendingArticleSends()
            let completed = !Task.isCancelled
            task.setTaskCompleted(success: completed)
            DiagnosticLog.shared.record(
                "price refresh: background task completed success=\(completed), processed=\(processed)",
                category: "price")
            self?.schedulePriceRefresh(reason: "background completion")
        }
    }

    /// Show share notifications as banners even while the app is open.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// Handle a notification tap. A pending-request notification deep-links to
    /// the Pending Requests screen; everything else just opens the app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        if userInfo[NotificationManager.typeKey] as? String == NotificationManager.typePendingRequest {
            await MainActor.run { SceneDelegate.routeToPendingRequests() }
        }
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(
            name: connectingSceneSession.configuration.name,
            sessionRole: connectingSceneSession.role
        )
        config.delegateClass = SceneDelegate.self
        return config
    }

    /// The frontmost view controller of the key window — where globally-injected
    /// prompts (the unsupported-kind alert) present from, since their trigger (an
    /// async ingest) has no view-controller context of its own.
    static func frontmostViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

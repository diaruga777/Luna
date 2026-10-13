//
//  AppDelegate.swift
//  Luna
//

import LunaSaves
import LunaIngest
import LunaSocial
import LunaSocialUI
import LunaMailAccount
import LunaAppConfig
import LunaDesignSystem
import LunaStorage
import LunaWeekly
import BackgroundTasks
import UIKit
import UserNotifications
import os
import LunaModels

/// One pass over every tracked product's seller prices, the body of the
/// price-refresh background job.
///
/// Kind-neutral by construction (a count, no price-module types), so it lives in
/// the universal app shell; the answer comes from `KindWiring.priceRefreshRunner`,
/// which only the two product-handling apps fill. Its presence is also the gate:
/// an app with no runner never registers or schedules the job, so the other two
/// don't redundantly refresh the shared store's trackers.
protocol PriceRefreshRunning {
    /// Refreshes every non-archived tracker, notifies on a first drop past
    /// threshold, and returns how many trackers were processed.
    func runPriceRefresh() async -> Int
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    private let logger = Logger(subsystem: LunaLogging.subsystem, category: "push")
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
    private var savesObserver: NSObjectProtocol?
    private var wifiAvailableObserver: NSObjectProtocol?
    private var launchRevealObserver: NSObjectProtocol?
    private var hasStartedLaunchMaintenance = false
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
        // Catch a broken xcconfig -> Info.plist chain immediately rather than
        // silently falling back to the compiled-in App Group id and splitting
        // the shared container from every extension. All four apps share this
        // launch path, so one assert covers them.
        assert(AppConfig.resolvedFromInfoPlist, "LunaAppGroupID did not resolve from Info.plist")
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
        // Move reader settings into the App Group so the share-extension reader
        // honors them (WPM, font, highlight color, …).
        ReaderSettings.migrateFromStandardIfNeeded()
        // Mark this surface installed so any Safari extension host knows which
        // sibling Luna apps its page buttons can deep-link into.
        InstalledAppMarkers.recordCurrentApp()
        // Unsupported-kind error for dropped INTERACTIVE in-app saves:
        // LunaSaves can't present UI, so the app shell installs the
        // presenter. This is the same cross-tier protocol-witness pattern as
        // `DiagnosticLog.exportIdentityProvider`.
        SavesIngestor.unsupportedSavePresenter = UnsupportedSaveCardPresenter()

        // A plugin-locked save is finished by re-running the pipeline for the
        // same id, and the flow that presents the browser step sits above
        // LunaSaves. An app with no plugin platform installs this too and
        // never has a locked save to resume.
        PluginResumeSeams.resumer = SavesIngestor.shared

        // Save of the Week (claudedocs/save-of-the-week.md): LunaWeekly can't see
        // the ingest pipeline, so the shell hands it the one metadata read the
        // row needs.
        WeeklySaveRefresher.metadataFetcher = WeeklyRowMetadataFetcher()

        // Diagnostics export header shows the connected email account (which lives
        // above LunaStorage), injected here.
        DiagnosticLog.exportIdentityProvider = ConnectedAccountExportIdentity()

        // URL Rescue (claudedocs/url-rescue.md): install the LLM-fallback engine
        // bridge + coordinator (all three apps; main-app only — extensions never
        // link the engine). Must precede ingestAllPending() so the ingestor's
        // rescueTrigger is set before the launch re-ingest can surface failures.
        URLRescueWiring.install()

        // The observer must exist before a cold Safari hand-off is routed.
        // Retrying old saves and lifecycle sweeps wait for the first card.
        if !LunaStage.isActive { BackgroundIngestCompletion.install() }

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
        savesObserver = NotificationCenter.default.addObserver(
            forName: .savesChanged, object: nil, queue: .main
        ) { [weak self] _ in
            // This bundles two unrelated follow-ups on one notification. Neither
            // has its own natural trigger, and "the saves list just changed" is a
            // good-enough proxy for both: take out the trash (purge expired saved
            // media) and check whether prices are worth rechecking (reschedule the
            // price refresh). That overlap is not a reason to split the observer.
            guard let self, self.hasStartedLaunchMaintenance else { return }
            KindWiring.savesDidChange()
            self.schedulePriceRefresh(reason: "saves list changed")
        }
        // Resume whatever a Wi-Fi-only network policy deferred, the instant
        // Wi-Fi reconnects — the app-launch/foreground and background-refresh
        // resumes below cover the other two triggers. What resumes is a kind
        // decision (media downloads / article link preloads).
        wifiAvailableObserver = NotificationCenter.default.addObserver(
            forName: NetworkReachability.wifiAvailableNotification, object: nil, queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard self?.hasStartedLaunchMaintenance == true else { return }
                KindWiring.wifiBecameAvailable()
            }
        }

        // A main-queue task enqueued during didFinishLaunching can still run
        // before UIKit commits the window. Use the actual reveal completion.
        // Background-only launches have no window to wait for.
        if !LunaStage.isActive {
            launchRevealObserver = NotificationCenter.default.addObserver(
                forName: AppLaunchTransition.didFinish, object: nil, queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.async { self?.startLaunchMaintenance() }
            }
            // A normal scene launch can still report .background here. Wait
            // for scene connection before deciding there is no UI to reveal.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard application.connectedScenes.isEmpty,
                      application.applicationState == .background else { return }
                self?.startLaunchMaintenance()
            }
        }
        #if DEBUG
        // LAST, once every catalog has been installed above: answer
        // `-LunaStageList` with the manifest and exit. Never reached without it.
        LunaStage.finishLaunchIfNeeded()
        #endif
        return true
    }

    /// Runs once after the launch card is visible, or immediately for a
    /// background-only wake. Deep links already have all of their wiring.
    func startLaunchMaintenance() {
        guard !LunaStage.isActive, !hasStartedLaunchMaintenance else { return }
        hasStartedLaunchMaintenance = true
        if let launchRevealObserver {
            NotificationCenter.default.removeObserver(launchRevealObserver)
            self.launchRevealObserver = nil
        }

        DispatchQueue.global(qos: .utility).async {
            let account = EmailAccountStore.shared.account?.address ?? "none"
            DiagnosticLog.shared.record("email account: \(account)", category: "mail")
            _ = NetworkReachability.shared
            SavesStore.shared.reapPendingDeletes()
            WeeklyProposalBackgroundCheck.schedule(reason: "launch")
        }
        Task { @MainActor in
            await WeeklySaveRefresher.shared.refreshWeeklySaves()
            await WeeklySaveRefresher.shared.checkProposalsIfKeyHolder()
        }
        SavesIngestor.shared.ingestAllPending()
        BackgroundIngestCompletion.runFromLifecycle()
        KindWiring.appDidLaunch()
        // The first scene foreground callback is skipped below; run its
        // kind-specific resumptions here, after launch installation completes.
        KindWiring.sceneDidForeground()
        if sharesByEmail {
            Task { await IncomingMailImporter.shared.importNewMail() }
            scheduleMailFetch()
        }
        if schedulesPriceRefresh {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.schedulePriceRefresh(reason: "launch")
                self?.refreshOverduePriceTrackersOnLaunch()
            }
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // A staged run backgrounds and returns during a screenshot pass; none of
        // this housekeeping should be allowed to reflow the screen it captured
        // (retiring a setup button is exactly that).
        guard !LunaStage.isActive else { return }
        startLaunchMaintenance()
        // Kind-specific background work: pending-completion promotion + send
        // retry (article apps), Live Activity reattachment (media apps).
        KindWiring.appDidEnterBackground()
        // The util card reflows behind the user's back: a setup button finished
        // in this session is retired now, freeing its slot for the email nudge.
        AppOnboardingStore.shared.retireCompletedSetupButtons()
        scheduleMailFetch()
        schedulePriceRefresh(reason: "entered background")
        WeeklyProposalBackgroundCheck.schedule(reason: "entered background")
        // A file released by an extension while this app was in the foreground has
        // nobody else to unlink it.
        SavesStore.shared.reapPendingDeletes()
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // Background URLSessions belong to the media download manager; apps
        // without the media kind complete the callback immediately.
        KindWiring.attachBackgroundURLSessionHandler(
            identifier: identifier, completionHandler)
        // The one wake this process is guaranteed to get without the user
        // touching anything: the transfer a Safari hand-off started just
        // finished. If that hand-off's metadata pass was cut short by an
        // expiring background window, this is where it resumes — on its own
        // lease, so it never delays the session handler above.
        BackgroundIngestCompletion.runFromLifecycle()
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
            task.setTaskCompleted(success: !Task.isCancelled)
        }
    }

    private func schedulePriceRefresh(reason: String) {
        // Reached from the saves observer and background handlers too, so
        // guard here rather than at every call site (see schedulesPriceRefresh).
        guard schedulesPriceRefresh else { return }
        let trackers = SavesStore.shared.priceTrackersStalestFirst()
        let activeTrackers = trackers.count
        guard activeTrackers > 0 else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.priceRefreshTaskID)
            return
        }
        // Scheduling is idempotent. This runs on many events (launch, foreground,
        // every saves list change, after a run), but repeatedly cancelling and
        // resubmitting a BGTask churns it so iOS never lets it mature — it never
        // fires. So a pending request is left untouched, and a new one is
        // submitted only when none is pending (the first tracker, or after a
        // run or expiration clears it). The earliest date comes from the oldest
        // actual refresh, not now, so a never-refreshed tracker still fires as
        // soon as possible. The next run reschedules from there.
        BGTaskScheduler.shared.getPendingTaskRequests { [weak self] pending in
            guard let self else { return }
            if pending.contains(where: { $0.identifier == Self.priceRefreshTaskID }) {
                return  // already pending — leave it to mature (see idempotency note)
            }
            let request = BGProcessingTaskRequest(identifier: Self.priceRefreshTaskID)
            let oldestRefresh = trackers
                .map { SavesStore.stalestRefresh($0.priceTracker) }
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
        let trackers = SavesStore.shared.priceTrackersStalestFirst()
        guard let oldest = trackers
            .map({ SavesStore.stalestRefresh($0.priceTracker) })
            .min(),
              oldest.addingTimeInterval(Self.priceRefreshInterval) <= Date()
        else { return }

        DiagnosticLog.shared.record(
            "price refresh: launch fallback started for \(trackers.count) overdue active tracker(s)",
            category: "price")
        Task { [weak self] in
            let processed = await runner.runPriceRefresh()
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
            let processed = await KindWiring.priceRefreshRunner?.runPriceRefresh() ?? 0
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

    /// The `userInfo` key a plugin notification's deep link travels under.
    ///
    /// It is a hand-copy of `SystemPluginNotificationCenter.deepLinkKey`: this
    /// file compiles into all four apps and only the central one links the
    /// plugin tier. `PluginNotificationDeepLinkTests` pins the two equal.
    static let pluginDeepLinkUserInfoKey = "lunaPluginDeepLink"

    /// A tapped plugin notification opens the link the plugin asked for, back
    /// through the app's own URL handling — the same route a `luna:` link from
    /// anywhere else takes.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let link = info[Self.pluginDeepLinkUserInfoKey] as? String,
              let url = URL(string: link)
        else { return }
        await UIApplication.shared.open(url)
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

/// The unsupported-kind card for a dropped interactive save, presented over
/// whatever is frontmost — the SAME card the share/action extensions show, full
/// screen so it reads as one of the deck's own cards rather than a system alert.
private struct UnsupportedSaveCardPresenter: UnsupportedSavePresenting {
    @MainActor
    func presentUnsupportedSave(owner: LunaApp) {
        guard let presenter = AppDelegate.frontmostViewController() else { return }
        let card = UnsupportedSaveCardViewController(owner: owner)
        card.modalPresentationStyle = .fullScreen
        card.delegate = DropCardDismisser.shared
        presenter.present(card, animated: true)
    }
}

/// In the app the drop card is a full-screen presentation over the deck, so Done
/// just takes it back down. Stateless, and a `static let` because the card holds
/// its delegate weakly.
@MainActor
private final class DropCardDismisser: UnsupportedSaveCardDelegate {
    static let shared = DropCardDismisser()

    func unsupportedSaveCardDidFinish(_ card: UnsupportedSaveCardViewController) {
        card.dismiss(animated: true)
    }
}

/// The one metadata read the Save of the Week row needs. `.luna` deliberately —
/// a faceted app must be able to render whichever kind it fetched, and it only
/// ever fetches its own.
private struct WeeklyRowMetadataFetcher: WeeklyMetadataFetching {
    func fetchMetadata(
        forURLString urlString: String
    ) async -> (title: String, host: String, imageData: Data?)? {
        guard let preview = await RecentURLMatcher.evaluate(
            urlString: urlString, surface: .luna)
        else { return nil }
        let host = URL(string: preview.urlString)?.host
            ?? preview.subtitle ?? preview.urlString
        return (title: preview.title, host: host, imageData: preview.imageData)
    }
}

/// The connected sending account, for the diagnostics export header.
private struct ConnectedAccountExportIdentity: DiagnosticExportIdentityProviding {
    var exportIdentity: String {
        EmailAccountStore.shared.account?.address ?? "none"
    }
}

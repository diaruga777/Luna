//
//  StageCatalog+Shared.swift
//  Luna
//

#if DEBUG

import LunaDesignSystem
import LunaModels
import LunaReadingListUI
import LunaShareSurface
import LunaURLClassification
import LunaStorage
import LunaWeekly
import UIKit

/// Stages every app has, because every app has these screens: its card deck,
/// the util card at index zero, the failed-save card (a failed save carries no
/// kind, so it belongs to nobody and therefore to everyone), and the settings
/// tree that is not kind-specific.
///
/// Compiled into all four targets — no membership exception. The kind catalogs
/// beside it are the ones that are per-target.
enum SharedStageCatalog {

    /// Delegates a staged surface needs kept alive: a replica or a card holds
    /// its delegate weakly, and a stage has no host to own one.
    @MainActor
    private static var stageRetained: [AnyObject] = []

    @MainActor
    static func install() {
        StageRegistry.register(
            deckStages + utilCardStages + cardStages + settingsStages
                + safariLessonStages + messagesLessonStages)
    }

    // MARK: - The Messages lesson

    /// The save lesson, playing itself: the other timed sequence in onboarding,
    /// and the one that ends on somebody else's screen. The conversation lands
    /// bubble by bubble, the Action Button press ripples over the link, the mock
    /// Dynamic Island runs the shortcut, and the sheet carries the REAL share
    /// surface saving this app's practice link — so the last third of this stage
    /// is whatever that app's own save result looks like (the Downloader's
    /// saved-media screen with the clip playing in it, the Price Tracker's price
    /// editor, the Reader's preview).
    ///
    /// It has no browser and no carousel around it: the pieces the host owns are
    /// the pill destinations (Shortcuts, Settings, the App Store) and the way
    /// out, none of which a review of the demonstration needs.
    @MainActor
    private static var messagesLessonStages: [StageDescriptor] {
        [
            StageDescriptor(
                id: "onboarding.messages-lesson", screen: "Messages lesson",
                variant: "full demonstration",
                summary: "The save conversation from its first bubble through the "
                    + "Action Button ripple, the Dynamic Island shortcut run, and the "
                    + "real share surface resolving in the sheet.",
                kind: .shared,
                seed: { StageFixtures.seedEmpty() },
                make: {
                    let configuration = OnboardingSurfaceConfiguration.current
                    let messages = MessagesReplicaViewController(
                        urlString: configuration.practiceURLString)
                    let demo = OnboardingSaveDemoController(
                        link: OnboardingSaveDemoLink.resolve(
                            practiceURLString: configuration.practiceURLString,
                            app: configuration.demonstrationApp))
                    messages.saveDemoController = demo
                    // The real entry starts the work as the user taps in and the
                    // conversation as the card finishes expanding; here, both once
                    // the replica has been laid out at its full size.
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + OnboardingAnimationClock.delay(0.4)
                    ) { [weak messages] in
                        guard let messages else { return }
                        demo.start(in: messages)
                        messages.updateURL(demo.link.urlString)
                        messages.prepareForPresentation()
                        // The press is the answer to the link that just landed —
                        // the source's own count of how long its staged content
                        // takes, which is what the demo loop uses too.
                        DispatchQueue.main.asyncAfter(
                            deadline: .now() + OnboardingAnimationClock.delay(
                                messages.actionButtonReplayDelay)
                        ) { [weak messages] in
                            messages?.replaySaveDemonstration()
                        }
                    }
                    return messages
                }),
        ]
    }

    // MARK: - The Safari lesson

    /// The setup lesson's browser, playing its own demonstration — the one
    /// screen in onboarding that is a timed sequence rather than a state, and
    /// so the one that cannot be reviewed by seeding a store. Which
    /// demonstration runs is the app's own answer
    /// (`OnboardingSurfaceConfiguration.SafariLesson`): the buried `luna.app`
    /// page and its clearing wave in three of them, the blocked InstaTok post
    /// and the extension's video panel in the Downloader.
    @MainActor
    private static var safariLessonStages: [StageDescriptor] {
        [
            StageDescriptor(
                id: "onboarding.safari-lesson", screen: "Safari lesson",
                variant: "full demonstration",
                summary: "The mock browser from its first frame: this app's demonstration "
                    + "runs, and the lesson settles on the shared setup popup above it, "
                    + "looping underneath until it is answered.",
                kind: .shared,
                seed: { StageFixtures.seedEmpty() },
                make: {
                    let safari = SafariReplicaViewController()
                    // In production the popup (and its scrim) is
                    // `AppOnboardingViewController`'s own state, raised off
                    // this same signal — see that type's
                    // `showSafariSetupPopup()`. This stage reviews the bare
                    // replica with no such host, so it mounts an equivalent
                    // pair directly instead.
                    let popupRaiser = StageSafariSetupPopupRaiser()
                    safari.delegate = popupRaiser
                    SharedStageCatalog.stageRetained.append(popupRaiser)
                    // The real entry starts the sequence once the incoming card
                    // has finished expanding; here, once the browser has been
                    // laid out at its full size.
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + OnboardingAnimationClock.delay(0.4)
                    ) { [weak safari] in
                        safari?.beginDemonstration()
                    }
                    return safari
                }),
            StageDescriptor(
                id: "onboarding.safari-lesson-journey", screen: "Safari lesson",
                variant: "whole journey",
                summary: "The lesson as the util card enters it, host and all. In central "
                    + "Luna that is the three sibling lessons in rank order, and the "
                    + "shared setup popup that comes up once the first full cycle "
                    + "is done — the lessons keep replaying underneath it.",
                kind: .shared,
                seed: { StageFixtures.seedEmpty() },
                make: {
                    let onboarding = AppOnboardingViewController(
                        completion: AppOnboardingCompletion(
                            root: KindWiringOnboardingRoot()))
                    // Same cue as the stage above: the sequence starts once the
                    // screen has been laid out at its full size.
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + OnboardingAnimationClock.delay(0.4)
                    ) { [weak onboarding] in
                        onboarding?.startSafariLessonForStaging()
                    }
                    return onboarding
                }),
        ]
    }

    // MARK: - The deck

    /// Deck stages build NO view controller (`make` is nil) — they seed and
    /// then let the app construct its own root. That is deliberate: the deck is
    /// the screen most worth reviewing and the one most easily faked, and a
    /// hand-rolled stand-in would drift from the thing it is standing in for.
    @MainActor
    private static var deckStages: [StageDescriptor] {
        [
            StageDescriptor(
                id: "deck.first-run", screen: "Card deck", variant: "first run",
                summary: "Nothing saved and onboarding unanswered: the surface headline, "
                    + "the corona, and the setup block on the util card.",
                kind: .shared,
                seed: {
                    StageFixtures.seedEmpty()
                    StageFixtures.resetOnboarding()
                }),
            StageDescriptor(
                id: "deck.empty", screen: "Card deck", variant: "empty",
                summary: "Onboarding answered, nothing saved yet — the util card in its "
                    + "completed layout is the only card.",
                kind: .shared,
                seed: {
                    StageFixtures.seedEmpty()
                    StageFixtures.completeOnboarding()
                }),
            StageDescriptor(
                id: "deck.populated", screen: "Card deck", variant: "populated",
                summary: "One save of every kind this app shows; the newest is centred and "
                    + "the util card sits one page left.",
                kind: .shared,
                seed: {
                    StageFixtures.completeOnboarding()
                    seedEveryKind()
                }),
            StageDescriptor(
                id: "deck.failed-save", screen: "Card deck", variant: "failed save centred",
                summary: "A save that never resolved: the error card with its red rim, "
                    + "centred because it is the newest.",
                kind: .shared,
                seed: {
                    StageFixtures.completeOnboarding()
                    let failed = StageFixtures.contentlessArticle(
                        seed: "stage-failed", url: "https://example.com/broken",
                        title: nil, state: .failed, hoursAgo: 1)
                    SaveFailureStore.shared.recordMetadata(
                        failed.id, title: "A Page That Would Not Load",
                        siteName: "example.com")
                    let ready = StageFixtures.article(
                        seed: "stage-ready", url: "https://example.com/ready",
                        title: "A Ready Article To Read", daysAgo: 2)
                    StageFixtures.seed(
                        [failed, ready],
                        contents: [ready.id: StageFixtures.content("A Ready Article To Read")])
                }),
            StageDescriptor(
                id: "deck.save-of-the-week", screen: "Card deck", variant: "Save of the Week",
                summary: "The util card carrying a live weekly pick — the ribbon, the row, "
                    + "and its save affordance.",
                kind: .shared,
                seed: {
                    StageFixtures.seedEmpty()
                    StageFixtures.completeOnboarding()
                    for kind in WeeklySaveKind.kinds(for: .current) {
                        StageFixtures.seedWeeklySave(
                            kind: kind, title: weeklyTitle(for: kind),
                            host: "theatlantic.com", daysOld: 2)
                    }
                }),
        ]
    }

    /// One save per kind THIS app shows. A foreign kind is stored and simply
    /// never surfaces (`LunaApp.includes`), so seeding all of them and letting
    /// the app filter is both simpler and a live check of that filter.
    private static func seedEveryKind() {
        var items: [SavedItem] = []
        var contents: [UUID: ArticleContent] = [:]

        let ready = StageFixtures.article(
            seed: "stage-ready", url: "https://example.com/ready",
            title: "The Quiet Architecture of Everyday Things", hoursAgo: 2)
        contents[ready.id] = StageFixtures.content("The Quiet Architecture of Everyday Things")
        items.append(ready)

        let started = StageFixtures.article(
            seed: "stage-started", url: "https://example.com/opened",
            title: "An Article You Started", daysAgo: 1,
            readState: .opened, readingProgress: 0.35)
        contents[started.id] = StageFixtures.content("An Article You Started")
        items.append(started)

        items.append(StageFixtures.contentlessArticle(
            seed: "stage-locked", url: "https://wsj.com/locked-story",
            title: "A Hard-Paywalled Story", state: .needsCaptcha, daysAgo: 2))
        items.append(StageFixtures.platformPost(
            seed: "stage-video", url: "https://youtube.com/watch?v=stage",
            title: "A Saved Video", platform: .youtube, daysAgo: 3))
        items.append(StageFixtures.alertingTracker(
            seed: "stage-tracker", name: "Discounted Gadget",
            url: "https://store.example.com/gadget", from: 200, to: 150, daysAgo: 4))

        StageFixtures.seed(items, contents: contents)
    }

    private static func weeklyTitle(for kind: WeeklySaveKind) -> String {
        switch kind {
        case .article: return "What We Talk About When We Talk About Rivers"
        case .media: return "A Short Film About Rain"
        case .product: return "The Only Kettle Worth Owning"
        }
    }

    // MARK: - The util card, standalone

    /// The card on its own, in the deck's exact frame. Worth having beside the
    /// deck stages because the interesting util-card states are inputs the deck
    /// resolves from the device — Safari's recent-URL trail, whether an account
    /// is connected, how many saves are old enough to earn the email nudge —
    /// and every one of them is an argument to this initializer.
    @MainActor
    private static var utilCardStages: [StageDescriptor] {
        [
            StageDescriptor(
                id: "util.first-run", screen: "Util card", variant: "first run",
                summary: "Headline, corona and setup block, before either lesson is answered.",
                kind: .shared,
                seed: { StageFixtures.seedEmpty() },
                make: { utilCard(showsOnboarding: true, recents: [], saveDates: []) }),
            StageDescriptor(
                id: "util.completed", screen: "Util card", variant: "completed",
                summary: "After both lessons: the paste row plus matching Safari-history "
                    + "URLs where the setup controls were.",
                kind: .shared,
                seed: { StageFixtures.seedEmpty() },
                make: {
                    utilCard(
                        showsOnboarding: false, recents: recentPreviews(),
                        saveDates: [StageFixtures.ago(days: 1)])
                }),
            StageDescriptor(
                id: "util.email-nudge", screen: "Util card", variant: "email nudge earned",
                summary: "Three saves old enough to earn the email offer, with no account "
                    + "connected — the third setup slot in use.",
                kind: .email,
                seed: { StageFixtures.seedEmpty() },
                make: {
                    utilCard(
                        showsOnboarding: true, recents: [],
                        saveDates: [
                            StageFixtures.ago(days: 3), StageFixtures.ago(days: 2),
                            StageFixtures.ago(days: 1),
                        ],
                        emailConnected: false)
                }),
            StageDescriptor(
                id: "util.save-of-the-week", screen: "Util card", variant: "weekly pick",
                summary: "A pick two days old: the week-tier label and the ribbon.",
                kind: .shared,
                seed: { StageFixtures.seedEmpty() },
                make: { utilCard(showsOnboarding: false, recents: [], weeklyDaysOld: 2) }),
            StageDescriptor(
                id: "util.save-of-the-month", screen: "Util card", variant: "month-tier pick",
                summary: "The same row past the nine-day mark, where the label flips from "
                    + "week to month.",
                kind: .shared,
                seed: { StageFixtures.seedEmpty() },
                make: { utilCard(showsOnboarding: false, recents: [], weeklyDaysOld: 14) }),
        ]
    }

    /// Not private: the media catalog builds the same card with a storage choice
    /// installed, which only its own targets can offer
    /// (`claudedocs/util-card.md`, "Where downloads are stored").
    @MainActor
    static func utilCard(
        showsOnboarding: Bool,
        recents: [RecentURLPreview],
        saveDates: [Date] = [],
        emailConnected: Bool = true,
        weeklyDaysOld: Int? = nil,
        storageChoice: (any DownloadStorageChoosing)? = nil
    ) -> UIViewController {
        let onboarding = AppOnboardingStore(
            app: .current, defaults: scratchDefaults("utilCard"),
            saveSetupMode: .actionButtonShortcut,
            newestSave: StagedNewestSave(date: saveDates.max()))
        if !showsOnboarding { onboarding.markCompleted() }

        let weekly = WeeklySaveStore(
            containerURL: scratchDirectory("weekly"), now: { StageFixtures.now })
        if let weeklyDaysOld {
            for kind in WeeklySaveKind.kinds(for: .current) {
                weekly.setDisplay(
                    WeeklySaveDisplay(
                        save: WeeklySave(
                            kind: kind, urlString: "https://theatlantic.com/pick",
                            date: StageFixtures.now.addingTimeInterval(-Double(weeklyDaysOld) * 86_400),
                            signature: Data()),
                        title: weeklyTitle(for: kind), subtitleHost: "theatlantic.com"),
                    for: kind)
            }
        }

        let card = UtilCardContentViewController(
            showsOnboarding: showsOnboarding,
            configuration: .configuration(for: .current, saveSetupMode: .actionButtonShortcut),
            onboardingStore: onboarding,
            weeklyStore: weekly,
            now: { StageFixtures.now },
            storageChoice: storageChoice)
        let environment = StageUtilCardEnvironment(
            hasSaves: !saveDates.isEmpty, savedDates: saveDates,
            isEmailConnected: emailConnected, recentMatches: recents)
        card.dataSource = environment
        card.delegate = environment
        return StageCardHostViewController(card: card, retaining: environment)
    }

    private static func recentPreviews() -> [RecentURLPreview] {
        [
            RecentURLPreview(
                urlString: "https://theatlantic.com/the-quiet-architecture-of-everyday-things",
                title: "The Quiet Architecture of Everyday Things",
                subtitle: "theatlantic.com", kind: .article, imageData: nil),
            RecentURLPreview(
                urlString: "https://youtube.com/watch?v=stage",
                title: "A Short Film About Rain", subtitle: "youtube.com",
                kind: .media, imageData: nil),
        ]
    }

    // MARK: - Cards that are not the deck's

    @MainActor
    private static var cardStages: [StageDescriptor] {
        [
            StageDescriptor(
                id: "card.failed-save.error", screen: "Failed save card", variant: "error",
                summary: "The default failed save: the page in a web view, its URL, and the "
                    + "retry-with-AI affordance.",
                kind: .shared,
                make: { failedSaveCard() }),
            StageDescriptor(
                id: "card.failed-save.rescuing", screen: "Failed save card",
                variant: "rescue in progress",
                summary: "A rescue running: the page dimmed under a progress bar. Frozen "
                    + "mid-run — the card polls its state provider and this one never moves.",
                kind: .shared,
                make: { failedSaveCard(.running(progress: 0.45)) }),
            StageDescriptor(
                id: "card.failed-save.no-rescue", screen: "Failed save card",
                variant: "no rescue offered",
                summary: "A failure not worth an LLM pass (or no engine available): the "
                    + "button is absent rather than disabled.",
                kind: .shared,
                make: { failedSaveCard(.unavailable) }),
            StageDescriptor(
                id: "card.failed-save.terminal", screen: "Failed save card",
                variant: "attempt spent",
                summary: "The rescue was already spent under this app version: an apology "
                    + "and Delete, until an update makes it eligible again.",
                kind: .shared,
                make: { failedSaveCard(.spent) }),
            StageDescriptor(
                id: "card.unsupported-save", screen: "Unsupported save card",
                variant: "another app's kind",
                summary: "What a single-content app shows when a foreign kind arrives — the "
                    + "same card from every surface.",
                kind: .shared,
                make: {
                    let owner: LunaApp = LunaApp.current == .downloader ? .reader : .downloader
                    // No delegate: on a staged card Done is inert, exactly as
                    // the empty closure it replaces was.
                    return UnsupportedSaveCardViewController(owner: owner)
                }),
            StageDescriptor(
                id: "card.rescue-failure", screen: "Extension failure card",
                variant: "save failed",
                summary: "The share/action extension's failure card, hosted in-app because a "
                    + "simulator cannot drive the real share sheet.",
                kind: .shared,
                make: {
                    guard let url = URL(string: "https://example.com/broken") else { return nil }
                    return UINavigationController(
                        rootViewController: RescueFailureViewController(
                            // No delegate: a staged card records nothing, opens
                            // nothing and completes nothing, exactly as the three
                            // empty closures it replaces did.
                            url: url, rescueURL: URL(string: "luna://rescue"),
                            delegate: nil))
                }),
        ]
    }

    @MainActor
    private static func failedSaveCard(
        _ rescueState: FailedSaveCardModel.RescueState = .idle
    ) -> UIViewController {
        let itemID = SavedItem.deterministicUUID(from: "stage-failed")
        let model = FailedSaveCardModel(
            itemID: itemID, url: URL(string: "https://example.com/broken"),
            urlText: "example.com/broken", rescueState: rescueState)
        let card = FailedSaveCardViewController(
            model: model,
            actions: FailedSaveCardActions(rescue: {}, share: { _ in }, delete: {}),
            // A constant provider is what freezes the state: the card re-reads
            // this on a timer, and a live one would resolve the rescue away.
            stateProvider: { model })
        return StageCardHostViewController(card: card)
    }

    // MARK: - Settings

    @MainActor
    private static var settingsStages: [StageDescriptor] {
        [
            StageDescriptor(
                id: "settings.root", screen: "Settings", variant: "root",
                summary: "The app's own settings list — the categories differ per app.",
                kind: .shared,
                make: { UINavigationController(rootViewController: SettingsViewController()) }),
            StageDescriptor(
                id: "settings.appearance", screen: "Settings → Appearance", variant: "default",
                summary: "Night vs predawn. Both are night; predawn is the same sky lifted "
                    + "one notch (`claudedocs/visual-effects.md`).",
                kind: .shared,
                make: {
                    UINavigationController(rootViewController: AppearanceSettingsScreen())
                }),
            StageDescriptor(
                id: "settings.shortcut", screen: "Settings → Shortcut & Safari",
                variant: "shortcut available",
                summary: "The full screen, forced into the Action-Button-capable layout a "
                    + "simulator would otherwise hide.",
                kind: .shared,
                make: {
                    UINavigationController(
                        rootViewController: ShortcutSettingsScreen(showsShortcutSetup: true))
                }),
            StageDescriptor(
                id: "settings.safari-only", screen: "Settings → Safari",
                variant: "no Action Button",
                summary: "The same screen on hardware that cannot run the shortcut: renamed, "
                    + "with the shortcut, On-Screen URLs and Double Save sections gone.",
                kind: .shared,
                make: {
                    UINavigationController(
                        rootViewController: ShortcutSettingsScreen(showsShortcutSetup: false))
                }),
            StageDescriptor(
                id: "settings.import-export", screen: "Settings → Import & Export",
                variant: "populated",
                summary: "Export counts read from the seeded store.",
                kind: .shared,
                seed: { seedEveryKind() },
                make: {
                    UINavigationController(rootViewController: ImportExportSettingsScreen())
                }),
            StageDescriptor(
                id: "settings.import-review", screen: "Import review sheet", variant: "both sections",
                summary: "The sheet a picked link-list file produces. Staged with a fixture "
                    + "document — a simulator has no document picker result to hand it.",
                kind: .shared,
                make: {
                    let host = UINavigationController(rootViewController: ImportExportSettingsScreen())
                    return PresentingHostViewController(host: host) {
                        LinkImportSheetViewController(document: LinkListDocument(
                            links: [
                                "https://example.com/the-quiet-architecture-of-everyday-things",
                                "https://example.com/notes-on-a-long-winter",
                                "https://example.org/why-maps-lie",
                            ],
                            archived: ["https://example.com/an-older-piece-worth-keeping"],
                            isStructured: true))
                    }
                }),
            StageDescriptor(
                id: "settings.diagnostics", screen: "Diagnostics", variant: "default",
                summary: "The five-tap screen. Reachable by argument here because five taps "
                    + "in blank space is not a thing a capture script should be doing.",
                kind: .shared,
                make: {
                    UINavigationController(rootViewController: DiagnosticsViewController())
                }),
        ]
    }

    // MARK: - Scratch stores

    /// A defaults suite nothing else uses. The staged container already
    /// redirects the App Group; this covers the stores that deliberately use
    /// STANDARD defaults instead — `AppOnboardingStore`, because each host owns
    /// its own onboarding.
    private static func scratchDefaults(_ name: String) -> UserDefaults {
        let suite = "LunaStage.\(name).\(ProcessInfo.processInfo.processIdentifier)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private static func scratchDirectory(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LunaStage-\(name)", isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// A staged Safari lesson has no onboarding host, so this stands in for the one
/// thing that host does at the lesson's end: raising the shared setup popup, and
/// its scrim, over the replica.
@MainActor
final class StageSafariSetupPopupRaiser: SafariReplicaDelegate {
    func safariReplicaDidReachSetupOffer(_ replica: SafariReplicaViewController) {
        let host: UIView = replica.view.window ?? replica.view
        let scrim = SafariSetupScrimView(frame: host.bounds)
        scrim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrim.backgroundColor = UIColor.black.withAlphaComponent(
            OnboardingSafariSetupPopupView.scrimAlpha)
        scrim.isUserInteractionEnabled = false
        host.addSubview(scrim)
        let popup = OnboardingSafariSetupPopupView(frame: host.bounds)
        popup.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(popup)
        popup.layoutIfNeeded()
        popup.present(fadingInAlongside: scrim)
    }
}

/// The staged util card's environment: fixed values in place of the shared
/// stores, and a save that always reports success.
@MainActor
final class StageUtilCardEnvironment: UtilCardDataSource, UtilCardDelegate {
    let utilCardHasSaves: Bool
    let utilCardSavedURLStrings: Set<String> = []
    let utilCardSavedDates: [Date]
    let utilCardIsEmailConnected: Bool
    let utilCardRecentMatches: [RecentURLPreview]

    init(
        hasSaves: Bool, savedDates: [Date], isEmailConnected: Bool,
        recentMatches: [RecentURLPreview]
    ) {
        utilCardHasSaves = hasSaves
        utilCardSavedDates = savedDates
        utilCardIsEmailConnected = isEmailConnected
        utilCardRecentMatches = recentMatches
    }

    func utilCardSave(
        urlString: String, source: CaptureSource, sourceView: UIView,
        completion: @escaping (Bool) -> Void
    ) {
        completion(true)
    }

    func utilCardOpenSystemSettings() {}
}

/// Hosts one card in the deck's exact frame — `CardDeckGeometry.cardFrame` is
/// pure arithmetic over the screen, so a staged card lands where the deck would
/// have put it, in the same surface chrome (`claudedocs/card-carousel.md`).
final class StageCardHostViewController: UIViewController {
    private let card: UIViewController
    private let surface = CardSurfaceView()
    /// A staged card's environment, which the card itself only holds weakly.
    private let retained: AnyObject?

    init(card: UIViewController, retaining retained: AnyObject? = nil) {
        self.card = card
        self.retained = retained
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background
        view.addSubview(surface)
        addChild(card)
        card.view.frame = surface.contentContainer.bounds
        card.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        surface.contentContainer.addSubview(card.view)
        card.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        surface.frame = CardDeckGeometry.cardFrame(
            inScreenSize: view.bounds.size, safeAreaInsets: view.safeAreaInsets)
        card.view.frame = surface.contentContainer.bounds
    }
}

/// A staged deck's newest save: one fixture date, or none for an empty deck.
private struct StagedNewestSave: OnboardingNewestSaveProviding {
    let date: Date?

    func newestSaveDate(excluding excludedID: UUID?) -> Date? { date }
}

#endif

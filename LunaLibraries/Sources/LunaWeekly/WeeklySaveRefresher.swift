//
//  WeeklySaveRefresher.swift
//  LunaWeekly
//

import Foundation
import LunaModels
import UserNotifications

/// What a fetched entry needs before it can be drawn: a title, a host, and an
/// already-downscaled thumbnail. Installed by the app shell (which owns the
/// ingest pipeline this module cannot see).
public typealias WeeklyMetadataFetcher =
    @Sendable (String) async -> (title: String, host: String, imageData: Data?)?

/// The launch/foreground orchestration: fetch this app's kinds, verify the
/// signatures, drop what has aged out, and update the local store — resolving
/// display metadata BEFORE the write, so the util card only ever animates in a
/// fully-formed row.
@MainActor
public final class WeeklySaveRefresher {
    public static let shared = WeeklySaveRefresher()

    /// Installed once at launch by the app shell. Without it a newly-arrived
    /// entry falls back to the URL's host for both title and subtitle rather
    /// than being dropped.
    public static var metadataFetcher: WeeklyMetadataFetcher?

    private let database: WeeklyCloudDatabase
    private let store: WeeklySaveStore
    private let now: () -> Date
    private let app: LunaApp
    /// Seams so the whole path is testable without the curator's private key
    /// (which lives outside this repository), a Keychain item, or a real
    /// notification centre.
    private let verify: (WeeklySave) -> Bool
    private let isKeyHolder: () -> Bool
    private let notifyProposals: (Int, String?) -> Void
    /// Foreground spam guard: at most one refresh a minute, one in flight.
    private var isRefreshing = false
    private var lastRefresh: Date?
    private var isCheckingProposals = false

    public init(
        database: WeeklyCloudDatabase = CKWeeklyCloudDatabase.shared,
        store: WeeklySaveStore = .shared,
        app: LunaApp = .current,
        now: @escaping () -> Date = Date.init,
        verify: @escaping (WeeklySave) -> Bool = WeeklySigning.verify,
        isKeyHolder: @escaping () -> Bool = { WeeklyPromotionKeyStore.isKeyHolder },
        notifyProposals: @escaping (Int, String?) -> Void = WeeklyProposalNotifier.post
    ) {
        self.database = database
        self.store = store
        self.app = app
        self.now = now
        self.verify = verify
        self.isKeyHolder = isKeyHolder
        self.notifyProposals = notifyProposals
    }

    /// The kinds this app is allowed to show — the only ones it ever asks for.
    public var kinds: [WeeklySaveKind] { WeeklySaveKind.kinds(for: app) }

    // MARK: - Weekly saves

    public func refreshWeeklySaves(force: Bool = false) async {
        guard !isRefreshing else { return }
        if !force, let lastRefresh, now().timeIntervalSince(lastRefresh) < 60 { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let fetched: [WeeklySave]
        do {
            fetched = try await database.fetchWeeklySaves(for: kinds)
        } catch {
            // No container, no network, no account: the row keeps whatever it
            // last knew rather than blinking out.
            weeklyCloudLog("weekly fetch failed: \(error.localizedDescription)")
            return
        }
        lastRefresh = now()

        let live = Dictionary(
            fetched
                .filter { verify($0) && !$0.isExpired(now: now()) }
                .map { ($0.kind, $0) },
            uniquingKeysWith: { first, _ in first })

        // Metadata resolves per kind CONCURRENTLY, each writing its display
        // the moment it lands: the card's row is a launch surface, and one
        // slow page must not hold the others' rows hostage.
        await withTaskGroup(of: Void.self) { group in
            for kind in kinds {
                guard let save = live[kind] else {
                    store.clear(kind: kind)
                    continue
                }
                let existing = store.display(for: kind)?.save
                if existing?.urlString == save.urlString, existing?.date == save.date {
                    continue
                }
                let store = store
                group.addTask { @MainActor in
                    let metadata = await Self.metadataFetcher?(save.urlString)
                    let host = metadata?.host
                        ?? URL(string: save.urlString)?.host
                        ?? save.urlString
                    store.setDisplay(
                        WeeklySaveDisplay(
                            save: save,
                            title: metadata?.title ?? host,
                            subtitleHost: host,
                            imageData: metadata?.imageData),
                        for: kind)
                }
            }
        }
    }

    // MARK: - Promotion (key-holder)

    /// Signs, writes, and mirrors locally so a self-promotion is visible
    /// immediately instead of waiting for the next fetch. Throws whatever
    /// CloudKit threw so the caller can show it.
    public func promote(kind: WeeklySaveKind, urlString: String) async throws {
        guard let key = WeeklyPromotionKeyStore.storedPrivateKey() else {
            throw WeeklyPromotionError.notKeyHolder
        }
        let save = try WeeklySigning.sign(
            kind: kind, urlString: urlString, date: now(), privateKey: key)
        try await database.saveWeekly(save)
        weeklyCloudLog("promoted \(kind.rawValue): \(urlString)")
        guard kinds.contains(kind) else { return }
        let metadata = await Self.metadataFetcher?(urlString)
        let host = metadata?.host ?? URL(string: urlString)?.host ?? urlString
        store.setDisplay(
            WeeklySaveDisplay(
                save: save,
                title: metadata?.title ?? host,
                subtitleHost: host,
                imageData: metadata?.imageData),
            for: kind)
    }

    // MARK: - Proposals

    public func createProposal(kind: WeeklySaveKind, urlString: String) async throws {
        let proposal = WeeklyProposal(kind: kind, urlString: urlString, date: now())
        try await database.createProposal(proposal)
        // A key-holder may propose too, and the inbox check would otherwise
        // notify them about their own submission.
        store.markProposalSeen(proposal.recordName)
        weeklyCloudLog("proposed \(kind.rawValue): \(proposal.urlString)")
    }

    public func fetchProposals() async throws -> [WeeklyProposal] {
        try await database.fetchProposals()
    }

    public func deleteProposal(recordName: String) async throws {
        try await database.deleteProposal(recordName: recordName)
    }

    public func isSignedIntoICloud() async -> Bool {
        (try? await database.accountStatus()) ?? false
    }

    /// Opportunistic inbox poll. No-op unless this device holds the key; new
    /// record names (against the store's seen set) produce ONE local
    /// notification per batch.
    @discardableResult
    public func checkProposalsIfKeyHolder() async -> Int {
        guard isKeyHolder(), !isCheckingProposals else { return 0 }
        isCheckingProposals = true
        defer { isCheckingProposals = false }

        let proposals: [WeeklyProposal]
        do {
            proposals = try await database.fetchProposals()
        } catch {
            weeklyCloudLog("proposal fetch failed: \(error.localizedDescription)")
            return 0
        }
        let names = Set(proposals.map(\.recordName))
        let unseen = names.subtracting(store.seenProposalIDs())
        store.markProposalsSeen(names)
        guard !unseen.isEmpty else { return 0 }
        let newest = proposals.first { unseen.contains($0.recordName) }
        notifyProposals(unseen.count, newest.flatMap { URL(string: $0.urlString)?.host })
        weeklyCloudLog("\(unseen.count) new proposal(s)")
        return unseen.count
    }
}

public enum WeeklyPromotionError: LocalizedError {
    case notKeyHolder

    public var errorDescription: String? {
        switch self {
        case .notKeyHolder:
            return L10n.string("SaveOfWeek_refresher_notKeyHolderError")
        }
    }
}

/// The key-holder's "someone proposed something" banner.
public enum WeeklyProposalNotifier {
    public static let typeValue = "weeklyProposal"

    public static func post(count: Int, host: String?) {
        let content = UNMutableNotificationContent()
        if count == 1 {
            content.title = L10n.string("SaveOfWeek_refresher_proposalNotification_singularHeadline")
            content.body = host ?? L10n.string("SaveOfWeek_refresher_proposalNotification_singularMessage")
        } else {
            content.title = L10n.string("SaveOfWeek_refresher_proposalNotification_pluralHeadline", count)
            content.body = L10n.string("SaveOfWeek_refresher_proposalNotification_pluralMessage")
        }
        content.sound = .default
        // The literal key is `NotificationManager.typeKey`; LunaWeekly sits
        // below LunaSocial and can't import it, and the string is already part
        // of the app's notification contract.
        content.userInfo = ["lunaNotificationType": typeValue]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "weeklyProposal-" + UUID().uuidString,
                content: content, trigger: nil))
    }
}

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
public protocol WeeklyMetadataFetching: Sendable {
    func fetchMetadata(
        forURLString urlString: String
    ) async -> (title: String, host: String, imageData: Data?)?
}

/// Whether a fetched entry really was signed by the curator. The shipped
/// verifier checks the bundled public key; a test hands in the public half of
/// whichever pair it minted.
public protocol WeeklySignatureVerifying {
    func isSignatureValid(_ save: WeeklySave) -> Bool
}

/// The shipped verifier: the bundled curator public key.
public struct WeeklyBundledKeyVerifier: WeeklySignatureVerifying {
    public init() {}

    public func isSignatureValid(_ save: WeeklySave) -> Bool {
        WeeklySigning.verify(save)
    }
}

/// Whether this device holds the curator's private key, and so may promote and
/// read the proposal inbox.
public protocol WeeklyKeyHolding {
    var isKeyHolder: Bool { get }
}

/// The shipped answer: a private key in this install's keychain.
public struct WeeklyKeychainKeyHolder: WeeklyKeyHolding {
    public init() {}

    public var isKeyHolder: Bool { WeeklyPromotionKeyStore.isKeyHolder }
}

/// The key-holder's "someone proposed something" banner, so the inbox check can
/// be exercised without a real notification centre.
public protocol WeeklyProposalNotifying {
    func notifyProposals(count: Int, host: String?)
}

/// The shipped notifier: one local notification per batch.
public struct WeeklyLocalProposalNotifier: WeeklyProposalNotifying {
    public init() {}

    public func notifyProposals(count: Int, host: String?) {
        WeeklyProposalNotifier.post(count: count, host: host)
    }
}

/// The launch/foreground orchestration: fetch this app's kinds, verify the
/// signatures, and update the local store — resolving
/// display metadata BEFORE the write, so the util card only ever animates in a
/// fully-formed row.
@MainActor
public final class WeeklySaveRefresher {
    public static let shared = WeeklySaveRefresher()

    /// Installed once at launch by the app shell. Without it a newly-arrived
    /// entry falls back to the URL's host for both title and subtitle rather
    /// than being dropped.
    public static var metadataFetcher: (any WeeklyMetadataFetching)?

    private let database: WeeklyCloudDatabase
    private let store: WeeklySaveStore
    private let now: () -> Date
    private let app: LunaApp
    /// Seams so the whole path is testable without the curator's private key
    /// (which lives outside this repository), a Keychain item, or a real
    /// notification centre.
    private let verifier: any WeeklySignatureVerifying
    private let keyHolder: any WeeklyKeyHolding
    private let proposalNotifier: any WeeklyProposalNotifying
    /// Foreground spam guard: at most one refresh a minute, one in flight.
    private var isRefreshing = false
    private var lastRefresh: Date?
    private var isCheckingProposals = false

    public init(
        database: WeeklyCloudDatabase = CKWeeklyCloudDatabase.shared,
        store: WeeklySaveStore = .shared,
        app: LunaApp = .current,
        now: @escaping () -> Date = Date.init,
        verifier: any WeeklySignatureVerifying = WeeklyBundledKeyVerifier(),
        keyHolder: any WeeklyKeyHolding = WeeklyKeychainKeyHolder(),
        proposalNotifier: any WeeklyProposalNotifying = WeeklyLocalProposalNotifier()
    ) {
        self.database = database
        self.store = store
        self.app = app
        self.now = now
        self.verifier = verifier
        self.keyHolder = keyHolder
        self.proposalNotifier = proposalNotifier
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
                .filter { verifier.isSignatureValid($0) }
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
                // An entry we already hold is skipped — UNLESS its metadata
                // never resolved. A row showing the bare host is not a row we
                // are finished with, and this is the only place that would ever
                // ask again.
                let existing = store.display(for: kind)
                if existing?.save.urlString == save.urlString,
                   existing?.save.date == save.date,
                   existing?.hasResolvedMetadata == true {
                    continue
                }
                let store = store
                group.addTask { @MainActor in
                    store.setDisplay(
                        await Self.display(for: save), for: kind)
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
        store.setDisplay(await Self.display(for: save), for: kind)
    }

    /// The one place a `WeeklySaveDisplay` is built from a signed entry — the
    /// launch/foreground refresh and a self-promotion both land here, so a
    /// failed metadata read is recorded as unresolved (and retried) whichever
    /// one wrote it.
    private static func display(for save: WeeklySave) async -> WeeklySaveDisplay {
        let metadata = await metadataFetcher?.fetchMetadata(forURLString: save.urlString)
        let host = metadata?.host ?? URL(string: save.urlString)?.host ?? save.urlString
        return WeeklySaveDisplay(
            save: save,
            title: metadata?.title ?? host,
            subtitleHost: host,
            imageData: metadata?.imageData,
            hasResolvedMetadata: metadata != nil)
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
        guard keyHolder.isKeyHolder, !isCheckingProposals else { return 0 }
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
        proposalNotifier.notifyProposals(
            count: unseen.count, host: newest.flatMap { URL(string: $0.urlString)?.host })
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

//
//  RecoveryFileApplier.swift
//  LunaSaves
//

import Foundation
import LunaIngest
import LunaModels
import LunaStorage
import LunaURLClassification

/// Replays a recovery file's recipe through Luna's own pipeline.
///
/// The replay needs the rescue engine's validator, its directive applier and
/// its learned-rule store, all of which live in `LunaURLRescue` — a module the
/// extensions must never link. So it is a witness: the app installs
/// `RecoveryRecipeReplay` (`Luna/URLRescueWiring.swift`), every other process
/// keeps `NoRecipeReplay`, and this module stays where it is in the graph.
public protocol RecoveryRecipeReplaying: AnyObject {
    /// False where no rescue engine is linked. The applier then keeps the
    /// recipe for the app instead of dropping it.
    var canReplay: Bool { get }

    /// Validates and replays `recipe`, persisting the result against `itemID`.
    /// True means the save is now ready and a host rule was learned.
    func replay(_ recipe: LunaRecoveryRecipe, pageURL: URL, itemID: UUID) async -> Bool
}

/// The default: no engine here, so nothing is replayed.
public final class NoRecipeReplay: RecoveryRecipeReplaying {
    public init() {}
    public var canReplay: Bool { false }
    public func replay(
        _ recipe: LunaRecoveryRecipe, pageURL: URL, itemID: UUID
    ) async -> Bool { false }
}

/// Turns a recovery Luna file into a finished save (`claudedocs/luna-file.md`).
///
/// A file carries two ways in, and they are tried in that order. The RECIPE is
/// a route Luna can take itself — replay it and the site's next failure can be
/// replayed the same way, without a model at all. The CONTENT is the one answer
/// the model already produced: it is adopted through exactly the chain a plugin
/// Model takes (`PluginModelAdopters` → `PluginOutcomeMapping` →
/// `SavesIngestor.applyRescued`), so a recovered save is written, presented and
/// surfaced like any other.
@MainActor
public final class RecoveryFileApplier {
    public static let shared = RecoveryFileApplier()

    /// How this app replays a recipe, if it can.
    public static var recipeReplay: any RecoveryRecipeReplaying = NoRecipeReplay()

    /// What happened to the file.
    public enum Result: Equatable {
        /// The save is ready; the deck should land on it.
        case recovered(itemID: UUID)
        /// This app does not show that kind, so nothing was stored.
        case dropped(owner: LunaApp)
        /// One line for the card.
        case failed(reason: String)
    }

    private let store: SavesStore
    private let ingestor: SavesIngestor
    private let handoffs: LLMHandoffStore
    private let pendingRecipes: PendingRecoveryRecipeStore
    private let now: () -> Date

    /// The apply in flight, and how far along it is. Process-local: the card
    /// reading it is in this process, and an apply never outlives it.
    private var progressByItemID: [UUID: Double] = [:]
    /// The last refusal per page, so the card can say why instead of silently
    /// going back to the offer.
    private var failureByURLString: [String: String] = [:]

    public init(
        store: SavesStore = .shared,
        ingestor: SavesIngestor = .shared,
        handoffs: LLMHandoffStore = .shared,
        pendingRecipes: PendingRecoveryRecipeStore = .shared,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.ingestor = ingestor
        self.handoffs = handoffs
        self.pendingRecipes = pendingRecipes
        self.now = now
    }

    // MARK: - What the card reads

    public func isApplying(_ itemID: UUID) -> Bool { progressByItemID[itemID] != nil }

    /// 0…1 while a file is being applied for this item, else nil.
    public func applyProgress(_ itemID: UUID) -> Double? { progressByItemID[itemID] }

    /// Why the last file for this page was refused, or nil.
    public func lastFailure(forURL urlString: String) -> String? {
        failureByURLString[urlString]
    }

    // MARK: - Apply

    public func apply(_ file: LunaRecoveryFile) async -> Result {
        let pageURLString = file.url.absoluteString
        failureByURLString[pageURLString] = nil

        // The ordinary surface gate: a Reader handed a product file stores
        // nothing and says whose kind it is.
        if case .unsupported(let owner) = SurfaceSupport.evaluateForCurrentProcess(
            owner: file.kind.owningApp) {
            SharedDiagnosticLog.record(
                "recovery file dropped: \(file.kind.rawValue) belongs to "
                    + owner.storageIdentifier, category: "rescue")
            return .dropped(owner: owner)
        }

        let itemID = existingItemID(for: file.url)
            ?? store.reserveSaveAttempt(urlString: pageURLString, at: now()).item.id
        report(itemID, progress: 0.15)
        defer { finish(itemID) }

        if let recipe = file.recipe {
            if Self.recipeReplay.canReplay {
                report(itemID, progress: 0.35)
                if await Self.recipeReplay.replay(recipe, pageURL: file.url, itemID: itemID) {
                    SharedDiagnosticLog.record(
                        "recovery file: recipe replayed host=\(file.url.host ?? "?")",
                        category: "rescue")
                    return succeed(itemID: itemID, pageURLString: pageURLString)
                }
            } else {
                // No engine in this process. The save is about to be recovered
                // from the content anyway; the recipe is kept so the app can
                // learn a host rule from it on its next foreground.
                pendingRecipes.append(PendingRecoveryRecipe(
                    pageURL: file.url, recipe: recipe, dateWritten: now()))
            }
        }

        report(itemID, progress: 0.6)
        guard let outcome = await RecoveryContentAdoption.outcome(for: file) else {
            let reason = L10n.string("LunaFile_recoveryNotAdoptedMessage")
            failureByURLString[pageURLString] = reason
            SharedDiagnosticLog.record(
                "recovery file: content not adopted for \(pageURLString)", category: "rescue")
            return .failed(reason: reason)
        }

        report(itemID, progress: 0.85)
        let applied = await ingestor.applyRescued(
            IngestResult(url: file.url, outcome: outcome), forItemID: itemID, interactive: false)
        guard applied else {
            let reason = L10n.string("LunaFile_recoveryNotSavedMessage")
            failureByURLString[pageURLString] = reason
            return .failed(reason: reason)
        }
        return succeed(itemID: itemID, pageURLString: pageURLString)
    }

    // MARK: - Private

    private func succeed(itemID: UUID, pageURLString: String) -> Result {
        if let record = handoffs.record(forURL: pageURLString) {
            handoffs.clear(id: record.id)
        }
        NotificationCenter.default.post(name: .savesChanged, object: nil)
        return .recovered(itemID: itemID)
    }

    /// The failed save this file is about, when Luna already has one. A save
    /// that is ready is left alone — a recovery file is not an edit.
    private func existingItemID(for url: URL) -> UUID? {
        let target = Self.matchKey(url)
        return store.items().first { item in
            guard item.state == .failed || item.state == .needsCaptcha else { return false }
            guard let itemURL = item.url else { return item.urlString == url.absoluteString }
            return Self.matchKey(itemURL) == target
        }?.id
    }

    /// Host and path, normalized. The model may answer with the canonical form
    /// of the URL the user saved — a trailing slash, a different case — and
    /// that is the same page, not a second save.
    static func matchKey(_ url: URL) -> String {
        HostMatching.normalizedHost(url.host ?? "") + HostMatching.normalizedPath(url.path)
    }

    private func report(_ itemID: UUID, progress: Double) {
        progressByItemID[itemID] = progress
        NotificationCenter.default.post(
            name: .rescueProgressChanged, object: nil,
            userInfo: [RescueProgressKey.itemID: itemID])
    }

    private func finish(_ itemID: UUID) {
        progressByItemID[itemID] = nil
        NotificationCenter.default.post(
            name: .rescueProgressChanged, object: nil,
            userInfo: [RescueProgressKey.itemID: itemID])
    }
}

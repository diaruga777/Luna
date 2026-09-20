//
//  PendingRecoveryRecipeStore.swift
//  LunaStorage
//

import Foundation
import LunaAppConfig
import LunaModels

/// A recipe an extension could not replay, kept for the app to learn from.
///
/// The share and action extensions adopt a recovery file's content themselves,
/// but they link no rescue engine, so the file's replayable recipe would be
/// lost there. This row is that recipe, flattened to fields a sidecar can
/// carry, plus the page it recovers.
public struct PendingRecoveryRecipe: Codable, Equatable, Sendable {
    public let pageURLString: String
    public let recipeURLString: String
    public let headers: [String: String]
    public let javascript: String?
    public let returns: String
    public let dateWritten: Date

    public init(
        pageURLString: String, recipeURLString: String, headers: [String: String],
        javascript: String?, returns: String, dateWritten: Date
    ) {
        self.pageURLString = pageURLString
        self.recipeURLString = recipeURLString
        self.headers = headers
        self.javascript = javascript
        self.returns = returns
        self.dateWritten = dateWritten
    }

    public init(pageURL: URL, recipe: LunaRecoveryRecipe, dateWritten: Date) {
        self.init(
            pageURLString: pageURL.absoluteString,
            recipeURLString: recipe.url.absoluteString,
            headers: recipe.headers, javascript: recipe.javascript,
            returns: recipe.returns.rawValue, dateWritten: dateWritten)
    }

    /// The recipe again, or nil when the row no longer parses as one.
    public var recipe: LunaRecoveryRecipe? {
        guard let url = URL(string: recipeURLString) else { return nil }
        return LunaRecoveryRecipe(
            url: url, headers: headers, javascript: javascript,
            returns: LunaRecoveryRecipe.Returns(rawValue: returns) ?? .html)
    }

    public var pageURL: URL? { URL(string: pageURLString) }
}

/// The recipes waiting for the app, in `pendingRecipes.json`.
///
/// The app drains this on foreground and replays each recipe for ONE reason:
/// to learn a host rule the next failure on that site can replay. The save the
/// recipe came with is already recovered, and is never touched again.
public final class PendingRecoveryRecipeStore {
    public static let shared = PendingRecoveryRecipeStore()

    /// A recipe the app never came back for is stale evidence about a site.
    public static let lifetime: TimeInterval = 24 * 60 * 60

    private let now: () -> Date
    /// Keyed by the page URL, so a second file for the same page replaces the
    /// first rather than teaching the same lesson twice.
    private let file: CoordinatedJSONFile<[String: PendingRecoveryRecipe]>

    public init(containerURL: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.now = now
        let base = containerURL ?? AppConfig.sharedContainerURL()
        self.file = CoordinatedJSONFile(
            url: base?.appendingPathComponent("pendingRecipes.json"),
            encoder: .sidecarISO8601, decoder: .sidecarISO8601, empty: { [:] })
    }

    public func append(_ recipe: PendingRecoveryRecipe) {
        file.mutate { rows in
            rows = rows.filter { !isExpired($0.value) }
            rows[recipe.pageURLString] = recipe
        }
    }

    /// One-shot: every unexpired row, and the store is left empty.
    public func takeAll() -> [PendingRecoveryRecipe] {
        file.mutate { rows in
            let fresh = rows.values.filter { !isExpired($0) }
            rows = [:]
            return fresh.sorted { $0.dateWritten < $1.dateWritten }
        }
    }

    /// Non-destructive, for diagnostics and tests.
    public func peek() -> [PendingRecoveryRecipe] {
        file.read().values.filter { !isExpired($0) }
            .sorted { $0.dateWritten < $1.dateWritten }
    }

    private func isExpired(_ row: PendingRecoveryRecipe) -> Bool {
        now().timeIntervalSince(row.dateWritten) >= Self.lifetime
    }
}

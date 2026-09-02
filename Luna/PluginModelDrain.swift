//
//  PluginModelDrain.swift
//  Luna
//
//  Adopts a Model the Safari content script queued through `plugins.queueModel`
//  (`claudedocs/plans/plugin-platform.md` §13.1). Safari can neither write a
//  save nor start a download, so it hands the already-`ingest`ed Model over and
//  this drain adopts it the same way `PluginIngestStage` would have, then hands
//  the mapped `Outcome` to `SavesIngestor.applyRescued` — the media download,
//  the article write, and the product tracker are the SAME code path a
//  same-process save reaches, so nothing here re-implements them.
//
//  Universal (no membership exception): every type it names is universal-tier
//  (LunaModels/LunaStorage/LunaIngest/LunaSaves/LunaHTMLClassification), so it
//  compiles into all four app targets even though only `KindWiring+Luna` ever
//  calls it. The one piece that needs the plugin-only tier — building a
//  `ProductInfo` from a plugin's `ProductModel` — rides in as a call argument
//  instead of a seam this file would otherwise have to declare and leave unset
//  everywhere else.
//

import Foundation
import LunaHTMLClassification
import LunaIngest
import LunaModels
import LunaSaves
import LunaStorage
import UIKit

/// Reopens the page a completed drain returns to. `KindWiring+Luna` installs
/// the witness; a process with none never leaves the app.
protocol PluginModelReturnOpening {
    func open(_ url: URL) async
}

/// The app's witness: an ordinary `open` of the page's https URL, because iOS
/// has no "return to the previous app" API.
struct SystemPluginModelReturnOpener: PluginModelReturnOpening {
    func open(_ url: URL) async {
        _ = await UIApplication.shared.open(url)
    }
}

enum PluginModelDrain {

    /// Where a completed drain sends the user back to.
    static var returnOpener: (any PluginModelReturnOpening)?

    /// Takes every queued Model and adopts it. `returningToSource` mirrors the
    /// Safari hand-off's `ret=safari` flag: once every row is settled, the
    /// first row's page is reopened in Safari.
    ///
    /// The bounce also needs the row's own `returnToSourceUntil` to still be in
    /// the future, the way `PendingResolvedMediaReturnPolicy` reads its marker:
    /// a row lives an hour, and a manual launch tomorrow must not be thrown at
    /// yesterday's page.
    ///
    /// `pendingStore`/`store`/`ingestor` are parameters so a test can exercise
    /// this against its own, the same reason `PendingResolvedMediaDownloads
    /// .persistSave` takes them.
    static func run(
        returningToSource: Bool,
        productInfoBuilder: @escaping (ProductModel, URL?) -> ProductInfo,
        pendingStore: PendingPluginModelStore = .shared,
        store: SavesStore = .shared,
        ingestor: SavesIngestor = .shared,
        now: Date = Date()
    ) {
        let rows = pendingStore.takeAll()
        guard !rows.isEmpty else { return }
        Task { @MainActor in
            for row in rows {
                await adopt(row, productInfoBuilder: productInfoBuilder, store: store, ingestor: ingestor)
            }
            guard returningToSource, let opener = returnOpener,
                  (rows[0].returnToSourceUntil ?? .distantPast) > now,
                  let sourceURL = URL(string: rows[0].urlString),
                  sourceURL.scheme?.hasPrefix("http") == true
            else { return }
            await opener.open(sourceURL)
        }
    }

    @MainActor
    static func adopt(
        _ row: PendingPluginModel, productInfoBuilder: (ProductModel, URL?) -> ProductInfo,
        store: SavesStore, ingestor: SavesIngestor
    ) async {
        guard let url = URL(string: row.urlString) else { return }
        guard let data = row.modelJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(PluginModel.self, from: data)
        else {
            await fallBackToNormalIngest(urlString: row.urlString, store: store, ingestor: ingestor)
            return
        }
        let model = decoded.resolvingRelativeURLs(against: url)
        let adopted: PluginAdoptedOutcome
        switch model {
        case let .media(media):
            guard let adopter = PluginModelAdopters.media else {
                await fallBackToNormalIngest(urlString: row.urlString, store: store, ingestor: ingestor)
                return
            }
            adopted = await adopter.adopt(media, url: url, pluginID: row.pluginID)
        case let .article(article):
            guard let adopter = PluginModelAdopters.article else {
                await fallBackToNormalIngest(urlString: row.urlString, store: store, ingestor: ingestor)
                return
            }
            adopted = await adopter.adopt(article, url: url, page: .none, pluginID: row.pluginID)
        case let .product(product):
            guard let adopter = PluginModelAdopters.product else {
                await fallBackToNormalIngest(urlString: row.urlString, store: store, ingestor: ingestor)
                return
            }
            adopted = await adopter.adopt(product, url: url, pluginID: row.pluginID)
        }

        guard let outcome = PluginOutcomeMapping.outcome(
            from: adopted, productInfo: productInfoBuilder)
        else {
            await fallBackToNormalIngest(urlString: row.urlString, store: store, ingestor: ingestor)
            return
        }
        let reservation = store.reserveSaveAttempt(urlString: row.urlString, at: Date())
        _ = await ingestor.applyRescued(
            IngestResult(url: url, outcome: outcome, pluginID: row.pluginID),
            forItemID: reservation.item.id, interactive: false)
    }

    /// The Model could not be adopted (a decode failure, a declined outcome,
    /// no adopter for this kind). Re-entering as an ordinary URL keeps the save
    /// rather than losing it — the Swift classifier is the same floor the
    /// ingest walk itself falls back to (§7.4).
    @MainActor
    private static func fallBackToNormalIngest(
        urlString: String, store: SavesStore, ingestor: SavesIngestor
    ) async {
        guard let url = URL(string: urlString) else { return }
        let reservation = store.reserveSaveAttempt(urlString: url.absoluteString, at: Date())
        _ = await ingestor.ingest(reservation.item, allowsInteractivePrompt: false)
    }
}

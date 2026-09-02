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

enum PluginModelDrain {

    /// Takes every queued Model and adopts it. `returningToSource` mirrors the
    /// Safari hand-off's `ret=safari` flag: once every row is settled, the
    /// first row's page is reopened in Safari — there is no "return to the
    /// previous app" API, so this is an ordinary `open` of its https URL.
    static func run(
        returningToSource: Bool,
        productInfoBuilder: @escaping (ProductModel, URL?) -> ProductInfo
    ) {
        let rows = PendingPluginModelStore.shared.takeAll()
        guard !rows.isEmpty else { return }
        Task { @MainActor in
            for row in rows {
                await adopt(row, productInfoBuilder: productInfoBuilder)
            }
            guard returningToSource, let sourceURL = URL(string: rows[0].urlString),
                  sourceURL.scheme?.hasPrefix("http") == true
            else { return }
            _ = await UIApplication.shared.open(sourceURL)
        }
    }

    @MainActor
    private static func adopt(
        _ row: PendingPluginModel, productInfoBuilder: (ProductModel, URL?) -> ProductInfo
    ) async {
        guard let url = URL(string: row.urlString) else { return }
        guard let data = row.modelJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(PluginModel.self, from: data)
        else {
            await fallBackToNormalIngest(urlString: row.urlString)
            return
        }
        let model = decoded.resolvingRelativeURLs(against: url)
        let adopted: PluginAdoptedOutcome
        switch model {
        case let .media(media):
            guard let adopter = PluginModelAdopters.media else {
                await fallBackToNormalIngest(urlString: row.urlString)
                return
            }
            adopted = await adopter.adopt(media, url: url, pluginID: row.pluginID)
        case let .article(article):
            guard let adopter = PluginModelAdopters.article else {
                await fallBackToNormalIngest(urlString: row.urlString)
                return
            }
            adopted = await adopter.adopt(article, url: url, page: .none, pluginID: row.pluginID)
        case let .product(product):
            guard let adopter = PluginModelAdopters.product else {
                await fallBackToNormalIngest(urlString: row.urlString)
                return
            }
            adopted = await adopter.adopt(product, url: url, pluginID: row.pluginID)
        }

        guard let outcome = Self.outcome(from: adopted, productInfoBuilder: productInfoBuilder) else {
            await fallBackToNormalIngest(urlString: row.urlString)
            return
        }
        let reservation = SavesStore.shared.reserveSaveAttempt(urlString: row.urlString, at: Date())
        _ = await SavesIngestor.shared.applyRescued(
            IngestResult(url: url, outcome: outcome, pluginID: row.pluginID),
            forItemID: reservation.item.id, interactive: false)
    }

    /// The same mapping `PluginIngestStage.adopt` makes in-process — kept as a
    /// small standalone copy because that stage lives in the plugin-only tier
    /// this universal file cannot import.
    private static func outcome(
        from adopted: PluginAdoptedOutcome, productInfoBuilder: (ProductModel, URL?) -> ProductInfo
    ) -> Outcome? {
        switch adopted {
        case .declined, .failed:
            return nil
        case let .media(assets, platform, itemID, _, _):
            let hasTimeline = assets.contains { $0.kind == .video || $0.kind == .audio }
            return hasTimeline
                ? .video(platform ?? .web, itemID: itemID)
                : .social(platform ?? .web, itemID: itemID)
        case let .article(content, sourceHTML):
            return .article(content, html: sourceHTML ?? "")
        case let .product(productModel, imageURL):
            return .product(productInfoBuilder(productModel, imageURL), html: "")
        }
    }

    /// The Model could not be adopted (a decode failure, a declined outcome,
    /// no adopter for this kind). Re-entering as an ordinary URL keeps the save
    /// rather than losing it — the Swift classifier is the same floor the
    /// ingest walk itself falls back to (§7.4).
    @MainActor
    private static func fallBackToNormalIngest(urlString: String) async {
        guard let url = URL(string: urlString) else { return }
        let reservation = SavesStore.shared.reserveSaveAttempt(urlString: url.absoluteString, at: Date())
        _ = await SavesIngestor.shared.ingest(reservation.item, allowsInteractivePrompt: false)
    }
}

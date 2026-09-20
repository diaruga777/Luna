//
//  RecoveryContentAdoption.swift
//  LunaIngest
//

import Foundation
import LunaModels

/// Turns a recovery Luna file's `content` into the pipeline outcome a save is
/// written from (`claudedocs/luna-file.md`).
///
/// The content IS a plugin `PluginModel`, so it takes exactly the chain a
/// plugin's Model takes — `PluginModelAdopters` for the kind, then
/// `PluginOutcomeMapping` — and a recovered save is therefore indistinguishable
/// from any other save downstream.
///
/// It sits here, above the kind modules and below both callers, because a
/// recovery file lands on two surfaces that persist differently: the app writes
/// it through `SavesIngestor.applyRescued`, an extension through
/// `ShareSurfaceDriver.present`. The adoption itself must not differ.
public enum RecoveryContentAdoption {

    /// The provenance a recovered save carries where a plugin save carries its
    /// plugin's id. It matches no plugin: it says the content came from a chat
    /// reply.
    public static let pluginID = "luna.recovery-file"

    /// The outcome to save, or nil when this app has no adopter for that kind
    /// or the adopter kept nothing.
    public static func outcome(for file: LunaRecoveryFile) async -> Outcome? {
        let adopted: PluginAdoptedOutcome
        switch file.content.resolvingRelativeURLs(against: file.url) {
        case let .article(article):
            guard let adopter = PluginModelAdopters.article else { return nil }
            adopted = await adopter.adopt(
                article, url: file.url, page: .none, pluginID: pluginID)
        case let .media(media):
            guard let adopter = PluginModelAdopters.media else { return nil }
            adopted = await adopter.adopt(media, url: file.url, pluginID: pluginID)
        case let .product(product):
            guard let adopter = PluginModelAdopters.product else { return nil }
            adopted = await adopter.adopt(product, url: file.url, pluginID: pluginID)
        }
        return PluginOutcomeMapping.outcome(from: adopted)
    }
}

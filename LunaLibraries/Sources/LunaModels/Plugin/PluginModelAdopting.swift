//
//  PluginModelAdopting.swift
//  LunaModels
//

import Foundation

/// What a kind module made of a plugin's Model.
///
/// The pipeline's own `Outcome` lives in LunaIngest, ABOVE this tier, so an
/// adopter answers in this small shape and `PluginIngestStage` maps it onto
/// `Outcome`. `ProductInfo` likewise lives above LunaModels (in
/// LunaHTMLClassification), so the product case carries the Model itself plus
/// the resolved image URL and the higher tier builds `ProductInfo` from them.
public enum PluginAdoptedOutcome {
    case media(
        assets: [MediaAsset],
        platform: ContentPlatform?,
        itemID: String?,
        title: String?,
        thumbnailURL: URL?)
    case article(ArticleContent, sourceHTML: String?)
    case product(ProductModel, imageURL: URL?)
    /// The kind module read the Model and kept nothing. The walk continues with
    /// the next plugin, then the Swift classifier.
    case declined
    case failed(SaveFailureReason?)
}

/// Turns a plugin's `media` Model into downloadable assets. `MediaKindComposition`
/// installs the witness.
public protocol MediaModelAdopting {
    func adopt(_ model: MediaModel, url: URL, pluginID: String) async -> PluginAdoptedOutcome
}

/// Turns a plugin's `article` Model into `ArticleContent`. The Model's HTML is
/// the body the plugin already chose, so the adopter converts it as trusted
/// rather than re-scoring it. `ArticleKindComposition` installs the witness.
public protocol ArticleModelAdopting {
    func adopt(
        _ model: ArticleModel, url: URL, page: CapturedPage, pluginID: String
    ) async -> PluginAdoptedOutcome
}

/// Turns a plugin's `product` Model into a tracker. `ProductKindComposition`
/// installs the witness.
public protocol ProductModelAdopting {
    func adopt(_ model: ProductModel, url: URL, pluginID: String) async -> PluginAdoptedOutcome
}

/// The three witnesses, one per kind.
///
/// A kind pack sets its own; an app that links no plugin platform leaves the
/// assignment harmlessly unread. `PluginIngestStage` refuses a Model whose kind
/// has no adopter, so a plugin can never produce a kind its host cannot store.
public enum PluginModelAdopters {
    public static var media: MediaModelAdopting?
    public static var article: ArticleModelAdopting?
    public static var product: ProductModelAdopting?

    /// Whether a Model of this kind can be adopted in this process.
    public static func hasAdopter(for kind: PluginModelKind) -> Bool {
        switch kind {
        case .media: return media != nil
        case .article: return article != nil
        case .product: return product != nil
        }
    }
}

//
//  ArticleEntity.swift
//  Luna
//
//  Siri/Shortcuts entity definition, in the app target for discovery.
//  `AppEntity`/`EntityQuery` conformances live here, alongside the `AppIntent`
//  definitions; matching and ranking logic lives in LunaIntents.ArticleMatcher.
//  See claudedocs/audio-playback.md's "Siri" section.
//

import AppIntents
import CoreSpotlight
import LunaIntents
import LunaModels
import LunaStorage
import Foundation

/// A saved, readable article as a Siri/Shortcuts/Spotlight entity. Its visible
/// representation shows the title, saved date, and source host. Restricted to
/// `ArticleReadability.isReadableArticle` articles — never videos, social
/// posts, or price trackers. `IndexedEntity` keeps it semantically
/// discoverable in Spotlight; `ArticleSpotlightIndexWiring`, in the article
/// apps' main process only, drives the actual `CSSearchableIndex` writes.
struct ArticleEntity: AppEntity, IndexedEntity {
    let id: UUID
    @Property(title: "Intents_articleEntity_titleProperty_title_Luna") var title: String
    @Property(title: "Intents_articleEntity_savedDateProperty_title_Luna") var savedDate: Date
    @Property(title: "Intents_articleEntity_sourceHostProperty_title_Luna") var sourceHost: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Intents_articleEntity_typeName_Luna"
    static var defaultQuery = ArticleEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        let subtitle = Self.subtitleText(sourceHost: sourceHost, savedDate: savedDate)
        return DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }

    /// Formats `"<host> · <date>"`, or just the date when there is no host — a
    /// document imported through the synthetic `lunadoc://` scheme is still a
    /// readable article, just with no real web host. Internal, not `private`,
    /// so `ArticleEntityDisplayTests` can verify the composition directly
    /// without going through `DisplayRepresentation`/`LocalizedStringResource`.
    static func subtitleText(sourceHost: String, savedDate: Date) -> String {
        let dateText = dateFormatter.string(from: savedDate)
        return sourceHost.isEmpty ? dateText : "\(sourceHost) · \(dateText)"
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    init(item: SavedItem) {
        self.id = item.id
        self.title = item.title ?? item.urlString
        self.savedDate = item.bumpDate ?? item.dateAdded
        self.sourceHost = ArticleSourceName.host(fromURLString: item.urlString) ?? ""
    }
}

/// Bridges `ArticleMatcher`'s plain logic to the AppIntents entity-query
/// protocols: lookup by id, the `EntityStringQuery` "find" search behind
/// phrases like "from The Atlantic", "about Boston", or a relative date, and
/// suggested (recent unread) articles.
struct ArticleEntityQuery: EntityQuery, EntityStringQuery {
    init() {}

    func entities(for identifiers: [UUID]) async throws -> [ArticleEntity] {
        let store = SavesStore.shared
        return identifiers
            .compactMap { store.item(withID: $0) }
            .filter(ArticleReadability.isReadableArticle)
            .map(ArticleEntity.init(item:))
    }

    func entities(matching string: String) async throws -> [ArticleEntity] {
        ArticleMatcher.search(query: string, in: SavesStore.shared.items())
            .map(ArticleEntity.init(item:))
    }

    func suggestedEntities() async throws -> [ArticleEntity] {
        ArticleMatcher.suggested(in: SavesStore.shared.items())
            .map(ArticleEntity.init(item:))
    }
}

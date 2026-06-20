//
//  SaveLinkIntent.swift
//  Clip
//

import AppIntents
import Foundation

/// Saves a specific weblink to the reading list, exactly as given. For "save
/// whatever Safari is showing", use ClipSafariPageIntent instead.
struct SaveLinkIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Link"
    static let description = IntentDescription(
        "Saves a link to your Queue reading list.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "URL", description: "The link to save.")
    var url: URL

    func perform() async throws -> some IntentResult & ReturnsValue<String?> {
        // `handleSavePressWithTimeout` normalizes Facebook deep links to their real
        // http article, so an `fbrpc://…` URL passed here saves the article.
        let savedURL = await IntentIngestHelper.handleSavePressWithTimeout(
            urlString: url.absoluteString)
        return .result(value: savedURL)
    }
}

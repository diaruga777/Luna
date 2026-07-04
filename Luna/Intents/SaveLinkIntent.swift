//
//  SaveLinkIntent.swift
//  Luna
//

import LunaIntents
import LunaMediaDownload
import AppIntents
import Foundation

/// Saves a specific weblink to the reading list, exactly as given. For "save
/// whatever Safari is showing", use LunaSafariPageIntent instead.
public struct SaveLinkIntent: AppIntent {
    public init() {}
    public static let title: LocalizedStringResource = "Save Link"
    public static let description = IntentDescription(
        "Saves a link to your Luna reading list.")
    public static let openAppWhenRun: Bool = false

    @Parameter(title: "URL", description: "The link to save.")
    public var url: URL

    public func perform() async throws -> some IntentResult & ReturnsValue<String?> {
        // `handleSavePressWithTimeout` normalizes Facebook deep links to their real
        // http article, so an `fbrpc://…` URL passed here saves the article.
        let savedURL = await IntentIngestHelper.handleSavePressWithTimeout(
            urlString: url.absoluteString)
        let mediaURL = savedURL ?? url.absoluteString
        guard MediaDownloadablePlatform.supports(mediaURL) else {
            return .result(value: savedURL)
        }
        if MediaAutoDownloader.isEnabled(forURLString: mediaURL) {
            _ = await LiveMediaDownloadManager.shared.start(urlString: mediaURL)
            return .result(value: savedURL)
        }
        return .result(value: "4:\(mediaURL)")
    }
}

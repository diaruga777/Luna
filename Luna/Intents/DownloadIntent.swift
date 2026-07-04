//
//  DownloadIntent.swift
//  Luna
//

import AppIntents
import Foundation
import LunaMediaDownload

public struct DownloadIntent: AppIntent {
    public init() {}
    public static let title: LocalizedStringResource = "Download"
    public static let description = IntentDescription(
        "Starts a Live Activity and background download for a social media URL.")
    public static let openAppWhenRun: Bool = false

    @Parameter(title: "URL", description: "The social media post or media URL to download.")
    public var url: URL

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let started = await LiveMediaDownloadManager.shared.start(urlString: url.absoluteString)
        return .result(value: started ? "Download started." : "Couldn't start download.")
    }
}

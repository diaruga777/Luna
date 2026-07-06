//
//  SaveFromAppIntent.swift
//  Luna
//

import LunaIntents
import LunaYouTubeAPI
import LunaPlatforms
import LunaStorage
import LunaURLClassification
import LunaModels
import LunaMediaDownload
import AppIntents
import Foundation

/// One generic save action that adapts to the current app. Pass the current app
/// (from Get Current App) and a single response string produced by the on-device
/// model for that app's screen. Each app encodes its fields into one string using
/// the format documented in `AppNamePlatform.screenPrompt` (fields joined by
/// " ; "); this intent splits that same string back into the fields it needs.
/// Apps that need no model response (Safari) accept a nil or empty string and fall
/// back to the tracked page URL. If the model errors or finds nothing it returns an
/// empty/"none" string, which is treated as "nothing to save".
public struct SaveFromAppIntent: AppIntent {
    public init() {}
    public static let title: LocalizedStringResource = "Save from App"
    public static let description = IntentDescription("""
        Saves content based on the current app. Pass the current app and the single \
        response string the model produced for that app's screen (fields joined by \
        " ; "). Safari and unknown apps may pass an empty string — the tracked page \
        URL is saved instead.
        """)
    public static let openAppWhenRun: Bool = false

    @Parameter(title: "App", description: "The current app, from Get Current App.")
    public var app: String?

    @Parameter(title: "Details", description: "The model's response string for the current app, or empty.")
    public var details: String?

    public enum SaveError: Error, CustomLocalizedStringResourceConvertible {
        case missingValues
        case notFound
        case youTubeNotSignedIn

        public var localizedStringResource: LocalizedStringResource {
            switch self {
            case .missingValues: return "Nothing to save was provided."
            case .notFound: return "Couldn't find a matching item."
            case .youTubeNotSignedIn: return "Sign in to YouTube in Luna's settings first."
            }
        }
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let app else { throw SaveError.missingValues }

        // Before any save work: let the Action Button onboarding state machine
        // hijack this invocation if it's mid-flight for this surface. Its first
        // interception fires from the Shortcuts app (the freshly-imported
        // shortcut's own first run); its second fires from wherever the Action
        // Button was actually pressed, once real setup is complete.
        let surface = AppSurfaceConfig.current.storageIdentifier
        switch ActionButtonOnboardingStore.shared.handleSaveIntentInvoked(
            appName: app, isCurrentAppLuna: Self.isCurrentAppLuna(comparedTo: app), forSurface: surface
        ) {
        case .returnOpenLunaToken:
            return .result(value: ActionButtonOnboardingStore.openLunaToken)
        case .returnEmpty:
            return .result(value: "")
        case .none:
            break
        }

        let fields = Self.parseFields(from: details)
        let platform = AppNamePlatform.platform(forAppName: app)

        switch platform {
        case .youtube:
            try await saveYouTube(channel: fields.first, title: fields.dropFirst().first)
        case .bluesky:
            let query = BlueskyPostQuery.searchQuery(
                handle: fields.first ?? "", text: fields.dropFirst().first ?? "")
            try await saveSearch(query) { try await BlueskySearchClient().topPostURL(query: $0) }
        case .reddit:
            let query = RedditPostQuery.searchQuery(
                subreddit: fields.first ?? "", title: fields.dropFirst().first ?? "",
                author: fields.dropFirst(2).first)
            try await saveSearch(query) { try await RedditSearchClient().topPostURL(query: $0) }
        case .music:
            try await saveMedia(.music, creator: fields.first, title: fields.dropFirst().first)
        case .podcast:
            try await saveMedia(.podcast, creator: fields.first, title: fields.dropFirst().first)
        case .x, .tiktok, .instagram, .facebook:
            // No public search API: find the post from [handle, content, time?].
            guard let finderPlatform = Self.finderPlatform(for: platform) else { throw SaveError.notFound }
            guard let url = await SocialPostFinder.findPostURL(
                platform: finderPlatform, handle: fields.first ?? "",
                content: fields.dropFirst().first, timestamp: fields.dropFirst(2).first)
            else { throw SaveError.notFound }
            return .result(value: await saveAndDownloadReturnValue(url.absoluteString))
        case nil:
            // Safari / unknown: a link in the response, else the tracked page URL.
            let link = fields.first { $0.hasPrefix("http") } ?? SafariURLStore.lastURL
            guard let link, link.hasPrefix("http") else { throw SaveError.notFound }
            return .result(value: await saveAndDownloadReturnValue(link))
        }
        return .result(value: "Saved to Luna.")
    }

    /// Splits the model's single response string into its " ; "-joined fields,
    /// trimming each and dropping empties. A "none" response (the model's
    /// "nothing identifiable" / error sentinel) yields no fields.
    public static func parseFields(from response: String?) -> [String] {
        let trimmed = (response ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "none" else { return [] }
        return trimmed.components(separatedBy: " ; ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Whether the "current app" reported by Shortcuts (`Get Current App`) is THIS
    /// Luna app — i.e. the Action Button was pressed while Luna itself was
    /// frontmost, so there's no need to bounce the user back to it. Compared
    /// case-insensitively against the running bundle's display/bundle name, plus a
    /// generic "Luna"-prefix match (covers "Luna", "Luna Reader", "Luna Downloader",
    /// "Luna Price Tracker" regardless of exactly how Shortcuts reports the name).
    private static func isCurrentAppLuna(comparedTo appName: String) -> Bool {
        let name = appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return false }
        if name.hasPrefix("luna") { return true }
        let displayName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)?
            .lowercased()
        let bundleName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)?
            .lowercased()
        return name == displayName || name == bundleName
    }

    private static func finderPlatform(for platform: ContentPlatform?) -> SocialPostFinder.Platform? {
        switch platform {
        case .x: return .x
        case .tiktok: return .tiktok
        case .instagram: return .instagram
        case .facebook: return .facebook
        default: return nil
        }
    }

    private func saveYouTube(channel: String?, title: String?) async throws {
        do {
            _ = try await YouTubeVideoSave.findAndSave(channel: channel ?? "", title: title ?? "")
        } catch YouTubeVideoSave.FindFailure.notSignedIn {
            throw SaveError.youTubeNotSignedIn
        } catch YouTubeVideoSave.FindFailure.badQuery {
            throw SaveError.missingValues
        } catch is YouTubeVideoSave.FindFailure {
            throw SaveError.notFound
        }
    }

    private func saveSearch(_ query: String, resolve: (String) async throws -> URL) async throws {
        guard !query.isEmpty else { throw SaveError.missingValues }
        guard let url = try? await resolve(query) else { throw SaveError.notFound }
        _ = await IntentIngestHelper.handleSavePressWithTimeout(urlString: url.absoluteString)
    }

    private func saveMedia(_ platform: ContentPlatform, creator: String?, title: String?) async throws {
        guard let creator, let title else { throw SaveError.missingValues }
        await MediaItemSave.save(platform: platform, creator: creator, title: title)
    }

    private func saveAndDownloadReturnValue(_ urlString: String) async -> String {
        _ = await IntentIngestHelper.handleSavePressWithTimeout(urlString: urlString)
        guard MediaDownloadablePlatform.supports(urlString) else { return "Saved to Luna." }
        if MediaAutoDownloader.isEnabled(forURLString: urlString) {
            _ = await LiveMediaDownloadManager.shared.start(urlString: urlString)
            return "Saved to Luna."
        }
        return "4:\(urlString)"
    }
}

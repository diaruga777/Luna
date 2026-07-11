//
//  SaveFromAppIntent.swift
//  Luna
//

import LunaIntents
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

        public var localizedStringResource: LocalizedStringResource {
            switch self {
            case .missingValues: return "Nothing to save was provided."
            case .notFound: return "Couldn't find a matching item."
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
        switch ActionButtonOnboardingStore.shared.handleProvideContextInvoked(
            appName: app, isCurrentAppLuna: Self.isCurrentAppLuna(comparedTo: app), forSurface: surface
        ) {
        case .foregroundThenUnsupported:
            // TEMPORARY shim (removed with this whole file in commit 8): the old
            // Shortcut branches on this exact literal with an "Open App → Luna"
            // action; `openLunaToken` itself was retired since this was its last
            // live reference.
            return .result(value: "open-luna")
        case .unsupported:
            return .result(value: "")
        case .none:
            break
        }

        let fields = SaveResponseParsing.parseFields(from: details)
        let platform = AppNamePlatform.platform(forAppName: app)

        switch platform {
        case .bluesky:
            let query = BlueskyPostQuery.searchQuery(
                handle: fields.first ?? "", text: fields.dropFirst().first ?? "")
            return .result(value: try await saveSearch(query) {
                try await BlueskySearchClient().topPostURL(query: $0) })
        case .reddit:
            let query = RedditPostQuery.searchQuery(
                subreddit: fields.first ?? "", title: fields.dropFirst().first ?? "",
                author: fields.dropFirst(2).first)
            return .result(value: try await saveSearch(query) {
                try await RedditSearchClient().topPostURL(query: $0) })
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

    /// The double-save action (send to Kindle / friend on a repeat press within
    /// 7 s) is armed only for the Reader app's Action Button saves — every other
    /// surface and save path keeps the plain save behavior.
    private static var doubleSaveSurface: String? {
        guard AppSurfaceConfig.current == .reader else { return nil }
        return AppSurfaceConfig.current.storageIdentifier
    }

    /// One save press through the intent path, with the double-save action armed
    /// when this app is eligible for it.
    private static func savePress(urlString: String) async -> IntentIngestHelper.ActionButtonSaveOutcome {
        guard let surface = doubleSaveSurface else {
            return .completed(savedURLString:
                await IntentIngestHelper.handleSavePressWithTimeout(urlString: urlString))
        }
        return await IntentIngestHelper.handleActionButtonSavePress(
            urlString: urlString, doubleSaveActionSurface: surface)
    }

    /// Saves a search-resolved post URL; returns the intent's result string
    /// (the open-Luna token when a double save asked for the friend selector).
    private func saveSearch(_ query: String, resolve: (String) async throws -> URL) async throws -> String {
        guard !query.isEmpty else { throw SaveError.missingValues }
        guard let url = try? await resolve(query) else { throw SaveError.notFound }
        switch await Self.savePress(urlString: url.absoluteString) {
        case .friendPromptRequested:
            // TEMPORARY literal (removed with this whole file in commit 8) —
            // see the note in `perform()`.
            return "open-luna"
        case .completed:
            return "Saved to Luna."
        }
    }

    private func saveAndDownloadReturnValue(_ urlString: String) async -> String {
        switch await Self.savePress(urlString: urlString) {
        case .friendPromptRequested:
            // Double save with "ask every time": bounce into Luna's friend
            // selector (the pending prompt is already recorded). The Shortcut's
            // "Open App → Luna" branch keys off this exact token. TEMPORARY
            // literal (removed with this whole file in commit 8).
            return "open-luna"
        case .completed:
            break
        }
        guard MediaDownloadablePlatform.supports(urlString) else { return "Saved to Luna." }
        if MediaAutoDownloader.isEnabled(forURLString: urlString) {
            _ = await LiveMediaDownloadManager.shared.start(urlString: urlString)
            return "Saved to Luna."
        }
        return "4:\(urlString)"
    }
}

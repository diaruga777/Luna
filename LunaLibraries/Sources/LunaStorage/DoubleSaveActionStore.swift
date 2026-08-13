//
//  DoubleSaveActionStore.swift
//  Luna
//

import LunaAppConfig
import Foundation
import LunaModels

/// What a double save of an ARTICLE (the same URL saved twice within 7 seconds
/// via the Action Button's Save App Intent — no other save surface) should do.
/// Chosen in Settings → Shortcut & Safari, in the two apps that can build
/// article files (Luna and Luna Reader). See claudedocs/double-save.md.
///
/// `allCases` is the picker's order.
public enum DoubleSaveAction: String, CaseIterable {
    /// The second press does nothing. The default — a double save is easy to
    /// trigger by accident, so it stays inert until the user opts in. Spelled
    /// `nothing`, not `none`, so it never collides with `Optional.none` at a
    /// call site.
    case nothing
    /// Emails the article's EPUB to the configured Kindle address, through the
    /// send-to-Kindle pipeline.
    case sendToKindle
    /// Return the article as a self-contained Word document for the
    /// Shortcut to display immediately or pass onward.
    case openDocument

    public var displayName: String {
        switch self {
        case .nothing: return L10n.string("Saves_doubleSave_actionNothingTitle")
        case .sendToKindle: return L10n.string("Common_sendToKindle")
        case .openDocument: return L10n.string("Saves_doubleSave_actionViewImmediatelyTitle")
        }
    }

    /// The file the App Intent should return for this action, or nil when the
    /// action isn't an export (`.nothing` / `.sendToKindle`).
    public var exportFormat: ArticleExportFormat? {
        switch self {
        case .nothing, .sendToKindle: return nil
        case .openDocument: return .document
        }
    }
}

/// App-Group-backed, per-surface settings for the double-save action, plus the
/// one-shot "friend prompt pending" hand-off the Save App Intent writes right
/// before it asks the Shortcut to open Luna: the foregrounding scene consumes
/// it and presents the friend selector.
public final class DoubleSaveActionStore {

    public static let shared = DoubleSaveActionStore()

    /// How long a written friend prompt stays valid. Foregrounding usually
    /// happens within a second or two of the intent; anything older is a stale
    /// leftover (e.g. the user dismissed the shortcut's open) and is dropped.
    public static let friendPromptLifetime: TimeInterval = 5 * 60

    private let defaults: UserDefaults
    private let now: () -> Date

    public init(defaults: UserDefaults? = nil, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: AppConfig.appGroupID)
            ?? .standard
        self.now = now
    }

    // `.rawValue` is used ONLY here, at the four defaults-key builders — every
    // caller above this file works with `DoubleSaveSurface` itself, never a
    // bare surface string.
    private func actionKey(forSurface surface: DoubleSaveSurface) -> String {
        "doubleSave.action.\(surface.rawValue)"
    }

    private func presetEmailsKey(forSurface surface: DoubleSaveSurface) -> String {
        "doubleSave.presetFriendEmails.\(surface.rawValue)"
    }

    private func promptURLKey(forSurface surface: DoubleSaveSurface) -> String {
        "doubleSave.pendingFriendPromptURL.\(surface.rawValue)"
    }

    private func promptDateKey(forSurface surface: DoubleSaveSurface) -> String {
        "doubleSave.pendingFriendPromptDate.\(surface.rawValue)"
    }

    // MARK: - Settings

    /// Defaults to `.nothing`. The retired PDF/Markdown choices migrate to the
    /// single document action; any other retired value (such as the old
    /// `sendToFriend`) lands on the inert default.
    public func action(forSurface surface: DoubleSaveSurface) -> DoubleSaveAction {
        guard let rawValue = defaults.string(forKey: actionKey(forSurface: surface))
        else { return .nothing }
        switch rawValue {
        case "openPDF", "openMarkdown": return .openDocument
        default: return DoubleSaveAction(rawValue: rawValue) ?? .nothing
        }
    }

    public func setAction(_ action: DoubleSaveAction, forSurface surface: DoubleSaveSurface) {
        defaults.set(action.rawValue, forKey: actionKey(forSurface: surface))
    }

    /// The preset recipient emails (lowercased addresses), in selection order.
    public func presetFriendEmails(forSurface surface: DoubleSaveSurface) -> [String] {
        defaults.stringArray(forKey: presetEmailsKey(forSurface: surface)) ?? []
    }

    public func setPresetFriendEmails(_ emails: [String], forSurface surface: DoubleSaveSurface) {
        defaults.set(emails, forKey: presetEmailsKey(forSurface: surface))
    }

    // MARK: - Ask-every-time hand-off

    /// Records that the app, once foregrounded, should present the friend
    /// selector for `urlString`.
    public func setPendingFriendPrompt(urlString: String, forSurface surface: DoubleSaveSurface) {
        defaults.set(urlString, forKey: promptURLKey(forSurface: surface))
        defaults.set(now().timeIntervalSinceReferenceDate,
                     forKey: promptDateKey(forSurface: surface))
    }

    /// One-shot consume: returns the pending prompt's URL (clearing it), or nil
    /// when there is none or it has gone stale.
    public func takePendingFriendPrompt(forSurface surface: DoubleSaveSurface) -> String? {
        defer {
            defaults.removeObject(forKey: promptURLKey(forSurface: surface))
            defaults.removeObject(forKey: promptDateKey(forSurface: surface))
        }
        guard let urlString = defaults.string(forKey: promptURLKey(forSurface: surface)),
              defaults.object(forKey: promptDateKey(forSurface: surface)) != nil
        else { return nil }
        let written = Date(timeIntervalSinceReferenceDate:
            defaults.double(forKey: promptDateKey(forSurface: surface)))
        guard now().timeIntervalSince(written) < Self.friendPromptLifetime else { return nil }
        return urlString
    }
}

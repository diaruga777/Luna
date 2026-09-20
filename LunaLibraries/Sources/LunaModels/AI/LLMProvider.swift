//
//  LLMProvider.swift
//  LunaModels
//

import Foundation
import LunaAppConfig

/// A chat model Luna can hand a prompt to. Luna never calls one over the
/// network: it opens the provider's app with the prompt already written, and
/// the reply comes back as a Luna file (`claudedocs/llm-handoff.md`).
public enum LLMProvider: String, CaseIterable, Codable, Equatable, Sendable {
    case chatGPT
    case claude

    public var displayName: String {
        switch self {
        case .chatGPT: return L10n.string("LLMProvider_chatGPT")
        case .claude: return L10n.string("LLMProvider_claude")
        }
    }
}

/// Which Claude surface a hand-off opens. Ordinary chat is the default; a user
/// who has Claude Code picks it once from the button's long-press menu and
/// Luna remembers.
public enum LLMClaudeTarget: String, CaseIterable, Codable, Equatable, Sendable {
    case chat
    case code

    public var displayName: String {
        switch self {
        case .chat: return L10n.string("LLMProvider_claudeChat")
        case .code: return L10n.string("LLMProvider_claudeCode")
        }
    }
}

/// The one preference the hand-off keeps. App-Group backed, because the share
/// extension builds the same links the app does.
public enum LLMProviderPreferences {
    private static let claudeTargetKey = "llm.claudeTarget"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: AppConfig.appGroupID) ?? .standard
    }

    /// `.chat` until the user picks Claude Code, then that, until they pick
    /// back.
    public static var claudeTarget: LLMClaudeTarget {
        get {
            (defaults.string(forKey: claudeTargetKey).flatMap(LLMClaudeTarget.init(rawValue:)))
                ?? .chat
        }
        set { defaults.set(newValue.rawValue, forKey: claudeTargetKey) }
    }
}

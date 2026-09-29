//
//  LLMDeepLink.swift
//  LunaModels
//

import Foundation

/// Builds the link that opens a provider with Luna's prompt already written
/// (`claudedocs/llm-handoff.md`). Pure: it knows the two providers' URL shapes
/// and nothing about whether either app is installed.
///
/// Each provider has a PRIMARY form and a fallback the caller opens when the
/// primary cannot be opened here. ChatGPT uses its web query route: opening
/// `chatgpt://new-chat?prompt=` can launch the app while silently discarding
/// the prompt. Claude uses a universal link.
public enum LLMDeepLink {

    /// The longest URL a provider is asked to accept. Claude Code caps its `q`
    /// at 5,000 characters and third-party ChatGPT link generators cap theirs
    /// at 2,000–4,000, so a prompt near `LLMHandoffPrompts.maxCharacters` has
    /// room to encode and the ceiling still catches an overrun.
    public static let maxURLCharacters = 8_000

    /// The characters that may stay literal inside the query value. Everything
    /// `urlQueryAllowed` permits, less the delimiters that would end the value
    /// or start another component.
    static let promptAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?#/")
        return set
    }()

    /// The provider link to open first, or nil when the encoded prompt would
    /// make it longer than `maxURLCharacters`.
    public static func url(
        for provider: LLMProvider, prompt: String,
        claudeTarget: LLMClaudeTarget = LLMProviderPreferences.claudeTarget
    ) -> URL? {
        switch provider {
        case .chatGPT:
            return build("https://chatgpt.com/?q=", prompt)
        case .claude:
            switch claudeTarget {
            case .chat: return build("https://claude.ai/new?q=", prompt)
            case .code: return build("https://claude.ai/code/new?q=", prompt)
            }
        }
    }

    /// What to open when `url(for:…)` cannot be opened in this process, or nil
    /// when the primary is the only form. Claude's chat link is already the
    /// web, so it has none.
    public static func fallbackURL(
        for provider: LLMProvider, prompt: String,
        claudeTarget: LLMClaudeTarget = LLMProviderPreferences.claudeTarget
    ) -> URL? {
        switch provider {
        case .chatGPT:
            return nil
        case .claude:
            switch claudeTarget {
            case .chat: return nil
            case .code: return build("claude://code/new?q=", prompt)
            }
        }
    }

    private static func build(_ prefix: String, _ prompt: String) -> URL? {
        guard let encoded = prompt.addingPercentEncoding(
            withAllowedCharacters: promptAllowed) else { return nil }
        let text = prefix + encoded
        guard text.count <= maxURLCharacters else { return nil }
        return URL(string: text)
    }
}

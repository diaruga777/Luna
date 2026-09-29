//
//  LLMLauncher.swift
//  LunaDesignSystem
//

import LunaModels
import UIKit

/// Opens a provider link. The app opens it itself; an extension may only ask
/// its host, and the host may refuse — which is why this is a seam rather than
/// a call to `UIApplication` wherever a hand-off starts.
@MainActor
public protocol LLMLaunching: AnyObject {
    /// Opens `url`, or `fallback` when this process cannot open `url`.
    func openLLM(_ url: URL, fallback: URL?)
}

/// The app's launcher: it asks the system whether the provider's own app can
/// take the link, and opens the web form when it cannot.
@MainActor
public final class LLMLauncher: LLMLaunching {
    public static let shared = LLMLauncher()

    public init() {}

    public func openLLM(_ url: URL, fallback: URL?) {
        let application = UIApplication.shared
        application.open(url, options: [:]) { opened in
            if !opened, let fallback { application.open(fallback) }
        }
    }
}

public extension LLMLaunching {
    /// Returns true when the prompt needed clipboard delivery because its
    /// percent-encoded URL exceeded the provider limit. Never drop a tap.
    @discardableResult
    func openPrompt(_ prompt: String, provider: LLMProvider) -> Bool {
        if let url = LLMDeepLink.url(for: provider, prompt: prompt) {
            openLLM(url, fallback: LLMDeepLink.fallbackURL(for: provider, prompt: prompt))
            return false
        }
        UIPasteboard.general.string = prompt
        let landing = LLMDeepLink.url(for: provider, prompt: "")!
        openLLM(landing, fallback: LLMDeepLink.fallbackURL(for: provider, prompt: ""))
        return true
    }
}

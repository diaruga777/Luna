//
//  SaveRecoveryHandoff.swift
//  Luna
//

import LunaDesignSystem
import LunaModels
import LunaStorage
import UIKit

/// Records a recovery hand-off and opens the provider — the one place that
/// does both (`claudedocs/llm-handoff.md`).
///
/// Three surfaces start a recovery: the failed card's row, the Downloader's
/// no-media card, and a ready card's long-press menu. They differ only in the
/// sentence they put in the prompt, so the record and the launch live here and
/// the surfaces pass their own sentence in. A surface that recorded without
/// launching, or launched without recording, would leave a card waiting on a
/// reply nobody asked for.
@MainActor
enum SaveRecoveryHandoff {

    static func prompt(for item: SavedItem, failure: String?) -> String? {
        guard let url = item.url else { return nil }
        return LLMHandoffPrompts.recovery(url: url, app: LunaApp.current, failure: failure)
    }

    /// Builds the prompt for `item`, records the hand-off and opens
    /// `provider`. Oversized links open an empty composer with the full prompt
    /// on the clipboard. False when the save has no URL.
    @discardableResult
    static func begin(
        item: SavedItem,
        provider: LLMProvider,
        claudeTarget: LLMClaudeTarget = LLMProviderPreferences.claudeTarget,
        failure: String?,
        launcher: any LLMLaunching = LLMLauncher.shared
    ) -> Bool {
        guard let prompt = prompt(for: item, failure: failure) else { return false }
        // Preserve the whole prompt even if a native app ignores query text,
        // or Unicode percent-encoding pushes it past the URL limit.
        UIPasteboard.general.string = prompt
        let linkPrompt = LLMDeepLink.url(
            for: provider, prompt: prompt, claudeTarget: claudeTarget) == nil ? "" : prompt
        guard let link = LLMDeepLink.url(
            for: provider, prompt: linkPrompt, claudeTarget: claudeTarget) else { return false }
        LLMHandoffStore.shared.begin(
            .recovery(itemID: item.id, urlString: item.urlString),
            provider: provider, claudeTarget: claudeTarget)
        launcher.openLLM(
            link,
            fallback: LLMDeepLink.fallbackURL(
                for: provider, prompt: linkPrompt, claudeTarget: claudeTarget))
        return true
    }
}

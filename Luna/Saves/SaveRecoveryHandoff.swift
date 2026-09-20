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

    /// Builds the prompt for `item`, records the hand-off and opens
    /// `provider`. False when the page has no URL or the built link is over
    /// `LLMDeepLink.maxURLCharacters`; nothing is recorded then.
    @discardableResult
    static func begin(
        item: SavedItem,
        provider: LLMProvider,
        claudeTarget: LLMClaudeTarget = LLMProviderPreferences.claudeTarget,
        failure: String?
    ) -> Bool {
        guard let url = item.url else { return false }
        let prompt = LLMHandoffPrompts.recovery(
            url: url, app: LunaApp.current, failure: failure)
        guard let link = LLMDeepLink.url(
            for: provider, prompt: prompt, claudeTarget: claudeTarget)
        else { return false }
        LLMHandoffStore.shared.begin(
            .recovery(itemID: item.id, urlString: item.urlString),
            provider: provider, claudeTarget: claudeTarget)
        LLMLauncher.shared.openLLM(
            link,
            fallback: LLMDeepLink.fallbackURL(
                for: provider, prompt: prompt, claudeTarget: claudeTarget))
        return true
    }
}

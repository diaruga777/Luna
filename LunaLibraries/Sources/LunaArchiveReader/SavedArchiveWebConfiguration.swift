//
//  SavedArchiveWebConfiguration.swift
//  Luna
//

import LunaDesignSystem
import Foundation
import WebKit

/// WebKit policies for creating and replaying saved article archives.
public enum SavedArchiveWebConfiguration {
    /// Capture runs the publisher page long enough to finish layout. Its output is
    /// sanitized before persistence; publisher execution is never needed on replay.
    public static func make(for url: URL) -> WKWebViewConfiguration {
        let configuration = WebJunkBlocker.makeConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.addUserScript(
            PaywallUnlockRules.cleanupUserScript())
        if let siteScript = SiteCleanupScripts.userScript(for: url) {
            configuration.userContentController.addUserScript(siteScript)
        }
        return configuration
    }

    /// Replay is a frozen, offline document. Keeping content JavaScript disabled is
    /// the hard boundary that prevents a legacy publisher bundle, delayed paywall,
    /// or reload from taking ownership of the saved page again.
    public static func makeReplayConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        return configuration
    }

    /// Attaches asynchronous content blockers before the page/archive starts loading.
    @MainActor
    public static func prepare(
        _ configuration: WKWebViewConfiguration, for url: URL
    ) async {
        let controller = configuration.userContentController
        controller.removeAllContentRuleLists()
        if let junk = await WebJunkBlocker.compiledRuleList() {
            controller.add(junk)
        }
        if let paywall = await PaywallUnlockRules.compiledRuleList(for: url) {
            controller.add(paywall)
        }
    }
}

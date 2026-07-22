//
//  SavedArchiveWebConfiguration.swift
//  Luna
//

import LunaDesignSystem
import Foundation
import WebKit

/// The shared WebKit policy for creating and replaying saved article archives.
///
/// JavaScript remains enabled because many publishers install their layout from
/// script, but Luna's generic junk cleanup, paywall cleanup, and site-specific
/// cleanup run around it. Per-host metering/paywall requests and common ad vendors
/// are blocked before the first navigation.
public enum SavedArchiveWebConfiguration {
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

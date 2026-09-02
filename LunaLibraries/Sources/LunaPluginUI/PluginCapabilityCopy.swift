//
//  PluginCapabilityCopy.swift
//  LunaPluginUI
//

import Foundation
import LunaModels
import LunaPluginKit

/// A capability's plain-language sentence for the consent and detail screens.
///
/// The consent screen is the only place a user sees what a plugin may do, so
/// every line says what happens to THEM — "Read and change your saved
/// items", not "grants the storage namespace". `PluginCapabilityName` is
/// `CaseIterable`, so `PluginCapabilityCopyTests` can pin one sentence per
/// case rather than trusting a `default:` branch to stay honest.
public enum PluginCapabilityCopy {

    public static func sentence(for capability: PluginCapabilityName) -> String {
        switch capability {
        case .fetch: return L10n.string("PluginCapability_fetch")
        case .html: return L10n.string("PluginCapability_html")
        case .page: return L10n.string("PluginCapability_page")
        case .storage: return L10n.string("PluginCapability_storage")
        case .secrets: return L10n.string("PluginCapability_secrets")
        case .files: return L10n.string("PluginCapability_files")
        case .crypto: return L10n.string("PluginCapability_crypto")
        case .browser: return L10n.string("PluginCapability_browser")
        case .downloads: return L10n.string("PluginCapability_downloads")
        case .settings: return L10n.string("PluginCapability_settings")
        case .ui: return L10n.string("PluginCapability_ui")
        case .mail: return L10n.string("PluginCapability_mail")
        case .notifications: return L10n.string("PluginCapability_notifications")
        case .bluetooth: return L10n.string("PluginCapability_bluetooth")
        case .wifi: return L10n.string("PluginCapability_wifi")
        case .exports: return L10n.string("PluginCapability_exports")
        }
    }

    /// What consent cannot promise, in the user's own terms (§15).
    /// JavaScriptCore has no watchdog and no interrupt, so a plugin with an
    /// infinite loop keeps running until the process dies. The screen must
    /// not imply Luna can stop a plugin mid-run.
    public static var containmentDisclosure: String {
        L10n.string("Plugins_containmentDisclosure")
    }

    /// One line naming what a plugin returns, for a listing row.
    public static func sentence(for kind: PluginModelKind) -> String {
        switch kind {
        case .article: return L10n.string("Plugins_kindArticle")
        case .media: return L10n.string("Plugins_kindMedia")
        case .product: return L10n.string("Plugins_kindProduct")
        }
    }

    /// The row/consent line for a plugin's status.
    public static func sentence(for status: PluginStatus) -> String {
        switch status {
        case .enabled: return L10n.string("Plugins_statusEnabled")
        case .disabled: return L10n.string("Plugins_statusDisabled")
        case .stopped(let reason): return L10n.string("Plugins_statusStopped", reason)
        case .loadFailed(let message): return L10n.string("Plugins_statusLoadFailed", message)
        }
    }
}

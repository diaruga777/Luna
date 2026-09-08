//
//  MediaBackgroundSessionIdentifier.swift
//  LunaMediaDownload
//

import Foundation

/// Stable identity for one Luna process's media background session.
///
/// A background session belongs to the process that created it, not to the
/// shared App Group. The bundle identifier therefore stays in the session id:
/// the containing app, share extension, action extension, Safari extension, and
/// Live Activity extension can never attach to one another's session
/// accidentally.
public enum MediaBackgroundSessionIdentifier {
    public static let suffix = ".mediaDownload.background.v2"

    private static let embeddedProcessSuffixes = [
        ".share", ".action2", ".safari", ".liveactivity",
    ]

    public static func identifier(forBundleIdentifier bundleIdentifier: String) -> String {
        bundleIdentifier + suffix
    }

    public static var current: String {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            preconditionFailure("A background media session requires a bundle identifier")
        }
        return identifier(forBundleIdentifier: bundleIdentifier)
    }

    static func containingAppBundleIdentifier(
        forProcessBundleIdentifier processBundleIdentifier: String
    ) -> String {
        guard let processSuffix = embeddedProcessSuffixes.first(where: {
            processBundleIdentifier.hasSuffix($0)
        }) else { return processBundleIdentifier }
        return String(processBundleIdentifier.dropLast(processSuffix.count))
    }

    /// The exact session id a containing app may attach when iOS wakes it.
    ///
    /// Central Luna's bundle id is a prefix of every sibling app, so a generic
    /// prefix check would incorrectly accept Downloader's session. Limit the
    /// route to the app itself and the concrete process bundles it can embed.
    public static func routedIdentifier(
        _ identifier: String, containingAppBundleIdentifier: String
    ) -> String? {
        guard identifier.hasSuffix(suffix) else { return nil }
        let processBundleIdentifier = String(identifier.dropLast(suffix.count))
        let belongsToApp = processBundleIdentifier == containingAppBundleIdentifier
            || embeddedProcessSuffixes.contains {
                processBundleIdentifier == containingAppBundleIdentifier + $0
        }
        return belongsToApp ? identifier : nil
    }

    /// Jobs written before process-specific sessions had no value. Treating a
    /// missing value as local keeps in-memory fixtures and an interrupted
    /// schema migration repairable; every new production job is explicit.
    static func includesJob(
        withSessionIdentifier jobSessionIdentifier: String?,
        inSessionIdentifier sessionIdentifier: String
    ) -> Bool {
        jobSessionIdentifier == nil || jobSessionIdentifier == sessionIdentifier
    }
}

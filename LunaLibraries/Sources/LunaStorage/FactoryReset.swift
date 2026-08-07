//
//  FactoryReset.swift
//  LunaStorage
//

import CoreSpotlight
import Foundation
import LunaAppConfig
import Security
import UserNotifications

/// Erases everything this install has ever written: both containers (the app's
/// own and the shared App Group), both defaults domains, every keychain item
/// this process can reach, the notification queue, and the Spotlight index.
/// Reached from Settings → Diagnostics, which is itself behind five taps.
///
/// **It is a file sweep, not a list of stores.** Naming each store here would
/// mean a new store silently surviving the wipe the day someone adds one — and
/// the whole point of the button is that nothing survives. The two containers
/// hold every file any Luna process writes, so emptying them covers the stores
/// that exist today and the ones that don't yet.
///
/// **The other Luna apps are wiped too, and that is intended.** The App Group
/// container and the shared keychain group are one thing shared by four apps;
/// "start over from scratch" cannot mean leaving the sibling's copy of the
/// reading list in place. What is NOT reachable: another app's or extension's
/// *private* container (iOS gives each `.appex` its own, and nothing in Luna
/// keeps state there — extensions write to the App Group precisely so they can
/// be read back) and the Safari web extension's `browser.storage`, which lives
/// inside Safari.
///
/// The caller is expected to TERMINATE the process straight afterwards. Every
/// store in the app is a long-lived singleton holding a decoded cache, and a
/// cache that outlives its file will write it back.
public enum FactoryReset {

    /// Teardown a kind module owns and this one cannot name. The media apps
    /// install an "end every Live Activity" eraser here: an activity outlives
    /// the process that started it, so a wiped download would otherwise keep a
    /// lock-screen card describing itself. Installed by the composition roots
    /// (`KindWiring+*`), like every other cross-tier seam.
    public static var additionalErasers: [() async -> Void] = []

    /// What the sweep did, for the diagnostic line. Deliberately paths and
    /// counts rather than a bool: a wipe that quietly failed on one directory
    /// looks exactly like a wipe that worked.
    public struct Report {
        public var removedPaths: [String] = []
        public var failures: [String] = []

        public var summary: String {
            let removed = "erased \(removedPaths.count) item(s)"
            guard !failures.isEmpty else { return removed }
            return removed + ", \(failures.count) failure(s): " + failures.joined(separator: "; ")
        }
    }

    /// Wipes the install. Call off the main thread — it is unbounded file I/O.
    @discardableResult
    public static func eraseEverything() async -> Report {
        var report = Report()

        for erase in additionalErasers { await erase() }

        await eraseNotifications()
        eraseSpotlightIndex()
        eraseTransientCaches()
        // Defaults BEFORE the files: `removePersistentDomain` empties cfprefsd's
        // in-memory copy, so nothing is left to be flushed back over the plist
        // we are about to delete.
        eraseDefaults()
        eraseKeychain()

        for root in fileRoots() {
            empty(root, into: &report)
        }
        recreateStandardDirectories()

        DiagnosticLog.shared.record("factory reset: \(report.summary)", category: "reset")
        return report
    }

    // MARK: - Files

    /// The directories whose CONTENTS go: the app's own `Documents`, `Library`
    /// and `tmp`, and the whole App Group container.
    ///
    /// Contents rather than the directories themselves — `Documents` and
    /// `Library` are made once, when the container is created, and nothing
    /// recreates them at launch. An app that deleted its own `Documents` would
    /// come back up with every write failing.
    private static func fileRoots() -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        var roots = ["Documents", "Library", "tmp"].map {
            home.appendingPathComponent($0, isDirectory: true)
        }
        if let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConfig.appGroupID) {
            roots.append(group)
        }
        return roots
    }

    /// Container-manager bookkeeping that lives at the root of a container
    /// alongside the app's own directories. Not ours to delete, and the attempt
    /// fails anyway — skipping it keeps the failure list meaningful.
    private static let reservedNames: Set<String> = [
        "SystemData",
        ".com.apple.mobile_container_manager.metadata.plist",
    ]

    /// Removes every child of `directory`. Internal so a test can drive it over
    /// a temporary tree instead of the real container.
    static func empty(_ directory: URL, into report: inout Report) {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants])
        else { return }
        for child in children where !reservedNames.contains(child.lastPathComponent) {
            do {
                try fileManager.removeItem(at: child)
                report.removedPaths.append(child.lastPathComponent)
            } catch {
                report.failures.append(
                    "\(child.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// Puts back the directories the system made at container-creation time and
    /// will not make again. `Library/Caches` in particular: `URLCache` and
    /// friends assume it exists.
    private static func recreateStandardDirectories() {
        let fileManager = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        for path in ["Documents", "Library", "Library/Caches", "Library/Preferences", "tmp"] {
            try? fileManager.createDirectory(
                at: home.appendingPathComponent(path, isDirectory: true),
                withIntermediateDirectories: true)
        }
    }

    // MARK: - Defaults

    /// Both domains: this app's own, and the App Group suite every Luna process
    /// shares. `removePersistentDomain` is the only supported way to empty a
    /// suite — deleting the plist underneath a live `cfprefsd` leaves its cached
    /// values to be written straight back.
    private static func eraseDefaults() {
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        UserDefaults.standard.removePersistentDomain(forName: AppConfig.appGroupID)
        UserDefaults(suiteName: AppConfig.appGroupID)?.removePersistentDomain(
            forName: AppConfig.appGroupID)
    }

    // MARK: - Keychain

    /// Every item class, in every access group this process can reach — its own
    /// private group and the shared App Group one (which is where
    /// `CredentialKeychain` writes). No `kSecAttrAccessGroup` in the query is
    /// what makes it "every reachable group"; `kSecAttrSynchronizableAny` is
    /// what makes it cover the iCloud-Keychain copies too, which is the whole
    /// difference between erasing a credential and hiding it until the next
    /// device syncs it back.
    private static func eraseKeychain() {
        let classes: [CFString] = [
            kSecClassGenericPassword,
            kSecClassInternetPassword,
            kSecClassCertificate,
            kSecClassKey,
            kSecClassIdentity,
        ]
        for itemClass in classes {
            let query: [String: Any] = [
                kSecClass as String: itemClass,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    // MARK: - System-held state

    private static func eraseNotifications() async {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        try? await center.setBadgeCount(0)
    }

    private static func eraseSpotlightIndex() {
        CSSearchableIndex.default().deleteAllSearchableItems(completionHandler: nil)
    }

    /// Caches and cookies the system holds on the app's behalf. Their files sit
    /// in the container and go with it, but both are read through a live
    /// in-memory store that would otherwise keep answering — and, for cookies,
    /// write itself back out.
    private static func eraseTransientCaches() {
        URLCache.shared.removeAllCachedResponses()
        let cookies = HTTPCookieStorage.shared
        for cookie in cookies.cookies ?? [] { cookies.deleteCookie(cookie) }
    }
}

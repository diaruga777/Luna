//
//  SharedSafariURL.swift
//  LunaSafari
//

import Foundation

/// Writes the last-seen Safari URL into the shared App Group defaults.
/// The main app reads these keys via `SafariURLStore` (kept as a separate copy
/// because the extension and app don't share a framework in this small project).
enum SharedSafariURL {
    // Read from the build-injected Info.plist key (see Config/Luna.xcconfig) so the
    // App Group id has a single source of truth shared with the app + other extensions.
    // This target doesn't link the package, so the lookup is inlined here.
    static let appGroupID = SafariAppGroup.id
    static let urlKey = "lastSafariURL"
    static let dateKey = "lastSafariURLDate"
    static let recentHistoryKey = "safariRecentURLHistory.v1"
    static let recentHistoryLimit = 20
    static let sharedSafariSetupKey = "setup.safari.hasRun.shared"
    static let centralSafariSetupKey = "setup.safari.hasRun.luna"
    static let setupStatusDarwinNotification = "\(appGroupID).setupStatusChanged"

    static func record(_ urlString: String) {
        let defaults = UserDefaults(suiteName: appGroupID)
        defaults?.set(urlString, forKey: urlKey)
        defaults?.set(Date().timeIntervalSince1970, forKey: dateKey)
        // Canonicalize BEFORE persisting. A concurrent/older extension can have
        // left repeats in the raw array; a revisit both removes every copy and
        // promotes the surviving value to the front without rewriting Safari's
        // raw URL string.
        var seen: Set<String> = [urlString]
        let remaining = (defaults?.stringArray(forKey: recentHistoryKey) ?? []).filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
        defaults?.set(
            Array(([urlString] + remaining).prefix(recentHistoryLimit)),
            forKey: recentHistoryKey)
    }

    /// Records that this containing app's extension has actually executed.
    /// Reader/Downloader/Price Tracker share completion; bare central Luna is
    /// deliberately independent. `surface` additionally stamps the FIRST such run
    /// per app, which the in-page setup confirmation pairs with the app's own
    /// setup tap.
    static func recordExtensionRun(isCentral: Bool, surface: String) {
        let defaults = UserDefaults(suiteName: appGroupID)
        defaults?.set(true, forKey: isCentral ? centralSafariSetupKey : sharedSafariSetupKey)
        // Only-if-absent: every later run must leave the original moment alone, or
        // "first ran recently" would be true forever.
        if defaults?.object(forKey: firstRunKey(surface)) == nil {
            defaults?.set(Date().timeIntervalSince1970, forKey: firstRunKey(surface))
        }
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(setupStatusDarwinNotification as CFString),
            nil, nil, true)
    }

    // MARK: - The in-page setup confirmation

    /// Mirrors `LunaStorage.LunaSetupStatusStore`'s four keys and its window; this
    /// target links no package (see the note above), so both copies are checked
    /// against each other by `SafariSetupCelebrationTests`.
    static let celebrationWindow: TimeInterval = 24 * 60 * 60

    static func setupTapKey(_ surface: String) -> String { "setup.safari.setupTapAt.\(surface)" }
    static func setupTapAppNameKey(_ surface: String) -> String {
        "setup.safari.setupTapAppName.\(surface)"
    }
    static func firstRunKey(_ surface: String) -> String { "setup.safari.firstRunAt.\(surface)" }
    static func celebrationShownKey(_ surface: String) -> String {
        "setup.safari.celebrationShown.\(surface)"
    }

    /// Whether the content script should take the page over with "You're all set
    /// up" instead of offering its usual pill: this app's setup button was tapped
    /// recently, this app's extension first ran recently, and it has not confirmed
    /// before. `recordExtensionRun` runs first on every request, so by the time the
    /// content script asks, the first-run stamp always exists.
    static func shouldCelebrateSetup(surface: String, now: Date = Date()) -> Bool {
        let defaults = UserDefaults(suiteName: appGroupID)
        guard defaults?.bool(forKey: celebrationShownKey(surface)) != true,
              let tap = storedDate(defaults, setupTapKey(surface)),
              let firstRun = storedDate(defaults, firstRunKey(surface))
        else { return false }
        return isRecent(tap, now: now) && isRecent(firstRun, now: now)
    }

    /// The name of the app to invite the user back to, stamped by that app itself.
    static func setupTapAppName(surface: String) -> String? {
        let name = UserDefaults(suiteName: appGroupID)?
            .string(forKey: setupTapAppNameKey(surface)) ?? ""
        return name.isEmpty ? nil : name
    }

    /// One-shot: the confirmation has now been seen, so it never takes over a page
    /// again. Written when the overlay actually renders, not when it's decided.
    static func recordCelebrationShown(surface: String) {
        UserDefaults(suiteName: appGroupID)?.set(true, forKey: celebrationShownKey(surface))
    }

    private static func isRecent(_ date: Date, now: Date) -> Bool {
        let elapsed = now.timeIntervalSince(date)
        return elapsed >= 0 && elapsed < celebrationWindow
    }

    private static func storedDate(_ defaults: UserDefaults?, _ key: String) -> Date? {
        guard let seconds = defaults?.object(forKey: key) as? Double else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    // The already-unlocked article HTML captured in Safari, handed to the app so it
    // renders that content instead of re-fetching (which would re-lock). The app reads
    // these via `SafariContentStore`, matching the URL and a short freshness window.
    static let unlockedURLKey = "safariUnlockedURL"
    static let unlockedHTMLKey = "safariUnlockedHTML"
    static let unlockedDateKey = "safariUnlockedDate"

    static func recordUnlockedContent(_ urlString: String, html: String) {
        let defaults = UserDefaults(suiteName: appGroupID)
        defaults?.set(urlString, forKey: unlockedURLKey)
        defaults?.set(html, forKey: unlockedHTMLKey)
        defaults?.set(Date().timeIntervalSince1970, forKey: unlockedDateKey)
    }
}

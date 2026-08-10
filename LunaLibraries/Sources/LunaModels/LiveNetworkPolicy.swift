//
//  LiveNetworkPolicy.swift
//  LunaModels
//

import Foundation

/// The ONE answer to "may this process talk to a real server?", consulted by
/// every live-network entry point in the codebase.
///
/// **Why it exists.** Luna's seams are injected closures and installed
/// singletons, and several of them are filled at LAUNCH — the test host is the
/// central Luna app, so `SellerComparisonRunner.installed`, the ingest
/// processors and the price fetchers are all live inside `LunaTests`. Nothing
/// structural stopped a test that drives a save from putting real retailer
/// traffic behind an assertion: it would pass, slowly, and depend on a
/// stranger's web server. That is the class of problem this closes, rather than
/// any one instance of it.
///
/// **The rule.** Live traffic is REFUSED whenever the process is running under
/// XCTest (`XCTestConfigurationFilePath` in the environment), unless one of the
/// opt-in environment variables is set. Outside XCTest — the shipping app, its
/// extensions, the clips, the widget — it is always permitted, and the check
/// costs one cached `Bool` read.
///
/// **A refusal is fast and loud, never slow.** The point is that a test which
/// forgot to stub fails immediately with an explanation, rather than timing out
/// after 20 s or (worse) succeeding against the live web. So every entry point
/// checks BEFORE building its request, the refusal is logged with the call site
/// and the URL, and it is recorded in `recordedRefusals` so a test can assert on
/// it directly (`XCTAssertNoLiveNetworkRefusals`).
public enum LiveNetworkPolicy {

    /// Whether this process is a test runner.
    ///
    /// Deliberately OUTSIDE the DEBUG block below: "am I a test host?" has more
    /// than one caller now, and every one of them wants the same answer. The
    /// test host is the central Luna app, so anything the app arms at launch is
    /// armed inside `LunaTests` too — live network was the first thing that had
    /// to be refused on that basis, and background work the app starts by itself
    /// (`BackgroundIngestCompletion`) is the second: a real ingest running
    /// unbidden mid-suite contends with the very WebKit the capture tests drive.
    /// In a Release build it simply answers false.
    public static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    #if DEBUG
    // MARK: - The decision
    //
    // Everything below exists to answer `isLiveNetworkAllowed` and to let a
    // test inspect what got refused. None of it ships in a Release build:
    // outside DEBUG, `allows`/`check` (the only entry points production code
    // calls) always permit — there is no test process to refuse on behalf
    // of, so the whole apparatus would be dead weight in the shipping binary.

    /// Set this to permit live traffic from a test process — the general opt-in
    /// every deliberately-live test should use.
    public static let optInEnvironmentKey = "LUNA_ALLOW_LIVE_NETWORK"

    /// The pre-existing per-suite live gates, kept working by routing them
    /// through the SAME opt-in rather than leaving a second mechanism that could
    /// drift from this one (`SocialMediaResolverTests`' live YouTube transfers).
    public static let legacyOptInEnvironmentKeys = [
        "RUN_LIVE_YOUTUBE_TESTS",
        "RUN_LIVE_YOUTUBE_BACKGROUND_TESTS",
    ]

    /// Whether a live-network opt-in is set in the environment.
    public static var isOptedIn: Bool {
        ([optInEnvironmentKey] + legacyOptInEnvironmentKeys).contains { isOptedIn(key: $0) }
    }

    /// Whether ONE named opt-in key is set (`"1"` / `"true"` / `"yes"`). The
    /// live-test suites gate themselves on this so their skip condition and the
    /// policy's permission can never disagree.
    public static func isOptedIn(key: String) -> Bool {
        guard let raw = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return raw == "1" || raw == "true" || raw == "yes"
    }

    /// Whether live network traffic is permitted right now.
    ///
    /// Cached: the environment cannot change under a running process, and this
    /// is consulted on every fetch. `overrideForTesting` is the one way to move
    /// it, and only a test can reach that.
    public static var isLiveNetworkAllowed: Bool {
        if let overrideForTesting { return overrideForTesting }
        return cachedDefaultDecision
    }

    private static let cachedDefaultDecision: Bool = !isRunningUnderXCTest || isOptedIn

    /// Test seam: forces the answer for one test, e.g. to pin the refusal path
    /// itself. Always restore it in `tearDown`.
    nonisolated(unsafe) public static var overrideForTesting: Bool?

    // MARK: - Refusal

    /// Thrown (or logged) when live traffic is refused. Carries the call site so
    /// the failure explains itself without a stack trace.
    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public let context: String
        public let urlString: String

        public init(context: String, urlString: String) {
            self.context = context
            self.urlString = urlString
        }

        public var description: String {
            """
            Live network refused in a test process: \(context) tried to reach \
            \(urlString). Stub this dependency, or set \
            \(LiveNetworkPolicy.optInEnvironmentKey)=1 for a deliberately live test.
            """
        }
    }

    // MARK: - Bookkeeping

    private static let lock = NSLock()
    nonisolated(unsafe) private static var refusals: [Refusal] = []

    /// Every refusal this process has recorded, oldest first.
    public static var recordedRefusals: [Refusal] {
        lock.lock()
        defer { lock.unlock() }
        return refusals
    }

    /// Drops the recorded refusals (a test's `setUp`).
    public static func resetRecordedRefusals() {
        lock.lock()
        refusals.removeAll()
        lock.unlock()
    }

    @discardableResult
    private static func record(context: String, url: URL?) -> Refusal {
        let refusal = Refusal(context: context, urlString: url?.absoluteString ?? "<no url>")
        lock.lock()
        refusals.append(refusal)
        lock.unlock()
        NSLog("[LunaLiveNetworkPolicy] %@", refusal.description)
        return refusal
    }
    #endif

    // MARK: - The check
    //
    // The only two entry points production code calls, so they stay available
    // unconditionally — in DEBUG they consult the decision above; in Release
    // there is nothing to consult, so they simply permit.

    /// The throwing form, for entry points that already propagate errors.
    public static func check(_ url: URL?, context: String) throws {
        #if DEBUG
        guard !isLiveNetworkAllowed else { return }
        throw record(context: context, url: url)
        #endif
    }

    /// The boolean form, for entry points whose failure mode is `nil`. Returns
    /// false — having already recorded and logged the refusal — when live
    /// traffic is not permitted.
    public static func allows(_ url: URL?, context: String) -> Bool {
        #if DEBUG
        guard !isLiveNetworkAllowed else { return true }
        _ = record(context: context, url: url)
        return false
        #else
        return true
        #endif
    }
}

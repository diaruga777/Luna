//
//  NotificationAuthorizationCallSiteTests.swift
//  LunaTests
//

import XCTest

/// Luna asks for notification authorization in exactly THREE places, and launch is
/// not one of them: pasting the Save of the Week key, connecting a sending account,
/// and committing a price alert threshold. Each is the moment a user opts into the
/// one thing Luna will notify them about (proposals, incoming shares, price drops),
/// so the prompt always arrives with its reason already on screen.
///
/// The rule can't be enforced by types — `NotificationManager.requestAuthorization()`
/// is public and callable from anywhere — and the failure mode is invisible in code
/// review: a stray call at launch or in some unrelated setup flow spends a ONE-TIME
/// system decision before the user has any reason to say yes, and the only symptom is
/// a permission prompt on a fresh install. So the call sites are pinned by scanning
/// the sources, the same way `PlatformHostsJSFixtureParityTests` pins the Safari
/// resources. Adding a legitimate fourth moment means editing `expectedCallSites`
/// here plus the policy paragraph in `CLAUDE.md`.
final class NotificationAuthorizationCallSiteTests: XCTestCase {

    /// Repo-relative path → how many `requestAuthorization()` calls it may contain.
    private static let expectedCallSites: [String: Int] = [
        // (1) The weekly key: this device becomes a proposal recipient.
        "Luna/Diagnostics/DiagnosticsViewController.swift": 1,
        // (2) Connecting a sending account — both credential paths.
        "Luna/Mail/CredentialViewController.swift": 1,
        "Luna/Mail/EmailAccountSetup.swift": 1,
        // (3) Committing a price alert threshold. There are three ways to ask
        // for one — the graph's line, the alert row's slider, and the "set an
        // alert at all" offer either makes when there is none — and one product
        // surface behind all of them, so they funnel through one call.
        "LunaLibraries/Sources/LunaPriceUI/ProductDetailViewController.swift": 1,
    ]

    /// Where the function is DEFINED — excluded from the call-site scan.
    private static let definitionFile =
        "LunaLibraries/Sources/LunaSocial/NotificationManager.swift"

    /// Normalized, and so is every enumerated URL below. `#filePath` is
    /// whatever path the compiler was handed while the enumerator reports the
    /// real one, and under a symlinked checkout (a worktree in `/tmp`, which is
    /// `/private/tmp`) those differ — the prefix strip then leaves `/privateLuna
    /// /...` and every call site reads as new. `resolvingSymlinksInPath` is the
    /// normalizer, and it is only correct applied to BOTH ends.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
    }

    func testRequestAuthorizationIsCalledOnlyFromTheThreeOptInMoments() throws {
        let found = try Self.scanForCallSites()
        XCTAssertEqual(
            found, Self.expectedCallSites,
            """
            The set of NotificationManager.requestAuthorization() call sites changed.
            Luna asks in exactly three moments (weekly key, email sign-in, price alert
            threshold) and never at launch. If you added a real fourth reason to ask,
            update expectedCallSites AND the policy note in CLAUDE.md; if this fired on
            an AppDelegate/launch path, that call is the bug.
            """)
    }

    /// The definition still exists where the scan expects it (so a rename can't turn
    /// this suite into a test that silently passes over zero files).
    func testDefinitionFileStillDeclaresRequestAuthorization() throws {
        let source = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(Self.definitionFile),
            encoding: .utf8)
        XCTAssertTrue(
            source.contains("public static func requestAuthorization()"),
            "NotificationManager.requestAuthorization() moved or was renamed — "
                + "update definitionFile and the call-site scan.")
    }

    /// An extension process can't honestly own the one-time prompt, so the guard in
    /// `NotificationManager` is part of the policy, not an implementation detail: the
    /// price editor is reachable from the share and action sheets.
    func testDefinitionSkipsExtensionProcesses() throws {
        let source = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(Self.definitionFile),
            encoding: .utf8)
        XCTAssertTrue(
            source.contains("guard !isAppExtension else"),
            "requestAuthorization() lost its app-extension guard — a threshold set in "
                + "the share sheet would spend the prompt on a dismissing surface.")
        XCTAssertTrue(
            source.contains("Bundle.main.bundleURL.pathExtension == \"appex\""),
            "isAppExtension no longer checks the bundle's .appex suffix — the guard "
                + "above would be deciding from something else.")
    }

    // MARK: - Scan

    private static func scanForCallSites() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for directory in ["Luna", "LunaLibraries/Sources"] {
            let root = repoRoot.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil) else {
                XCTFail("couldn't enumerate \(directory)")
                continue
            }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let relative = url.resolvingSymlinksInPath().path.replacingOccurrences(
                    of: repoRoot.path + "/", with: "")
                guard relative != definitionFile else { continue }
                let source = try String(contentsOf: url, encoding: .utf8)
                let hits = source.components(separatedBy: "requestAuthorization()").count - 1
                if hits > 0 { counts[relative] = hits }
            }
        }
        return counts
    }
}

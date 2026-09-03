import LunaModels
import LunaPluginKit
import LunaURLClassification
import XCTest

final class PluginRecoveryHandoffTests: XCTestCase {
    func testHandoffKeepsPrivateURLLocalAndRequiresMatchingCaseLink() throws {
        let suite = "plugin-recovery-handoff-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PluginRecoveryHandoffStore(defaults: defaults)
        let id = UUID()
        let recoveryCase = PluginRecoveryCase(
            caseID: id,
            originalURL: "https://example.com/story?token=secret", outcome: "failed")
        let liveURL = try XCTUnwrap(URL(string: "https://example.com/story?token=secret"))

        XCTAssertTrue(store.record(recoveryCase, validationURL: liveURL))
        XCTAssertNil(store.take(caseID: UUID()), "a stale tab must not consume a newer handoff")
        let handoff = try XCTUnwrap(store.take(caseID: id))
        XCTAssertFalse(handoff.recoveryCase.originalURL.contains("secret"))
        XCTAssertTrue(handoff.validationURL.contains("secret"))
        XCTAssertNil(store.peek())
    }

    func testRecoveryDeepLinkCarriesOnlyTheCaseIdentifier() throws {
        let id = UUID()
        let link = try XCTUnwrap(LunaDeepLink.pluginRecoveryLink(caseID: id))

        XCTAssertEqual(LunaDeepLink.pluginRecoveryCaseID(from: link), id)
        XCTAssertFalse(link.absoluteString.contains("example.com"))
        XCTAssertNil(LunaDeepLink.pluginRecoveryCaseID(from:
            try XCTUnwrap(URL(string: "luna://pluginrecovery?case=not-a-uuid"))))
    }
}

import XCTest
import LunaCodeCore
@testable import LunaCodeMac

final class CodeMacCatalogTests: XCTestCase {
    func testSixDayCadenceDependsOnConfirmedInstallation() {
        let now = Date(timeIntervalSince1970: 2000000)
        var target = CodeMacTarget(name: "App", project: CodeProject(path: "/repo/App.xcodeproj", scheme: "App"), deviceID: "phone", enabled: true)
        XCTAssertTrue(target.isDue(at: now))
        target.lastAttempt = now.addingTimeInterval(-60); XCTAssertFalse(target.isDue(at: now))
        target.lastAttempt = now.addingTimeInterval(-1801); XCTAssertTrue(target.isDue(at: now))
        target.lastSuccess = now.addingTimeInterval(-143 * 3600); XCTAssertFalse(target.isDue(at: now))
        target.lastSuccess = now.addingTimeInterval(-144 * 3600); XCTAssertTrue(target.isDue(at: now))
        target.jobID = "retained-job"; XCTAssertFalse(target.isDue(at: now))
    }
    func testPendingRequestAndSigningPolicySurviveRestart() throws {
        var project = CodeProject(path: "/repo/App.xcodeproj", scheme: "App")
        project.developmentTeam = "USERS_TEAM"; project.minimumProfileHours = 156
        var target = CodeMacTarget(name: "App", project: project, deviceID: "phone")
        target.pendingRequest = CodeRequest(.overnightSubmit)
        let decoded = try JSONDecoder().decode(CodeMacTarget.self, from: JSONEncoder().encode(target))
        XCTAssertEqual(decoded.pendingRequest?.id, target.pendingRequest?.id)
        XCTAssertEqual(decoded.project.developmentTeam, "USERS_TEAM")
        XCTAssertEqual(decoded.project.minimumProfileHours, 156)
        XCTAssertTrue(decoded.project.xcodeArguments.contains("DEVELOPMENT_TEAM=USERS_TEAM"))
    }
    func testGitHubInputCannotBecomeAnArbitraryCloneURL() throws {
        XCTAssertEqual(try CodeMacGitHub.repository("https://github.com/example/app.git"), "example/app")
        XCTAssertEqual(try CodeMacGitHub.repository("example/app"), "example/app")
        for input in ["https://evil.example/app", "https://github.com@evil.example/app", "../app", "owner/../app", "owner/app/extra", "--upload-pack=bad", "file:///tmp/repo", "https://user:password@github.com/owner/app"] {
            XCTAssertThrowsError(try CodeMacGitHub.repository(input), input)
        }
    }
    func testAddRequiresTrustBeforeInvokingXcode() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let host = try CodeMacHost(root: root)
        let data = await host.handle(Data(#"{"method":"target_add","params":{"project":"/tmp/App.xcodeproj","scheme":"App","deviceID":"phone"}}"#.utf8))
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertTrue((value?["error"] as? String)?.contains("trust=true") == true)
    }
    func testProfileRotationOnlySelectsMatchingExpiringAutomaticDevelopmentProfile() {
        let now = Date()
        let profile: [String: Any] = ["ExpirationDate": now.addingTimeInterval(3600), "TeamIdentifier": ["TEAM"], "ProvisionedDevices": ["phone"], "Entitlements": ["get-task-allow": true, "application-identifier": "TEAM.com.example.app"]]
        XCTAssertTrue(CodeProfileRefresh.matches(profile, bundle: "com.example.app", team: "TEAM", device: "phone", minimumHours: 156, at: now))
        XCTAssertFalse(CodeProfileRefresh.matches(profile, bundle: "com.other.app", team: "TEAM", device: "phone", minimumHours: 156, at: now))
        XCTAssertFalse(CodeProfileRefresh.matches(profile, bundle: "com.example.app", team: "OTHER", device: "phone", minimumHours: 156, at: now))
        XCTAssertFalse(CodeProfileRefresh.matches(profile, bundle: "com.example.app", team: "TEAM", device: "different-phone", minimumHours: 156, at: now))
        var fresh = profile; fresh["ExpirationDate"] = now.addingTimeInterval(168 * 3600)
        XCTAssertFalse(CodeProfileRefresh.matches(fresh, bundle: "com.example.app", team: "TEAM", device: "phone", minimumHours: 156, at: now))
    }

    func testSecondCatalogCannotOwnSameStateDirectory() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var host: CodeMacHost? = try CodeMacHost(root: root)
        XCTAssertNotNil(host)
        XCTAssertThrowsError(try CodeMacHost(root: root))
        host = nil
        XCTAssertNoThrow(try CodeMacHost(root: root))
    }
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
}

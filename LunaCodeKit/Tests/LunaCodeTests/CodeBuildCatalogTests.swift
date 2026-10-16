import XCTest
@testable import LunaCodeCore
@testable import LunaCodeMac

final class CodeBuildCatalogTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUp() { suite = UUID().uuidString; defaults = UserDefaults(suiteName: suite)! }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testCacheSurvivesRelaunchAndRefreshPreservesRowSettings() {
        let catalog = CodeBuildCatalog(defaults: defaults)
        var reader = CodeBuildApp(project: CodeProject(path: "/Luna/Luna.xcodeproj", scheme: "Reader"), name: "Reader", bundleID: "reader", branch: "feature/reader", deviceID: "phone")
        reader.jobID = "job"
        let code = CodeBuildApp(project: CodeProject(path: "/Luna/Luna.xcodeproj", scheme: "Code"), name: "Code", bundleID: "code")
        let other = CodeBuildApp(project: CodeProject(path: "/Other/Other.xcodeproj", scheme: "Other"), name: "Other", bundleID: "other")
        catalog.save([reader, code, other], peer: "mac")
        catalog.selectedTab = 1; catalog.setDefaultDevice("phone", peer: "mac")
        var refreshed = reader; refreshed.project.scheme = "ReaderDefault"; refreshed.name = "Luna Reader"; refreshed.branch = "main"; refreshed.deviceID = nil; refreshed.jobID = nil
        catalog.merge([refreshed, code], path: reader.project.path, peer: "mac")
        let restored = CodeBuildCatalog(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(restored.selectedTab, 1)
        XCTAssertEqual(restored.defaultDevice(peer: "mac"), "phone")
        let row = restored.apps(peer: "mac").first { $0.bundleID == "reader" }
        XCTAssertEqual(row?.project.scheme, "Reader"); XCTAssertEqual(row?.name, "Luna Reader"); XCTAssertEqual(row?.branch, "feature/reader")
        XCTAssertEqual(row?.deviceID, "phone"); XCTAssertEqual(row?.jobID, "job")
        XCTAssertEqual(restored.apps(peer: "mac").count, 3)
        XCTAssertTrue(restored.apps(peer: "anotherMac").isEmpty)
        XCTAssertNil(restored.defaultDevice(peer: "anotherMac"))
    }
    func testOpeningSeveralProjectsRetainsHistoryWithoutChangingSelectedProject() {
        let session = CodeSessionStore(defaults: defaults)
        let one = CodeProject(path: "/One/App.xcodeproj", scheme: "One")
        let two = CodeProject(path: "/Two/App.xcodeproj", scheme: "Two")
        session.setProject(one, peer: "mac"); session.setProject(two, peer: "mac")
        session.setProject(one, peer: "mac")
        XCTAssertEqual(session.recentProjects(peer: "mac"), [one, two])
        XCTAssertTrue(session.recentProjects(peer: "other").isEmpty)
        CodeBuildCatalog(defaults: defaults).save([CodeBuildApp(project: two, name: "Two", bundleID: "two")], peer: "mac")
        XCTAssertEqual(session.project(peer: "mac"), one)
    }
    func testCurrentPhoneSelectionRequiresUniqueMatchAndNeverReplacesSavedPhone() {
        let current = CodeDevice(id: "current", name: "My Phone")
        let other = CodeDevice(id: "other", name: "Other")
        XCTAssertEqual(CodeBuildCatalog.resolveDevice([other, current], preferred: nil, currentName: "My Phone"), current)
        XCTAssertNil(CodeBuildCatalog.resolveDevice([other, current], preferred: nil, currentName: "iPhone"))
        XCTAssertNil(CodeBuildCatalog.resolveDevice([other], preferred: "current", currentName: "Other"))
        XCTAssertEqual(CodeBuildCatalog.resolveDevice([other], preferred: nil, currentName: "iPhone"), other)
        XCTAssertNil(CodeBuildCatalog.resolveDevice([], preferred: nil, currentName: "iPhone"))
    }
    func testDeviceDiscoveryIncludesIdlePairedPhonesAndExcludesUnavailableAndSimulators() throws {
        let data = Data(#"{"result":{"devices":[{"properties":{"hardware":{"reality":"physical","platform":"iOS","udid":"phone"},"state":{"name":"Phone"},"connection":{"state":"connected"}}},{"hardwareProperties":{"reality":"physical","platform":"iOS","udid":"legacy"},"deviceProperties":{"name":"Legacy"},"connectionProperties":{"tunnelState":"disconnected","pairingState":"paired"}},{"properties":{"hardware":{"reality":"simulated","platform":"iOS","udid":"sim"},"state":{"name":"Simulator"},"connection":{"state":"connected"}}},{"properties":{"hardware":{"reality":"physical","platform":"iOS","udid":"offline"},"state":{"name":"Offline"},"connection":{"state":"unavailable"}}},{"properties":{"hardware":{"reality":"physical","platform":"tvOS","udid":"tv"},"state":{"name":"TV"},"connection":{"state":"connected"}}}]}}"#.utf8)
        XCTAssertEqual(try CodeDeviceSupport.parseDevices(data).map(\.id), ["legacy", "phone"])
    }
    func testBuildOptionsRoundTripAndOldRequestsStillDecode() throws {
        var request = CodeRequest(.runOnDevice); request.project = CodeProject(path: "/App.xcodeproj", scheme: "App")
        request.deviceBuild = CodeDeviceBuild(deviceID: "phone")
        let decoded = try JSONDecoder().decode(CodeRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.deviceBuild?.branch, "main")
        XCTAssertEqual(decoded.deviceBuild?.deviceID, "phone")
        request = CodeRequest(.build)
        let legacy = try JSONDecoder().decode(CodeRequest.self, from: JSONEncoder().encode(request))
        XCTAssertNil(legacy.deviceBuild)
    }
    func testProcessAppendsCommandsToJobLog() async throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: log) }
        let process = CodeProcess()
        _ = try await process.run("/bin/echo", ["first"], directory: "/tmp", log: log)
        _ = try await process.run("/bin/echo", ["second"], directory: "/tmp", log: log)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "first\nsecond\n")
    }
    func testMainCheckoutPreservesDirtyEditorBranchAndCleansUp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("Repo")
        let state = root.appendingPathComponent("State")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        func git(_ args: [String]) async throws -> String {
            try await CodeDeviceSupport.git(args, directory: repository.path, root: state)
        }
        _ = try await git(["init", "-b", "main"])
        _ = try await git(["config", "user.name", "Luna Tests"])
        _ = try await git(["config", "user.email", "luna@example.invalid"])
        let projectPath = repository.appendingPathComponent("App.xcodeproj")
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)
        try Data("main project".utf8).write(to: projectPath.appendingPathComponent("project.pbxproj"))
        let source = repository.appendingPathComponent("Source.swift")
        try Data("main source".utf8).write(to: source)
        _ = try await git(["add", "."]); _ = try await git(["commit", "-m", "main"])
        _ = try await git(["checkout", "-b", "editor"])
        try Data("unsaved Mac edits".utf8).write(to: source)
        let originalStatus = try await git(["status", "--porcelain"])
        let checkout = try await CodeDeviceCheckout.create(project: CodeProject(path: projectPath.path, scheme: "App"), branch: "main", root: state, name: UUID().uuidString)
        XCTAssertEqual(try String(contentsOf: checkout.directory.appendingPathComponent("Source.swift"), encoding: .utf8), "main source")
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkout.project.path))
        let branch = try await git(["branch", "--show-current"])
        XCTAssertEqual(branch, "editor")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "unsaved Mac edits")
        let status = try await git(["status", "--porcelain"])
        XCTAssertEqual(status, originalStatus)
        await checkout.remove(root: state)
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkout.directory.path))
        do {
            _ = try await CodeDeviceCheckout.create(project: CodeProject(path: projectPath.path, scheme: "App"), branch: "--help", root: state, name: UUID().uuidString)
            XCTFail("Option-shaped refs must not become git options")
        } catch {}
    }

    func testXcodeJSONIgnoresWarningBracketsAndPackageProgress() throws {
        let output = Data("2026-10-16 [MT] warning: no destinations\nResolved packages: Support\n[{\"buildSettings\":{\"PRODUCT_TYPE\":\"app\"}}]\n".utf8)
        let parsed = try CodeDeviceSupport.parseJSONOutput(output) as? [[String: Any]]
        XCTAssertEqual((parsed?.first?["buildSettings"] as? [String: String])?["PRODUCT_TYPE"], "app")
    }

}

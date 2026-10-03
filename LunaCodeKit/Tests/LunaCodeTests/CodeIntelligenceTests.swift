import XCTest
@testable import LunaCodeCore
@testable import LunaCodeMac

final class CodeIntelligenceTests: XCTestCase {
    /// Opt-in integration test uses a disposable Xcode fixture built by
    /// scripts/test_code_intelligence.sh, never a user's working project.
    func testUIKitAndExternalModuleCompletionAndUnsavedDiagnostic() async throws {
        guard let root = ProcessInfo.processInfo.environment["LUNA_CODE_INTELLIGENCE_FIXTURE"] else { throw XCTSkip("Run scripts/test_code_intelligence.sh for the live Xcode integration.") }
        let project = CodeProject(path: root + "/Fixture.xcodeproj", scheme: "Fixture")
        let server = try CodeLanguageServer(project: project, derivedData: URL(fileURLWithPath: root + "/DerivedData"), logs: URL(fileURLWithPath: root))
        try await server.initialize(project: project)
        let path = root + "/Main.swift"
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        var text = "import UIKit\nimport FixtureSupport\nlet label = UILabel()\nlabel."
        try server.update(path: path, text: text, version: 1)
        var uikit: [CodeCompletion] = []
        for attempt in 0..<10 {
            try server.update(path: path, text: text + String(repeating: "\n", count: attempt), version: attempt + 1)
            _ = try await server.diagnostics(path: path)
            uikit = try await server.complete(path: path, position: CodePosition(line: 3, character: 6))
            if uikit.contains(where: { $0.label.contains("textColor") }) { break }
            try await Task.sleep(for: .seconds(1))
        }
        XCTAssertTrue(uikit.contains(where: { $0.label.contains("textColor") }), "UIKit completions: \(uikit.map(\.label).prefix(20))")
        text = "import UIKit\nimport FixtureSupport\nlet store = FixtureStore()\nstore."
        try server.update(path: path, text: text, version: 20)
        let external = try await server.complete(path: path, position: CodePosition(line: 3, character: 6))
        XCTAssertTrue(external.contains(where: { $0.label.contains("recordCount") }), "External completions: \(external.map(\.label))")
        try server.update(path: path, text: "import UIKit\nlet value: Int = \"wrong\"\n", version: 30)
        let diagnostics = try await server.diagnostics(path: path)
        XCTAssertTrue(diagnostics.contains(where: { $0.message.contains("String") && $0.message.contains("Int") }), "Diagnostics: \(diagnostics)")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original, "Unsaved buffers must not alter Mac files")
    }
}

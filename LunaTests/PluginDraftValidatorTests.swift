import LunaModels
import LunaPluginIngest
import LunaPluginKit
import XCTest

final class PluginDraftValidatorTests: XCTestCase {
    func testNormalizerAcceptsOneOuterJavaScriptFence() throws {
        XCTAssertEqual(
            try PluginDraftSource.normalize("```javascript\nlet answer = 1;\n```"),
            "let answer = 1;")
    }

    func testNormalizerRefusesProseAndCodeBlocks() {
        XCTAssertThrowsError(try PluginDraftSource.normalize("Here you go\n```js\nlet x = 1\n```"))
        XCTAssertThrowsError(try PluginDraftSource.normalize("```js\na\n```\n```js\nb\n```"))
    }

    func testValidatorRunsClassifyAndIngestAgainstTheTargetCase() async {
        let report = await PluginDraftValidator.validate(
            sourceText: source(classify: "{ kind: 'article' }", ingest: """
            { kind: 'article', title: 'Recovered', html: '<p>Readable body</p>' }
            """),
            recoveryCase: recoveryCase())
        XCTAssertTrue(report.passed, report.errors.joined(separator: "\n"))
        XCTAssertEqual(report.modelKind, "article")
    }

    func testValidatorExplainsATargetDecline() async {
        let report = await PluginDraftValidator.validate(
            sourceText: source(classify: "false", ingest: "null"),
            recoveryCase: recoveryCase())
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.errors.joined().contains("declined"))
    }

    private func recoveryCase() -> PluginRecoveryCase {
        PluginRecoveryCase(
            originalURL: "https://example.com/story", outcome: "failed")
    }

    private func source(classify: String, ingest: String) -> String {
        """
        /* luna-plugin
        {"id":"user.test.recovery","name":"Recovery","version":"1.0.0","api":1,"produces":["article"],"match":{"hosts":["example.com"]},"capabilities":[]}
        */
        luna.register({
          classify() { return \(classify); },
          async ingest() { return \(ingest); }
        });
        """
    }
}

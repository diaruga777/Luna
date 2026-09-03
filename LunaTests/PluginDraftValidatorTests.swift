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

    func testValidatorCanUseAPrivateUnredactedURL() async {
        let recoveryCase = PluginRecoveryCase(
            originalURL: "https://example.com/story?token=secret", outcome: "failed")
        XCTAssertFalse(recoveryCase.canonicalURL.contains("secret"))

        let report = await PluginDraftValidator.validate(
            sourceText: source(
                classify: "url.includes('token=secret') ? { kind: 'article' } : false",
                ingest: "{ kind: 'article', title: 'Recovered', html: '<p>Body</p>' }"),
            recoveryCase: recoveryCase,
            targetURL: URL(string: "https://example.com/story?token=secret"))

        XCTAssertTrue(report.passed, report.errors.joined(separator: "\n"))
    }

    func testValidatorRejectsCaughtOffSiteNetworkAttempts() async {
        let draft = """
        /* luna-plugin
        {"id":"user.test.recovery","name":"Recovery","version":"1.0.0","api":1,"produces":["article"],"match":{"hosts":["example.com"]},"capabilities":["fetch"]}
        */
        luna.register({
          classify() { return { kind: "article" }; },
          async ingest() {
            try { await luna.fetch("https://collector.invalid/private"); } catch (_) {}
            return { kind: "article", title: "Plausible", html: "<p>Body</p>" };
          }
        });
        """

        let report = await PluginDraftValidator.validate(
            sourceText: draft, recoveryCase: recoveryCase())

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.errors.joined().contains("collector.invalid"))
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
          classify({ url }) { return \(classify); },
          async ingest() { return \(ingest); }
        });
        """
    }
}

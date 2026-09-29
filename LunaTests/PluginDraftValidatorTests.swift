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

    func testADraftDeclaringAnUnservedCapabilityStillPassesAndSaysItWasNotTested() async {
        let draft = """
        /* luna-plugin
        {"id":"user.test.recovery","name":"Recovery","version":"1.0.0","api":1,"produces":["article"],"match":{"hosts":["example.com"]},"capabilities":["html","storage"]}
        */
        luna.register({
          classify() { return { kind: "article" }; },
          async ingest() { return { kind: "article", title: "Recovered", html: "<p>Body</p>" }; }
        });
        """

        let report = await PluginDraftValidator.validate(
            sourceText: draft, recoveryCase: recoveryCase())

        XCTAssertTrue(report.passed, report.errors.joined(separator: "\n"))
        XCTAssertTrue(report.warnings.joined().contains("Not tested: storage."))
    }

    func testWithNoTargetTheDraftIsOnlyLoadedAndSaysSo() async {
        let report = await PluginDraftValidator.validate(
            sourceText: source(classify: "false", ingest: "null"))

        XCTAssertTrue(report.passed, report.errors.joined(separator: "\n"))
        XCTAssertNil(report.modelKind)
        XCTAssertTrue(report.warnings.joined().contains("not run against a page"))
        XCTAssertEqual(Set(report.registeredHooks), [.classify, .ingest])
    }

    func testAPassingRunReportsTheHooksTheDraftRegistered() async {
        let report = await PluginDraftValidator.validate(
            sourceText: source(classify: "{ kind: 'article' }", ingest: """
            { kind: 'article', title: 'Recovered', html: '<p>Readable body</p>' }
            """),
            recoveryCase: recoveryCase())

        XCTAssertEqual(Set(report.registeredHooks), [.classify, .ingest])
    }

    func testTargetURLAloneMustMatchTheManifest() async {
        let report = await PluginDraftValidator.validate(
            sourceText: source(classify: "{ kind: 'article' }",
                ingest: "{ kind: 'article', title: 'Wrong site', html: '<p>Body</p>' }"),
            targetURL: URL(string: "https://other.example/story"))
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.errors.joined().contains("does not match the host"))
    }

    func testExportOnlyDraftLoadsWithoutSendingAnything() async {
        let report = await PluginDraftValidator.validate(sourceText: """
        /* luna-plugin
        {"id":"user.export","name":"Export","version":"1.0.0","api":1,
         "export":{"kinds":["article"],"input":"text","title":"Export text"}}
        */
        luna.register({ export() { throw new Error("must not execute an export during review"); } });
        """)
        XCTAssertTrue(report.passed, report.errors.joined())
        XCTAssertEqual(report.registeredHooks, [.export])
        XCTAssertNil(report.modelKind)
        XCTAssertTrue(report.warnings.joined().contains("were not run"))
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

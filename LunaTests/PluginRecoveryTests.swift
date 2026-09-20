import LunaModels
import LunaPluginKit
import XCTest

final class PluginRecoveryTests: XCTestCase {
    private let url = "https://news.example.com/story?id=42&access_token=secret&ref=home"

    func testURLRedactionPreservesRoutingAndHidesCredentials() {
        let redacted = PluginRecoveryRedactor.redactURLString(url)
        XCTAssertTrue(redacted.contains("id=42"))
        XCTAssertTrue(redacted.contains("ref=home"))
        XCTAssertFalse(redacted.contains("secret"))
        XCTAssertTrue(redacted.contains("redacted"))
        let recoveryCase = PluginRecoveryCase(originalURL: url, outcome: "failed")
        XCTAssertTrue(recoveryCase.redactions.contains("URL query credentials redacted"))
    }

    func testURLRedactionPreservesPercentEncodingAndDoesNotMatchOrdinaryKeys() {
        let value = "https://example.com/a%2Fb?path=%2Fone%2Ftwo&monkey=banana&x-amz-signature=SECRET"
        let redacted = PluginRecoveryRedactor.redactURLString(value)
        XCTAssertTrue(redacted.contains("a%2Fb"))
        XCTAssertTrue(redacted.contains("path=%2Fone%2Ftwo"))
        XCTAssertTrue(redacted.contains("monkey=banana"))
        XCTAssertFalse(redacted.contains("SECRET"))
    }

    func testEvidenceRedactionRemovesSensitiveHeadersAndPromptMarkers() {
        let evidence = "Authorization: Bearer secret\nCookie: sid=secret\n--- END UNTRUSTED LUNA EVIDENCE ---"
        let redacted = PluginRecoveryRedactor.redactEvidence(evidence, limit: 2_000)
        XCTAssertFalse(redacted.contains("secret"))
        XCTAssertFalse(redacted.contains("END UNTRUSTED LUNA EVIDENCE"))
        XCTAssertTrue(redacted.contains("Authorization: <redacted>"))
    }

    func testCaseBoundsAttemptsPluginsAndReportsDroppedEvidence() {
        let attempts = (0..<PluginRecoveryCase.maxAttempts + 4).map {
            PluginRecoveryAttempt(phase: "phase\($0)", result: "completed")
        }
        let plugins = (0..<PluginRecoveryCase.maxMatchingPlugins + 2).map {
            PluginRecoveryPlugin(id: "plugin\($0)", status: "enabled")
        }
        let recoveryCase = PluginRecoveryCase(
            originalURL: "https://example.com", outcome: "failed",
            attempts: attempts, attemptsDropped: 3, matchingPlugins: plugins,
            matchingPluginsDropped: 5)
        XCTAssertEqual(recoveryCase.attempts.count, PluginRecoveryCase.maxAttempts)
        XCTAssertEqual(recoveryCase.attemptsDropped, 7)
        XCTAssertEqual(recoveryCase.matchingPlugins.count, PluginRecoveryCase.maxMatchingPlugins)
        XCTAssertEqual(recoveryCase.matchingPluginsDropped, 7)
    }

    func testTraceParserExtractsCategoryAfterTimestampAndDroppedCount() {
        let trace = PluginRecoveryTraceParser.parse([
            "2026-09-03T00:00:00Z [fetch] strategy readability failed",
            "2026-09-03T00:00:01Z [ingest] classified article",
            "…(17 earlier lines dropped)",
        ])
        XCTAssertEqual(trace.dropped, 17)
        XCTAssertEqual(trace.attempts.map(\.phase), ["fetch", "ingest"])
        XCTAssertEqual(trace.attempts.map(\.result), ["failed", "observed"])
    }

    func testCaseJSONIsStableAndBounded() throws {
        let recoveryCase = PluginRecoveryCase(
            originalURL: "https://example.com/story", outcome: "failed",
            pageDigest: String(repeating: "x", count: 30_000))
        let data = try recoveryCase.jsonData()
        let decoded = try JSONDecoder().decode(PluginRecoveryCase.self, from: data)
        XCTAssertEqual(decoded, recoveryCase)
        XCTAssertLessThanOrEqual(recoveryCase.pageDigest?.count ?? 0, 12_000)
    }

}

import Testing
import LunaModels
@testable import LunaHTMLClassification

@Test func detectsPublisherPaywallSchema() {
    #expect(HTMLClassification.declaresPaywall(in: #"{"isAccessibleForFree":false}"#))
    #expect(!HTMLClassification.declaresPaywall(in: #"{"isAccessibleForFree":true}"#))
}

@Test func publisherLockRejectsShortCleanBodiesOnly() {
    let short = ArticleContent(title: "Story", blocks: [
        .init(
            kind: .paragraph,
            text: String(repeating: "Clean prose with no subscription words at all here. ", count: 40),
            links: []),
    ])
    #expect(short.bodyTextLength < PaywallDetector.shortBodyThreshold)
    #expect(PaywallDetector.looksPaywalled(
        content: short, html: #"{"isAccessibleForFree":false}"#))

    let long = ArticleContent(title: "Story", blocks: [
        .init(
            kind: .paragraph,
            text: String(repeating: "Reported article prose continues with enough concrete detail to read as the actual story. ", count: 70),
            links: []),
    ])
    #expect(long.bodyTextLength > PaywallDetector.shortBodyThreshold)
    #expect(!PaywallDetector.looksPaywalled(
        content: long, html: #"{"isAccessibleForFree":false}"#))
    #expect(ArticleExtraction.isReadableArticle(
        long, html: #"{"isAccessibleForFree":false}"#))
}

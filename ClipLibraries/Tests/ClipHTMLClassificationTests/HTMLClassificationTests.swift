import Testing
@testable import ClipHTMLClassification

@Test func detectsPublisherPaywallSchema() {
    #expect(HTMLClassification.declaresPaywall(in: #"{"isAccessibleForFree":false}"#))
    #expect(!HTMLClassification.declaresPaywall(in: #"{"isAccessibleForFree":true}"#))
}

import Testing
@testable import LunaHTMLClassification

@Test func detectsPublisherPaywallSchema() {
    #expect(HTMLClassification.declaresPaywall(in: #"{"isAccessibleForFree":false}"#))
    #expect(!HTMLClassification.declaresPaywall(in: #"{"isAccessibleForFree":true}"#))
}

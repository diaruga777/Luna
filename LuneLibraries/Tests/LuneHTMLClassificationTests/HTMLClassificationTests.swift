import Testing
@testable import LuneHTMLClassification

@Test func detectsPublisherPaywallSchema() {
    #expect(HTMLClassification.declaresPaywall(in: #"{"isAccessibleForFree":false}"#))
    #expect(!HTMLClassification.declaresPaywall(in: #"{"isAccessibleForFree":true}"#))
}

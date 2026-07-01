import Foundation
import Testing
@testable import LunaPaywallBypass

@Test func trailingDotIsLimitedToNYTimesHosts() {
    #expect(PaywallBypassRules.trailingDotURL(for: URL(string: "https://www.nytimes.com/a")!)?.host == "www.nytimes.com.")
    #expect(PaywallBypassRules.trailingDotURL(for: URL(string: "https://example.com/a")!)?.host == "example.com.")
}

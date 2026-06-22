import Foundation
import Testing
@testable import ClipURLClassification

@Test func canonicalizationRemovesOnlyTrackingData() {
    let url = URL(string: "https://example.com/read?id=42&utm_source=test#section")!
    #expect(URLClassification.canonicalURL(url).absoluteString == "https://example.com/read?id=42")
}

@Test func platformRecognitionUsesAValidatedYouTubeID() {
    let url = URL(string: "https://youtu.be/dQw4w9WgXcQ")!
    #expect(URLClassification.platform(for: url)?.platform == .youtube)
    #expect(URLClassification.youTubeVideoID(in: url) == "dQw4w9WgXcQ")
}

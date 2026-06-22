import Testing
@testable import ClipModels

@Test func platformKindsAreExhaustive() {
    #expect(ContentPlatform.youtube.kind == .video)
    #expect(ContentPlatform.reddit.kind == .social)
    #expect(ContentPlatform.music.kind == .audio)
}

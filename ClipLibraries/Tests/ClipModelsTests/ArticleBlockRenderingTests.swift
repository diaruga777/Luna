import Testing
@testable import ClipModels

@Test func joinsNonEmptyBlocksWithParagraphSpacing() {
    #expect(ArticleBlockRendering.plainText(blocks: [" First ", "", "Second"]) == "First\n\nSecond")
}

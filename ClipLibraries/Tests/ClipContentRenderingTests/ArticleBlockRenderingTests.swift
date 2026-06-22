import Testing
@testable import ClipContentRendering

@Test func joinsNonEmptyBlocksWithParagraphSpacing() {
    #expect(ArticleBlockRendering.plainText(blocks: [" First ", "", "Second"]) == "First\n\nSecond")
}

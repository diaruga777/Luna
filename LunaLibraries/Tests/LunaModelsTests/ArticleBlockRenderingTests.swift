import Testing
@testable import LunaModels

@Test func joinsNonEmptyBlocksWithParagraphSpacing() {
    #expect(ArticleBlockRendering.plainText(blocks: [" First ", "", "Second"]) == "First\n\nSecond")
}

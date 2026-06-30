import Testing
@testable import LuneModels

@Test func joinsNonEmptyBlocksWithParagraphSpacing() {
    #expect(ArticleBlockRendering.plainText(blocks: [" First ", "", "Second"]) == "First\n\nSecond")
}

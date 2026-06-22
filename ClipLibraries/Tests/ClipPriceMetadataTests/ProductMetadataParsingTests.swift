import Testing
@testable import ClipPriceMetadata

@Test func parsesJSONLDProductOffer() {
    let html = #"<script type="application/ld+json">{"@type":"Product","name":"Widget","offers":{"price":"19.95","priceCurrency":"AUD"}}</script>"#
    let product = ProductMetadataParsing.firstJSONLDProduct(in: html)
    #expect(product?.name == "Widget")
    #expect(product?.price == 19.95)
    #expect(product?.currency == "AUD")
}

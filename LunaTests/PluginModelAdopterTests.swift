//
//  PluginModelAdopterTests.swift
//  LunaTests
//

import XCTest
import LunaHTMLClassification
import LunaIngest
import LunaMediaDownload
import LunaModels
import LunaPluginIngest
import LunaPriceIngest
import LunaReaderUI

/// What each kind module makes of a plugin's Model
/// (`claudedocs/plans/plugin-platform.md` §5, §7.3).
final class PluginModelAdopterTests: XCTestCase {

    private let url = URL(string: "https://example.com/p/abc")!

    // MARK: - Media

    func testMediaAdoptionCarriesTheHeadersQualityAndExpiry() async {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let model = MediaModel(
            title: "A clip", platform: "instagram", itemID: "abc",
            assets: [
                MediaAssetSpec(
                    url: URL(string: "https://cdn.example.com/v.mp4")!, type: .video,
                    thumbnailURL: URL(string: "https://cdn.example.com/t.jpg")!,
                    estimatedBytes: 4096,
                    headers: ["Referer": "https://example.com/", "User-Agent": "Bot"],
                    quality: "1080p"),
            ],
            expiresAt: expiry)

        guard case let .media(assets, platform, itemID, title, _) =
            await MediaModelAdopter().adopt(model, url: url, pluginID: "app.luna.ig")
        else { return XCTFail("expected .media") }

        XCTAssertEqual(assets.count, 1)
        let asset = assets[0]
        XCTAssertEqual(asset.kind, .video)
        XCTAssertEqual(asset.requestHeaders["Referer"], "https://example.com/")
        XCTAssertEqual(asset.quality, "1080p")
        XCTAssertEqual(asset.estimatedByteCount, 4096)
        XCTAssertEqual(asset.pluginID, "app.luna.ig")
        XCTAssertEqual(asset.expiresAt, expiry)
        XCTAssertEqual(platform, .instagram)
        XCTAssertEqual(itemID, "abc")
        XCTAssertEqual(title, "A clip")
    }

    func testAnUnknownPlatformNameFallsBackToTheURLThenToWeb() async {
        let model = MediaModel(
            platform: "somewhere-new",
            assets: [MediaAssetSpec(url: URL(string: "https://cdn.test/v.mp4")!, type: .video)])

        guard case let .media(_, unknownHost, _, _, _) =
            await MediaModelAdopter().adopt(model, url: url, pluginID: "p")
        else { return XCTFail("expected .media") }
        XCTAssertEqual(unknownHost, .web, "an unrecognized name and host settle on .web")

        let onReddit = URL(string: "https://www.reddit.com/r/x/comments/abc/t/")!
        guard case let .media(_, recognized, _, _, _) =
            await MediaModelAdopter().adopt(model, url: onReddit, pluginID: "p")
        else { return XCTFail("expected .media") }
        XCTAssertEqual(recognized, .reddit, "the URL answers when the name does not")
    }

    func testTwitterIsSpelledXInternally() async {
        let model = MediaModel(
            platform: "twitter",
            assets: [MediaAssetSpec(url: URL(string: "https://cdn.test/v.mp4")!, type: .video)])
        guard case let .media(_, platform, _, _, _) =
            await MediaModelAdopter().adopt(model, url: url, pluginID: "p")
        else { return XCTFail("expected .media") }
        XCTAssertEqual(platform, .x)
    }

    func testAModelWithNoAssetsIsDeclined() async {
        let model = MediaModel(assets: [])
        guard case .declined = await MediaModelAdopter().adopt(model, url: url, pluginID: "p")
        else { return XCTFail("a media Model with nothing to download keeps nothing") }
    }

    // MARK: - Article

    func testArticleAdoptionConvertsTheFragmentWithoutRescoringIt() async {
        // Short enough that the readability arbitration would discard it; the
        // plugin already chose the body, so it survives.
        let model = ArticleModel(
            title: "The headline", author: "A. Writer",
            html: "<p>One short paragraph with a <a href=\"/next\">link</a>.</p>")

        guard case let .article(content, sourceHTML) = await ArticleModelAdopter().adopt(
            model, url: url, page: .none, pluginID: "p")
        else { return XCTFail("expected .article") }

        XCTAssertEqual(content.title, "The headline")
        XCTAssertEqual(content.author, "A. Writer")
        XCTAssertEqual(content.blocks.count, 1)
        XCTAssertTrue(content.blocks[0].text.contains("One short paragraph"))
        XCTAssertEqual(
            content.blocks[0].links.first?.urlString, "https://example.com/next",
            "an inline link survives and is made absolute")
        XCTAssertEqual(sourceHTML, model.html)
    }

    func testALeadImageBecomesTheFirstBlockWhenTheBodyHasNone() async {
        let model = ArticleModel(
            title: "T", html: "<p>Body text.</p>",
            leadImageURL: URL(string: "https://example.com/hero.jpg")!)
        guard case let .article(content, _) = await ArticleModelAdopter().adopt(
            model, url: url, page: .none, pluginID: "p")
        else { return XCTFail("expected .article") }
        XCTAssertEqual(content.blocks.first?.kind, .image)
        XCTAssertEqual(content.blocks.first?.imageURLString, "https://example.com/hero.jpg")
    }

    /// A recording is handed back as a request, not fetched: the runner does the
    /// work later. The Model's html becomes the lead the transcript follows.
    func testATranscriptionModelBecomesARequestWithTheHTMLAsLead() async {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let model = ArticleModel(
            title: "A talk", author: "Someone",
            html: "<p>The description.</p>",
            leadImageURL: URL(string: "https://example.com/poster.jpg")!,
            language: "en",
            transcription: ArticleTranscriptionSpec(
                url: URL(string: "https://cdn.example.com/v.mp4")!, type: .video,
                audioURL: URL(string: "https://cdn.example.com/a.m4a")!,
                headers: ["Referer": "https://example.com/"], expiresAt: expiry))

        guard case let .transcription(request) = await ArticleModelAdopter().adopt(
            model, url: url, page: .none, pluginID: "app.luna.yt.transcript")
        else { return XCTFail("expected .transcription") }

        XCTAssertEqual(request.mediaURL.absoluteString, "https://cdn.example.com/v.mp4")
        XCTAssertEqual(request.mediaKind, .video)
        XCTAssertEqual(request.audioURL?.absoluteString, "https://cdn.example.com/a.m4a")
        XCTAssertEqual(request.fetchURL, request.audioURL, "the audio leg is what gets fetched")
        XCTAssertEqual(request.requestHeaders["Referer"], "https://example.com/")
        XCTAssertEqual(request.expiresAt, expiry)
        XCTAssertEqual(request.language, "en")
        XCTAssertEqual(request.title, "A talk")
        XCTAssertEqual(request.author, "Someone")
        XCTAssertEqual(request.pluginID, "app.luna.yt.transcript")
        let lead = request.leadContent
        XCTAssertEqual(lead?.blocks.first?.kind, .image)
        XCTAssertEqual(lead?.blocks.first?.imageURLString, "https://example.com/poster.jpg")
        XCTAssertTrue(lead?.blocks.last?.text.contains("The description.") ?? false)
    }

    func testATranscriptionModelWithNoHTMLHasNoLead() async {
        let model = ArticleModel(
            title: "A talk", html: "   ",
            transcription: ArticleTranscriptionSpec(
                url: URL(string: "https://cdn.example.com/a.m4a")!, type: .audio))
        guard case let .transcription(request) = await ArticleModelAdopter().adopt(
            model, url: url, page: .none, pluginID: "p")
        else { return XCTFail("expected .transcription") }
        XCTAssertNil(request.leadContent)
        XCTAssertEqual(request.mediaKind, .audio)
        XCTAssertNil(request.audioURL)
    }

    func testAnEmptyFragmentFails() async {
        let model = ArticleModel(title: "T", html: "   ")
        guard case let .failed(reason) = await ArticleModelAdopter().adopt(
            model, url: url, page: .none, pluginID: "p")
        else { return XCTFail("expected .failed") }
        XCTAssertEqual(reason, .notReadable)
    }

    // MARK: - Product

    func testProductAdoptionBuildsTrackableInfo() async {
        let model = ProductModel(
            name: "A Thing", price: PluginPrice(amount: 12.34, currency: "aud"),
            imageURL: URL(string: "https://example.com/i.jpg")!,
            brand: "Acme", productID: "SKU1",
            identifiers: ProductIdentifiersSpec(gtin: "0123456789012"),
            sellers: [
                ProductSellerSpec(
                    url: URL(string: "https://other.test/thing")!, name: "Other",
                    price: PluginPrice(amount: 11, currency: "AUD")),
                // No price: cannot be tracked, so it is dropped.
                ProductSellerSpec(url: URL(string: "https://third.test/thing")!),
            ])

        guard case let .product(adopted, imageURL) =
            await ProductModelAdopter().adopt(model, url: url, pluginID: "p")
        else { return XCTFail("expected .product") }

        let info = PluginProductInfoBuilder.make(from: adopted, imageURL: imageURL)
        XCTAssertEqual(info.name, "A Thing")
        XCTAssertEqual(info.priceAmount, Decimal(string: "12.34"))
        XCTAssertEqual(info.priceCurrency, "AUD", "the currency is normalized to ISO 4217 case")
        XCTAssertEqual(info.identifiers.gtin, "0123456789012")
        XCTAssertEqual(info.sellers.count, 1, "a seller with no price is not trackable")
        XCTAssertEqual(info.sellers.first?.price.currency, "AUD")
    }

    func testAPricelessProductIsDeclined() async {
        let model = ProductModel(name: "T", price: PluginPrice(amount: 0, currency: "USD"))
        guard case .declined = await ProductModelAdopter().adopt(model, url: url, pluginID: "p")
        else { return XCTFail("a tracker with no amount cannot alert or graph") }
    }
}

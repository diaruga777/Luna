//
//  RescueGenerableSchemas.swift
//  LunaURLRescue
//

// The @Generable schemas the on-device / PCC conformers fill in. iOS-26-only
// (FoundationModels), so the whole file is availability-gated; the conformers
// map these drafts down to the plain `RescuePlanResponse` / `RescueArticleResponse`
// DTOs so nothing above the seam names a Generable type.
//
// Decision (see refactor-plans / url-rescue.md): ONE umbrella plan struct with a
// `@Guide(.anyOf(...))` closed-vocabulary `kind` string plus optional field
// groups — matching the flat `AudioCleanupVerdict` precedent. Enums with
// associated values are unproven in this codebase's @Generable usage. The
// article payload is a SEPARATE (PCC-only) second call so the small plan schema
// fits the 4096-token on-device window.

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
@Generable
struct RescuePlanDraft {
    @Guide(description: """
    Your chosen rescue strategy. "reroute": a better URL for the SAME content on \
    the same website (AMP, mobile, print, canonical, or embed variant). "webjs": \
    load the page in a browser and run JavaScript that returns its content. \
    "product": the product name, price, and currency read verbatim from the \
    digest. "article": you will be asked for the full text next. "media_url": a \
    direct media-file URL found in the digest. "give_up": nothing here can work.
    """, .anyOf(["article", "product", "reroute", "webjs", "media_url", "give_up"]))
    let kind: String

    @Guide(description: "For reroute/webjs: an https URL on the SAME site (or its amp/mobile/print/canonical variant) to load instead. Omit otherwise.")
    let rerouteURLString: String?

    @Guide(description: "Browser identity for the re-fetch, only if a specific one is needed.",
           .anyOf(["iphone_safari", "desktop_safari", "googlebot", "facebook_crawler"]))
    let userAgentToken: String?

    @Guide(description: "https Referer to send, e.g. https://www.google.com/. Omit unless needed.")
    let refererString: String?

    @Guide(description: "Accept-Language header value, e.g. en-US,en;q=0.9. Omit unless needed.")
    let acceptLanguage: String?

    @Guide(description: "IPv4 address for X-Forwarded-For, only for crawler-whitelist sites. Omit otherwise.")
    let xForwardedFor: String?

    @Guide(description: "For webjs: a self-contained JavaScript body that RETURNS a string (HTML, JSON, or a media URL). No cookies, no navigation, no external network requests.")
    let javascript: String?

    @Guide(description: "What the webjs javascript returns.", .anyOf(["html", "json", "media_url"]))
    let scriptResultKind: String?

    @Guide(description: "For media_url: the direct https video/image/audio file URL found in the page data. Omit otherwise.")
    let mediaURLString: String?

    @Guide(description: "For product: the product's display name exactly as it appears in the page data.")
    let productName: String?

    @Guide(description: "For product: the numeric price EXACTLY as it appears in the page data — digits and decimal separator only, e.g. 129.99.")
    let productPriceAmount: String?

    @Guide(description: "For product: ISO 4217 currency code, e.g. USD.")
    let productCurrency: String?

    let productImageURLString: String?
    let productBrand: String?
}

@available(iOS 26.0, *)
extension RescuePlanDraft {
    /// Down to the plain, seam-safe DTO.
    var response: RescuePlanResponse {
        RescuePlanResponse(
            kind: kind,
            rerouteURLString: rerouteURLString,
            userAgentToken: userAgentToken,
            refererString: refererString,
            acceptLanguage: acceptLanguage,
            xForwardedFor: xForwardedFor,
            javascript: javascript,
            scriptResultKind: scriptResultKind,
            mediaURLString: mediaURLString,
            productName: productName,
            productPriceAmount: productPriceAmount,
            productCurrency: productCurrency,
            productImageURLString: productImageURLString,
            productBrand: productBrand)
    }
}

@available(iOS 26.0, *)
@Generable
struct RescueArticleDraft {
    @Guide(description: "The article's title, exactly as written.")
    let title: String

    @Guide(description: "The byline / author, if the page shows one. Omit otherwise.")
    let author: String?

    @Generable
    struct BlockDraft {
        @Guide(description: "The kind of text block.",
               .anyOf(["paragraph", "heading", "quote", "listItem"]))
        let kind: String
        @Guide(description: "The block's text, exactly as written in the page data — never summarized, never invented.")
        let text: String
    }

    @Guide(description: "The article's full body, in order, one entry per paragraph/heading/quote/list item, reproduced verbatim from the page data.")
    let blocks: [BlockDraft]
}

@available(iOS 26.0, *)
extension RescueArticleDraft {
    var response: RescueArticleResponse {
        RescueArticleResponse(
            title: title,
            author: author,
            blocks: blocks.map { RescueArticleResponse.BlockDTO(kind: $0.kind, text: $0.text) })
    }
}
#endif

//
//  RescueRecipeValidator.swift
//  LunaURLRescue
//

import Foundation
import LunaModels

/// Vets the recipe a recovery Luna file carries, under the same rules a model's
/// own plan meets (`claudedocs/luna-file.md`).
///
/// A recipe is written by a chat model the user talked to, so it is exactly as
/// untrusted as a plan: the destination goes through
/// `RescueDirectiveValidator`'s host policy, the headers through its allowlist
/// and user-agent token map, and the script through its size cap. The rules are
/// not restated here — the same validator answers both, or the two could drift
/// and only one of them would be the security boundary.
public struct RescueRecipeValidator {
    public enum Rejection: Error, Equatable {
        /// The recipe's URL is not on the page's own site, nor on one of the
        /// fixed mirrors.
        case hostNotAllowed
        case badJavaScript
    }

    /// The literal user agent a recipe may name when it is not one of the
    /// tokens. Bounded because it goes into a request header.
    static let maxUserAgentLength = 300

    private let base = RescueDirectiveValidator()

    public init() {}

    /// The directive to apply, or why the recipe was refused.
    func directive(
        for recipe: LunaRecoveryRecipe, pageURL: URL
    ) -> Result<RescueDirective, Rejection> {
        guard recipe.url.scheme?.lowercased() == "https",
              base.isAllowedRerouteHost(candidate: recipe.url, original: pageURL)
        else { return .failure(.hostNotAllowed) }

        let headers = self.headers(for: recipe)
        guard let javascript = recipe.javascript else {
            return .success(.reroute(RescueReroute(url: recipe.url, headers: headers)))
        }
        guard javascript.utf8.count <= RescueDirectiveValidator.maxJavaScriptBytes else {
            return .failure(.badJavaScript)
        }
        return .success(.webJS(RescueScript(
            pageURL: recipe.url, headers: headers, javascript: javascript,
            resultKind: Self.resultKind(recipe.returns))))
    }

    /// The three header names a recipe may set, mapped onto the closed set a
    /// directive carries. A malformed value is dropped, never an error — the
    /// recipe is still worth replaying without it.
    private func headers(for recipe: LunaRecoveryRecipe) -> RescueHeaders {
        var headers = RescueHeaders()
        if let agent = recipe.headers["user-agent"] {
            headers.userAgent = RescueDirectiveValidator.userAgent(fromToken: agent)
                ?? (agent.count <= Self.maxUserAgentLength ? agent : nil)
        }
        if let referer = recipe.headers["referer"], referer.count <= 2048,
           let url = URL(string: referer), url.scheme?.lowercased() == "https", url.host != nil {
            headers.referer = url
        }
        if let language = recipe.headers["accept-language"],
           language.range(of: "^[A-Za-z0-9,;=.\\- ]{1,64}$", options: .regularExpression) != nil {
            headers.acceptLanguage = language
        }
        return headers
    }

    private static func resultKind(_ returns: LunaRecoveryRecipe.Returns) -> RescueScript.ResultKind {
        switch returns {
        case .html: return .html
        case .json: return .json
        case .mediaURL: return .mediaURL
        }
    }
}

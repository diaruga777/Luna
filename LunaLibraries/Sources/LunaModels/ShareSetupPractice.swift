//
//  ShareSetupPractice.swift
//  LunaModels
//

import Foundation

/// The deterministic link and preview used by the share-sheet onboarding
/// lesson. These URLs deliberately never reach the network: the extensions
/// recognize them before appending a reading-list row, show this bundled
/// preview, and record setup evidence in the shared App Group.
public enum ShareSetupPractice {
    public static let lunaURLString = "https://luna.app/about"
    public static let instaTokURLString =
        "https://instatok.web/@moonwatch/lunar-eclipse"
    public static let amayzonURLString =
        "https://amayzon.web/eyephone-air"

    public static let urlStrings: Set<String> = [
        lunaURLString,
        instaTokURLString,
        amayzonURLString,
    ]

    public static let title = L10n.string("ShareSetupPractice_articleSubjectLine")
    public static let byline = L10n.string("ShareSetupPractice_bylineExample")
    public static let intro = L10n.string("ShareSetupPractice_featuresHeading")
    public static let features = [
        L10n.string("ShareSetupPractice_feature01"),
        L10n.string("ShareSetupPractice_feature02"),
        L10n.string("ShareSetupPractice_feature03"),
        L10n.string("ShareSetupPractice_feature04"),
        L10n.string("ShareSetupPractice_feature05"),
        L10n.string("ShareSetupPractice_feature06"),
        L10n.string("ShareSetupPractice_feature07"),
        L10n.string("ShareSetupPractice_feature08"),
        L10n.string("ShareSetupPractice_feature09"),
        L10n.string("ShareSetupPractice_feature10"),
        L10n.string("ShareSetupPractice_feature11"),
        L10n.string("ShareSetupPractice_feature12"),
        L10n.string("ShareSetupPractice_feature13"),
        L10n.string("ShareSetupPractice_feature14"),
        L10n.string("ShareSetupPractice_feature15"),
        L10n.string("ShareSetupPractice_feature16"),
        L10n.string("ShareSetupPractice_feature17"),
        L10n.string("ShareSetupPractice_feature18"),
        L10n.string("ShareSetupPractice_feature19"),
        L10n.string("ShareSetupPractice_feature20"),
        L10n.string("ShareSetupPractice_feature21"),
        L10n.string("ShareSetupPractice_feature22"),
        L10n.string("ShareSetupPractice_feature23"),
    ]

    public static var plainText: String {
        ([intro] + features.map { "• " + $0 }).joined(separator: "\n")
    }

    public static var articleContent: ArticleContent {
        ArticleContent(
            title: title,
            blocks: [block(kind: .paragraph, intro)]
                + features.map { block(kind: .listItem, $0) })
    }

    public static var fallbackHTMLBody: String {
        "<h1>\(escaped(title))</h1>\n"
            + "<p>\(escaped(intro))</p>\n<ul>\n"
            + features.map { "<li>\(escaped($0))</li>" }
                .joined(separator: "\n")
            + "\n</ul>"
    }

    public static func matches(_ url: URL) -> Bool {
        urlStrings.contains(canonicalString(for: url))
    }

    private static func canonicalString(for url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        var value = components?.url?.absoluteString ?? url.absoluteString
        while value.last == "/" { value.removeLast() }
        return value
    }

    private static func block(
        kind: ArticleContent.Block.Kind,
        _ text: String
    ) -> ArticleContent.Block {
        .init(kind: kind, text: text, links: [])
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

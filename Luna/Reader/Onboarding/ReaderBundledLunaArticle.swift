//
//  ReaderBundledLunaArticle.swift
//  Luna
//

import LunaModels
import LunaStorage
import Foundation

/// The offline copy used by both halves of the onboarding demonstration.
///
/// `LunaWikipedia.html` is the Safari-shaped page.  This extracted form is
/// stored through the ordinary ReadingListStore so the final reveal is a real
/// Reader card with the same persistence and offline behavior as any save.
enum ReaderBundledLunaArticle {
    static let urlString = "https://en.wikipedia.org/wiki/Luna"

    @discardableResult
    static func install(in store: ReadingListStore = .shared) -> ReadingListItem {
        let item = store.add(urlString: urlString, source: .manual)
        if item.state == .ready, store.content(for: item) != nil {
            return item
        }
        return store.saveContent(content, for: item)
    }

    static let content = ArticleContent(
        title: "Luna",
        author: "Wikipedia contributors",
        blocks: [
            paragraph(
                "Luna commonly refers to Earth’s Moon, named “Luna” in Latin, Spanish, "
                    + "and other languages; Luna, the ancient Roman personification of "
                    + "the Moon; Luna as a given name and surname; and Luna marble, the "
                    + "ancient Roman term for Carrara marble."),
            heading("Places"),
            paragraph(
                "Places named Luna include municipalities in Apayao, Isabela, La Union, "
                    + "and San Jose in the Philippines; localities in Cluj and Satu Mare "
                    + "counties in Romania; and communities or geographic features in "
                    + "Arkansas, Missouri, Minnesota, New Mexico, Arizona, and New York."),
            paragraph(
                "Other uses include the ancient Etruscan city of Luna, Luna in Aragon "
                    + "and Rajasthan, the Luna River in Spain, Luna Peak, Luna Street, "
                    + "Roverè della Luna, and the LUNA lunar-analogue facility in Cologne."),
            heading("Arts, entertainment and media"),
            paragraph(
                "Luna appears throughout fiction, film, television, radio, literature, "
                    + "and music. It names fictional characters and starships, films from "
                    + "several countries, novels, performers, bands, albums, songs, and "
                    + "Ellen Tykeson’s sculpture in Eugene, Oregon."),
            heading("Businesses and people"),
            paragraph(
                "The name is used by businesses and brands including Luna Bar, Luna "
                    + "Guitars, Luna Innovations, Luna Lounge, Luna Park, and Luna "
                    + "Publications. It is also the professional or given name of "
                    + "footballers, singers, artists, and other public figures."),
            heading("Science and technology"),
            paragraph(
                "In biology, Luna can mean the orca known as L98, the California redwood "
                    + "tree protected by Julia Butterfly Hill, or the lime-green North "
                    + "American luna moth. In computing it has named a cryptocurrency, "
                    + "the default Windows XP theme, an OMRON computer line, a Nokia "
                    + "phone, Amazon’s cloud-gaming service, and a digital audio workstation."),
            heading("Transportation and other uses"),
            paragraph(
                "Luna has named Soviet carrier rockets and space missions, a historic "
                    + "tugboat, yachts, passenger ships, an unmanned aircraft, a moped, "
                    + "and Soviet artillery rockets. The word also names a small vessel "
                    + "used in a monstrance and a Bantu language of the Democratic "
                    + "Republic of the Congo."),
            heading("About this offline copy"),
            paragraph(
                "Adapted from the English Wikipedia disambiguation page “Luna”, revision "
                    + "1357613450. Text is available under the Creative Commons "
                    + "Attribution-ShareAlike 4.0 License. Links and editing controls are "
                    + "disabled during this onboarding demonstration."),
        ])

    private static func heading(_ text: String) -> ArticleContent.Block {
        .init(kind: .heading, text: text, links: [])
    }

    private static func paragraph(_ text: String) -> ArticleContent.Block {
        .init(kind: .paragraph, text: text, links: [])
    }
}

//
//  BundledLunaArticle.swift
//  Luna
//

import LunaModels
import LunaStorage
import Foundation

/// The offline copy used by both halves of the onboarding demonstration. This
/// extracted form is stored through the ordinary ReadingListStore so the final
/// reveal is a real Reader card with the same persistence and offline behavior
/// as any save.
enum BundledLunaArticle {
    static let urlString = "https://luna.app"

    struct InstallResult {
        let item: ReadingListItem
        let wasCreated: Bool
    }

    @discardableResult
    static func install(
        urlString: String = urlString,
        in store: ReadingListStore = .shared
    ) -> InstallResult {
        let wasCreated = store.item(forURLString: urlString) == nil
        let item = store.add(urlString: urlString, source: .manual)
        if item.state == .ready, store.content(for: item) != nil {
            return InstallResult(item: item, wasCreated: wasCreated)
        }
        return InstallResult(
            item: store.saveContent(content, for: item),
            wasCreated: wasCreated)
    }

    static func installTemporary(
        urlString: String = urlString,
        registry: AppOnboardingStore = .shared,
        in store: ReadingListStore = .shared
    ) -> Bool {
        let result = install(urlString: urlString, in: store)
        if result.wasCreated {
            registry.recordTemporarySave(identifier: result.item.id)
        } else {
            // Never claim ownership of a save the user already had.
            registry.clearTemporarySaveIdentifier()
        }
        return result.item.state == .ready && store.content(for: result.item) != nil
    }

    static func cleanupTemporary(
        registry: AppOnboardingStore = .shared,
        in store: ReadingListStore = .shared
    ) {
        defer { registry.clearTemporarySaveIdentifier() }
        guard let identifier = registry.temporarySaveIdentifier,
              let item = store.item(withID: identifier)
        else { return }
        store.delete(item)
    }

    static let content = ArticleContent(
        title: "Save anything in Safari",
        blocks: [
            paragraph(
                "Your article, and your browsing history, all stay offline."),
            paragraph(
                "Speed read, open links inline, and more! The best smartphone reading "
                    + "experience you’ve ever had."),
        ])

    private static func paragraph(_ text: String) -> ArticleContent.Block {
        .init(kind: .paragraph, text: text, links: [])
    }
}

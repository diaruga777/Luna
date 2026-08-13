//
//  ReaderHostFactory.swift
//  Luna
//

import LunaModels
import UIKit

/// Single construction point for the full-screen reader a save opens into: the stacked-
/// layer `RabbitHoleReaderViewController`. Centralised so every call site shares one
/// entry point.
public enum ReaderHostFactory {
    /// - Parameter fullContentUpFront: render every layer's whole article
    ///   immediately (no progressive prefix → swap) for hosts that cannot
    ///   tolerate progressive rendering.
    public static func make(item: SavedItem,
                     content: ArticleContent,
                     shareProvider: ReaderShareProviding? = nil,
                     fullContentUpFront: Bool = false,
                     includesArticleTitle: Bool = true) -> UIViewController {
        let reader = RabbitHoleReaderViewController(
            item: item, content: content,
            shareProvider: shareProvider,
            includesArticleTitle: includesArticleTitle)
        reader.rendersFullContentUpFront = fullContentUpFront
        return reader
    }
}

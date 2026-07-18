//
//  ReaderHostFactory.swift
//  Luna
//

import LunaModels
import UIKit

/// Single construction point for the full-screen reader a save opens into: the stacked-
/// layer `RabbitHoleReaderViewController`. Centralised so every call site shares one
/// entry point and injects the same transition.
public enum ReaderHostFactory {
    /// - Parameter fullContentUpFront: render every layer's whole article
    ///   immediately (no progressive prefix → swap) — for hosts that keep the
    ///   reader permanently embedded, e.g. carousel cards.
    public static func make(item: ReadingListItem,
                     content: ArticleContent,
                     shareProvider: ReaderShareProviding? = nil,
                     transition: RabbitHoleTransitioning? = nil,
                     fullContentUpFront: Bool = false) -> UIViewController {
        let reader = RabbitHoleReaderViewController(
            item: item, content: content,
            shareProvider: shareProvider,
            transition: transition)
        reader.rendersFullContentUpFront = fullContentUpFront
        return reader
    }
}

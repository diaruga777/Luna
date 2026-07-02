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
    public static func make(item: ReadingListItem,
                     content: ArticleContent,
                     shareProvider: ReaderShareProviding? = nil,
                     transition: RabbitHoleTransitioning? = nil) -> UIViewController {
        RabbitHoleReaderViewController(
            item: item, content: content,
            shareProvider: shareProvider,
            transition: transition)
    }
}

//
//  ReaderHostFactory.swift
//  Clip
//

import ClipDesignSystem
import ClipModels
import UIKit

/// Single decision point for which reader hosts a save when opened full-screen: the
/// standard `ReaderViewController`, or — when the experimental flag is on — the forked
/// `RabbitHoleReaderViewController`. Centralised so every call site shares one branch
/// and the standard reader stays the untouched default.
public enum ReaderHostFactory {
    public static func make(item: ReadingListItem,
                     content: ArticleContent,
                     shareProvider: ReaderShareProviding? = nil,
                     gazeTrackerFactory: GazeTrackerFactory? = nil,
                     transition: RabbitHoleTransitioning? = nil) -> UIViewController {
        if ReaderSettings.rabbitHoleReaderEnabled {
            return RabbitHoleReaderViewController(
                item: item, content: content,
                shareProvider: shareProvider, gazeTrackerFactory: gazeTrackerFactory,
                transition: transition)
        }
        return ReaderViewController(
            item: item, content: content,
            shareProvider: shareProvider, gazeTrackerFactory: gazeTrackerFactory)
    }
}

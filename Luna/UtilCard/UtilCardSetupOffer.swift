//
//  UtilCardSetupOffer.swift
//  Luna
//

import Foundation

/// A setup lesson the util card can offer, in PRIORITY order — which is also
/// the order the buttons read top to bottom. The block stacks up from the paste
/// row, so the last one present is the bottom-most.
enum UtilCardSetupButton: CaseIterable, Equatable {
    case safari
    case save
}

/// Which setup buttons the util card puts on screen.
///
/// Never more than two: a third leaves the card no room for the Save of the
/// Week row and the recent URLs above it. Whatever is offered fills the bottom
/// slots, so an absent lesson is not a gap — the rest move down.
enum UtilCardSetupOffer {
    static let maximumButtons = 2

    static func buttons(safari: Bool, save: Bool) -> [UtilCardSetupButton] {
        let offered: [(UtilCardSetupButton, Bool)] = [
            (.safari, safari),
            (.save, save),
        ]
        return Array(offered.filter(\.1).map(\.0).prefix(maximumButtons))
    }
}

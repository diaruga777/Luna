//
//  UtilCardSetupOffer.swift
//  Luna
//

import Foundation

/// A setup lesson the util card can offer, in priority order — which is also
/// the order the buttons read top to bottom. The block stacks up from the paste
/// row, so the last one present is the bottom-most.
enum UtilCardSetupButton: CaseIterable, Equatable {
    case safari
    case save
    /// Connecting an email account. Last, and deliberately: it is a nudge, not
    /// a requirement, so it only appears once one of the two system
    /// integrations has stopped asking for the card's room.
    case email
}

/// Which setup buttons the util card puts on screen.
///
/// Never more than two: a third leaves the card no room for the Save of the
/// Week row and the recent URLs above it. Whatever is offered fills the bottom
/// slots, so an absent lesson is not a gap — the rest move down.
enum UtilCardSetupOffer {
    static let maximumButtons = 2

    /// Email waits until Luna has proved itself: three saves, or two days with
    /// the first one — whichever comes first. Newsletters are worth asking for
    /// only once someone is actually reading here.
    static let emailSaveCount = 3
    static let emailFirstSaveAge: TimeInterval = 48 * 60 * 60

    static func buttons(
        safari: Bool,
        save: Bool,
        email: Bool
    ) -> [UtilCardSetupButton] {
        let offered: [(UtilCardSetupButton, Bool)] = [
            (.safari, safari),
            (.save, save),
            (.email, email),
        ]
        return Array(offered.filter(\.1).map(\.0).prefix(maximumButtons))
    }

    /// - Parameter saveDates: when each save in the store was made, in any
    ///   order. Any save counts, whichever surface made it.
    static func emailIsEarned(saveDates: [Date], now: Date) -> Bool {
        if saveDates.count >= emailSaveCount { return true }
        guard let first = saveDates.min() else { return false }
        return now.timeIntervalSince(first) >= emailFirstSaveAge
    }
}

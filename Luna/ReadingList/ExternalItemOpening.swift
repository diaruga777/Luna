//
//  ExternalItemOpening.swift
//  Luna
//

import LunaModels

/// A root screen that can open one of its items in an external app (the
/// `<scheme>://read` deep link's "open elsewhere" leg), so `SceneDelegate` needs
/// no kind-specific downcast to route it.
///
/// Universal: it names only `ReadingListItem`. Each app's card-deck root conforms
/// where the behavior makes sense; a root that doesn't conform simply isn't
/// offered the leg.
///
/// Extracted from `ListKindSupport.swift`, which was deleted along with the rest
/// of the unreachable table-list surface — this was the one live thing in it.
protocol ExternalItemOpening: AnyObject {
    func openExternally(_ item: ReadingListItem)
}

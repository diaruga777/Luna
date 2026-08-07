//
//  MediaDeepLinkAction.swift
//  Luna
//

import Foundation

/// What `<scheme>://media?url=…` (the download Live Activity's tap-to-view
/// link) should do, decided by `KindWiring.mediaDeepLinkAction(forURLString:)`
/// — one variant per app, since only media-linking apps (Luna, LunaDownloader)
/// have an answer. Kind-neutral shape (no media-module types), so it lives in
/// the universal app shell alongside `ExternalItemOpening`; `SceneDelegate`
/// switches on it without ever naming a media-kind symbol.
enum MediaDeepLinkAction: Equatable {
    /// A downloaded local file — `SceneDelegate` centers the deck on this
    /// reading-list item and opens it (`ExternalItemOpening`).
    case centerAndOpen(UUID)
    /// A Photos-backed save — already handled (opened Photos); nothing further.
    case openedExternally
    /// Still downloading, or the URL matches no row — land on the deck, the
    /// default behavior for any other cold/foreground launch.
    case none
}

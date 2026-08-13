//
//  MediaDeepLinkAction.swift
//  Luna
//

import Foundation

/// What `<scheme>://media?url=…` (the download Live Activity's tap-to-view
/// link) should do, decided by `KindWiring.mediaDeepLinkAction(forURLString:)`
/// — one variant per app, since only media-linking apps (Luna, LunaDownloader)
/// have an answer. Kind-neutral shape (no media-module types), so it lives in
/// the universal app shell; `SceneDelegate` switches on it without ever naming
/// a media-kind symbol.
enum MediaDeepLinkAction: Equatable {
    /// A downloaded local file — `SceneDelegate` centers the deck on this
    /// saved item. The card itself is the destination; a handoff must not
    /// open the source URL in an in-app browser.
    case center(UUID)
    /// A Photos-backed save — already handled (opened Photos); nothing further.
    case openedExternally
    /// Still downloading, or the URL matches no row — land on the deck, the
    /// default behavior for any other cold/foreground launch.
    case none
}

/// How the shell materializes — and afterwards releases — a shareable copy of a
/// downloaded item's file, so `SceneDelegate` can raise a share sheet for the
/// finished Live Activity's Share link (`&share=1`) without naming a
/// media-module type.
///
/// Kind-neutral by construction: plain Foundation types, and the answer comes
/// from `KindWiring.mediaShareFileExporter` — installed only in the two apps that
/// link the media kind, so the share leg is simply unreachable in Reader and
/// Price Tracker (which never run the download activity in the first place).
protocol MediaShareFileExporting {
    /// A concrete file URL for the saved item, or nil when there is nothing
    /// shareable — a Photos-backed save, a transfer still running, a file gone.
    func exportedFileURL(forItemID itemID: UUID) async -> URL?
    /// Releases the temporary copy `exportedFileURL` made, once the sheet is done.
    func discardExportedFile(at fileURL: URL)
}

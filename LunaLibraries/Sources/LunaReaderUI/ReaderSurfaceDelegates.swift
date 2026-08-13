//
//  ReaderSurfaceDelegates.swift
//  LunaReaderUI
//

import LunaModels
import UIKit

/// Where a reader that does NOT write the shared `ReaderSettings` sends its mode
/// switches instead. One host has that shape: the action extension keeps its OWN
/// last-used mode, separate from the main app's, so `persistsModePreference: false`
/// plus one of these is how it hears about a switch.
///
/// Held strongly by the reader — the conformer is a small per-presentation
/// coordinator the surface makes, not the reader's owner. Nil in the main app, where
/// the reader writes the shared settings itself.
public protocol ReaderModePreferenceDelegate: AnyObject {
    func reader(_ reader: UIViewController, didSelectMode mode: ReadingListItem.ReaderMode)
}

/// How an extension's in-sheet reader exits. Both the loading screen's floating
/// button and the finished reader's Done item end here, and the host answers by
/// completing its extension request.
///
/// No sender, deliberately: the two buttons live on DIFFERENT view controllers (the
/// `ShareReaderViewController` and the `ReaderViewController` that replaces it), and
/// every host answers the same way regardless — so a sender could only mislead.
///
/// Held strongly, and by the bar item as well as the screen: the Done item has to keep
/// working after its view controller leaves the nav stack, which is the whole reason
/// the exit does not live on the screen itself.
public protocol ShareReaderCompletionDelegate: AnyObject {
    func shareReaderDidFinish()
}

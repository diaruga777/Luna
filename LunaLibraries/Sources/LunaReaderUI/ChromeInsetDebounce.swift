//
//  ChromeInsetDebounce.swift
//  LunaReaderUI
//

import CoreGraphics

/// The ~0.5pt debounce shared by the readers' `topChromeInset` (scroll) /
/// `topContentInset` (RSVP) property observers: hosts that float their chrome
/// outside the reader re-report the same inset on every layout pass, and
/// re-running the inset's layout work for sub-point jitter would be wasted.
enum ChromeInsetDebounce {
    static func changed(from old: CGFloat, to new: CGFloat) -> Bool {
        abs(new - old) > 0.5
    }
}

//
//  QuotingTextView.swift
//  LunaReaderUI
//
//  The reader's article text view. Its one addition to UITextView is that COPY
//  is the reader's copy, not the system's: a copied passage carries the same
//  quote-plus-URL payload the selection menu's Share sends, so pasting a
//  highlight into a message says where it came from.
//
//  Overriding `copy(_:)` rather than rewriting the edit menu is what makes every
//  copy route agree — the callout's Copy, ⌘C, and the accessibility action all
//  land on this one method.
//

import UIKit

public final class QuotingTextView: UITextView {

    /// Asked to copy the selected range in the reader's own format. Returning
    /// true means it handled the copy; false (or no handler at all) falls back
    /// to UIKit's plain-text copy.
    public var copySelectionAsQuote: ((NSRange) -> Bool)?

    public override func copy(_ sender: Any?) {
        let range = selectedRange
        if range.length > 0, copySelectionAsQuote?(range) == true { return }
        super.copy(sender)
    }
}

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

/// The reader that owns a `QuotingTextView` and knows the article behind it.
@MainActor
public protocol QuotingTextViewDelegate: AnyObject {
    /// Copy the selected range in the reader's own quote-plus-URL format.
    /// Returning true means it handled the copy; false (or no delegate at all)
    /// falls back to UIKit's plain-text copy.
    func quotingTextView(
        _ textView: QuotingTextView, copySelectionIn range: NSRange) -> Bool
}

public final class QuotingTextView: UITextView {

    /// The reader hosting this text view — it owns the view, hence weak.
    public weak var quotingDelegate: (any QuotingTextViewDelegate)?

    public override func copy(_ sender: Any?) {
        let range = selectedRange
        if range.length > 0,
           quotingDelegate?.quotingTextView(self, copySelectionIn: range) == true {
            return
        }
        super.copy(sender)
    }
}

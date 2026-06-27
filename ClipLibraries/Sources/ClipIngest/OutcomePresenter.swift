//
//  OutcomePresenter.swift
//  ReaderKit
//

import ClipModels
import Foundation

/// A thin per-surface presenter over the unified `Outcome`. Each surface (main app
/// list, share extension, action-extension reader, app intents, friend receive)
/// implements ONE method whose body is an EXHAUSTIVE switch over `Outcome` — the
/// compiler forbids a `default`, so no surface can forget a case. Every case shows
/// real UI (or persists + notifies for headless surfaces); `.failed`/timeout shows
/// an error, NEVER an infinite spinner.
///
/// The pipeline is called identically everywhere; the ONLY per-surface difference
/// is the body of `present`. Lives in ReaderKit so the extensions can conform.
public protocol OutcomePresenter {
    /// Present `outcome` for the already-saved `item`. Must handle ALL cases. Never
    /// leaves a spinner: a `.failed`/timeout outcome shows an error or marks the item
    /// failed, it does not hang.
    func present(_ outcome: Outcome, for item: ReadingListItem) async
}

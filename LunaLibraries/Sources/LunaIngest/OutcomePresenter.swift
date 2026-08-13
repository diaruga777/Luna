//
//  OutcomePresenter.swift
//  ReaderKit
//

import LunaModels
import Foundation

/// A thin per-surface presenter over the unified `Outcome`. Each surface (main
/// app list, share extension, action-extension reader, app intents, friend
/// receive) implements one method whose body is an exhaustive switch over
/// `Outcome`. The compiler forbids a `default` case, so no surface can forget
/// a case. Every case shows real UI, or persists and notifies for headless
/// surfaces; `.failed` or a timeout shows an error, never an infinite spinner.
///
/// The pipeline is called identically everywhere; the only per-surface
/// difference is the body of `present`. Lives in ReaderKit so the extensions
/// can conform.
public protocol OutcomePresenter {
    /// Presents `outcome` for the already-saved `item`. Must handle all
    /// cases. Never leaves a spinner: a `.failed` or timeout outcome shows an
    /// error or marks the item failed, it does not hang.
    func present(_ outcome: Outcome, for item: SavedItem) async
}

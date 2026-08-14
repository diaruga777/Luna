//
//  ArchiveUnlockDelegate.swift
//  LunaArchiveReader
//

import UIKit

/// How `ArchiveWebReaderViewController` reports itself to whoever put it on screen.
///
/// **Having one at all is itself a statement.** `archiveReaderDidUnlockArticle` has
/// no default, so a delegate means the presenter TAKES THIS CONTROLLER AWAY the
/// moment the unlock lands — the app dismisses the modal and opens the item's own
/// reader, the extensions swap it out of their nav stack. That is what decides
/// whether the cover comes off at the end of the unlock (see `extractAndSave`).
/// The one presentation with no delegate is the `-openArchive` debug root, which has
/// nowhere to go: there the unlocked page is uncovered and stays up.
///
/// The other three legs have defaults, so a host declares only what it can do — an
/// unattended import wires the two outcomes and nothing else, and no extension can
/// offer the system-browser escape.
///
/// Conformers are small per-unlock objects in the shape `RescueFailureCardDelegate`'s
/// take, which is why the reader holds this STRONGLY: whatever builds one drops it
/// immediately (an enum with nothing to hold, a short-lived presenter, a continuation
/// scope that has already returned), while the reader stays up until the unlock
/// resolves. Each of them holds its own host weakly, so nothing cycles.
@MainActor
public protocol ArchiveUnlockDelegate: AnyObject {
    /// The article was extracted and saved. Whoever set this delegate now takes the
    /// controller away.
    func archiveReaderDidUnlockArticle(_ reader: ArchiveWebReaderViewController)

    /// `.unattended` only: the attempt has stopped and no article was saved. Called
    /// at most once, and never alongside `archiveReaderDidUnlockArticle`.
    func archiveReaderDidGiveUp(_ reader: ArchiveWebReaderViewController)

    /// `.unattended` only: the browser received more of the current page. The
    /// bulk import uses this heartbeat to reset its per-link idle deadline; it
    /// is deliberately not an outcome.
    func archiveReaderDidMakeProgress(_ reader: ArchiveWebReaderViewController)

    /// The user pressed the header's leading button. The main app dismisses the
    /// modal; extensions complete their extension request. The default dismisses the
    /// reader's own presentation, which is also what an unattended host wants: it
    /// installs the reader out of sight and non-interactive, so nobody can press it.
    func archiveReaderDidClose(_ reader: ArchiveWebReaderViewController)

    /// Whether this host can hand the archive URL to the system browser. False — the
    /// default, and every extension — hides BOTH Safari escapes (the header item and
    /// the overlay button), since an `.appex` has no `UIApplication` to open one with.
    var offersSystemBrowserEscape: Bool { get }

    /// Escape hatch for when archive.today keeps CAPTCHA-looping in the embedded web
    /// view: open the same archive URL in real Safari, which may already hold a valid
    /// `cf_clearance`. Reached only while `offersSystemBrowserEscape` is true, since
    /// that is what puts the two buttons on screen.
    func archiveReader(
        _ reader: ArchiveWebReaderViewController, openInSystemBrowser url: URL)
}

public extension ArchiveUnlockDelegate {
    func archiveReaderDidGiveUp(_ reader: ArchiveWebReaderViewController) {}

    func archiveReaderDidMakeProgress(_ reader: ArchiveWebReaderViewController) {}

    func archiveReaderDidClose(_ reader: ArchiveWebReaderViewController) {
        reader.dismiss(animated: true)
    }

    var offersSystemBrowserEscape: Bool { false }

    func archiveReader(
        _ reader: ArchiveWebReaderViewController, openInSystemBrowser url: URL
    ) {}
}

//
//  UnattendedArticleUnlock.swift
//  LunaArchiveReader
//

import LunaModels
import LunaStorage
import UIKit

/// Runs the paywall-unlock web flow with nobody watching it — the bulk import's
/// pass over the saves that came back hard-paywalled (`claudedocs/import-export.md`).
///
/// Two things make it unattended rather than merely invisible:
///
/// - **It is out of sight, not hidden.** The reader is installed full-size at the
///   BOTTOM of the key window, behind the app's own opaque UI. That matters:
///   WebKit throttles (and eventually stops) JavaScript and navigation in a web
///   view that is hidden, zero-sized or out of a window, and this flow is entirely
///   JS-driven — a DOM probe every 0.35s, a form submit, an extraction. Occluded
///   is fine; hidden is not. It is also non-interactive, so it can never take a
///   touch meant for the import sheet on top of it.
/// - **It gives up instead of asking.** `ArchiveWebReaderViewController`'s
///   `.unattended` mode reports a CAPTCHA or a dead end through
///   `archiveReaderDidGiveUp` rather than uncovering the page or showing a message,
///   and this adds the one thing the controller has no opinion about: a deadline. A
///   save that isn't unlocked is
///   left exactly as it was — titled, tappable, `.needsCaptcha` — so the user can
///   open it and solve the CAPTCHA themselves whenever they like. That is why
///   nothing here reports an error: there is no failure, only a save that stayed
///   locked.
@MainActor
public enum UnattendedArticleUnlock {

    /// How long one article gets. Generous enough for a real page load plus an
    /// archive.today round trip, short enough that a file with fifty locked
    /// articles can't hold the import open for an hour. A slow one is abandoned,
    /// not failed.
    /// `nonisolated` so `unlock` can take it as a default argument: a default
    /// is evaluated in the caller's context, which is not this actor.
    public nonisolated static let defaultTimeout: TimeInterval = 45

    /// Attempts the unlock; returns whether the article's content ended up saved.
    ///
    /// Serial by contract, not by construction — the caller runs one at a time,
    /// both because each attempt is a whole `WKWebView` and because two of them
    /// racing archive.today is the quickest way to be rate-limited.
    @discardableResult
    public static func unlock(
        itemID: UUID,
        urlString: String,
        store: SavesStore = .shared,
        timeout: TimeInterval = defaultTimeout
    ) async -> Bool {
        guard let url = URL(string: urlString), let host = hostView() else { return false }

        let reader = ArchiveWebReaderViewController(
            articleURL: url, itemID: itemID, store: store, mode: .unattended)
        // No Safari escape and no close button behavior to wire: there is no one to
        // press them, so the delegate below declares only the two outcomes and takes
        // the protocol's defaults for the rest.
        install(reader, in: host)
        defer { remove(reader) }

        let outcome = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    // Resumed exactly once: the controller reports one outcome, and
                    // the deadline below races it in a separate child task. The reader
                    // holds its delegate strongly, which is what keeps the box (and so
                    // the continuation) alive past this scope.
                    reader.delegate = OnceBox(continuation)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        return outcome
    }

    /// Guarantees one resume for a continuation the reader's two outcome legs can
    /// both reach. Main-actor bound, like the legs themselves.
    ///
    /// It IS the unlock's delegate: the two outcomes are the whole of what an
    /// unattended attempt has to hear, so the smallest honest owner of them is the
    /// thing that already exists to keep them mutually exclusive.
    @MainActor
    private final class OnceBox: ArchiveUnlockDelegate {
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func archiveReaderDidUnlockArticle(_ reader: ArchiveWebReaderViewController) {
            resume(true)
        }

        func archiveReaderDidGiveUp(_ reader: ArchiveWebReaderViewController) {
            resume(false)
        }

        private func resume(_ value: Bool) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(returning: value)
        }
    }

    // MARK: - Hosting

    /// The window to hide the unlock inside: the foreground scene's key window.
    /// Nil in an extension or before a scene exists, which is also exactly where
    /// this must never run.
    private static func hostView() -> UIView? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .windows.first { $0.isKeyWindow }
    }

    private static func install(_ reader: UIViewController, in host: UIView) {
        let view = reader.view!   // Forces `viewDidLoad`, which starts the flow.
        view.frame = host.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Behind everything the app is showing, and deaf to touches. Not
        // `isHidden`, not zero-sized, not `alpha = 0` — see the type comment.
        view.isUserInteractionEnabled = false
        host.insertSubview(view, at: 0)
        reader.beginAppearanceTransition(true, animated: false)
        reader.endAppearanceTransition()
    }

    private static func remove(_ reader: UIViewController) {
        reader.beginAppearanceTransition(false, animated: false)
        reader.viewIfLoaded?.removeFromSuperview()
        reader.endAppearanceTransition()
    }
}

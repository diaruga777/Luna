//
//  EmailLoginLoadingCover.swift
//  Luna
//
//  A button-free, full-screen cover with a centered dot-matrix spinner, installed
//  over the navigation controller's view so it also hides the Cancel/back bar
//  buttons — while a network verification round trip runs, nothing on screen can
//  be tapped. Shared by both the app-password `signIn` path and the Outlook OAuth
//  token exchange (previously the OAuth path had its own private copy of this).
//

import LunaDesignSystem
import UIKit

final class EmailLoginLoadingCover {
    private let coverView = UIView()
    private let spinner: DotMatrixSpinnerView

    /// Installs the cover over `host` (pass `navigationController?.view` so the
    /// bar buttons are covered too, falling back to the view controller's own
    /// view if it isn't in a navigation controller).
    init(host: UIView) {
        // dimension: 7 so the checkmark shape in `resolveToCheckmark` reads clearly —
        // the default 4×4 grid is too coarse for a recognizable check.
        spinner = DotMatrixSpinnerView(dimension: 7, side: 40)
        coverView.backgroundColor = .systemBackground
        coverView.isUserInteractionEnabled = true
        coverView.translatesAutoresizingMaskIntoConstraints = false

        spinner.translatesAutoresizingMaskIntoConstraints = false
        coverView.addSubview(spinner)
        host.addSubview(coverView)
        NSLayoutConstraint.activate([
            coverView.topAnchor.constraint(equalTo: host.topAnchor),
            coverView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            coverView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            coverView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            spinner.centerXAnchor.constraint(equalTo: coverView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: coverView.centerYAnchor),
        ])
        spinner.startAnimating()
    }

    /// Tears the cover down immediately (the failure path — the caller then
    /// re-enables its own UI and shows an error alert).
    func hide() {
        coverView.removeFromSuperview()
    }

    /// The success beat: the spinner resolves into a checkmark, holds briefly,
    /// then `completion` runs (the caller dismisses the modal from it). The cover
    /// itself is left in place — its host is about to be dismissed anyway.
    func resolveToCheckmark(completion: @escaping () -> Void) {
        spinner.resolveToCheckmark(completion: completion)
    }
}

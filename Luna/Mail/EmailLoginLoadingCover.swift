//
//  EmailLoginLoadingCover.swift
//  Luna
//
//  A full-screen, button-free cover with a centered eclipse-horizon spinner. It
//  installs over the navigation controller's view, so it also hides the
//  Cancel/back bar buttons while a network verification round trip runs — nothing
//  on screen can be tapped. Shared by the app-password `signIn` path and the
//  Outlook OAuth token exchange.
//

import LunaDesignSystem
import UIKit

final class EmailLoginLoadingCover {
    private let coverView = UIView()
    private let spinner: HorizonSpinnerView

    /// Installs the cover over `host`. Pass `navigationController?.view` to
    /// cover the bar buttons too, or the view controller's own view when it has
    /// no navigation controller.
    init(host: UIView) {
        spinner = HorizonSpinnerView(side: 40)
        coverView.backgroundColor = LunaColors.background
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

    /// Tears the cover down immediately. This is the failure path: the caller
    /// re-enables its own UI and shows an error alert.
    func hide() {
        coverView.removeFromSuperview()
    }

    /// The success path. The spinner resolves into a checkmark, holds briefly,
    /// then runs `completion`, where the caller dismisses the modal. The cover
    /// stays in place, since its host is about to be dismissed anyway.
    func resolveToCheckmark(completion: @escaping () -> Void) {
        spinner.resolveToCheckmark(completion: completion)
    }
}

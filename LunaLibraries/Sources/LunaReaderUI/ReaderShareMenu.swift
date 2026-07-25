//
//  ReaderShareMenu.swift
//  LunaReaderUI
//

import UIKit

/// Hangs the share options off a share button as a native `UIMenu`.
///
/// Why the system menu rather than a hand-rolled popover: UIKit renders a button's
/// menu as the standard Liquid Glass popover AND gives the press-and-slide gesture
/// for free — touch down, the popover opens, slide onto an option without lifting,
/// release to pick it. Those thresholds are the platform's own, so a plain tap can
/// never land on an option: UIKit anchors the popover clear of the button's own
/// frame and ignores the finger until it has moved onto a row. Re-implementing that
/// with a custom long-press recogniser is exactly how you get a tap that selects
/// whatever happens to be under it.
public enum ReaderShareMenu {

    /// Makes `button` present `build()`'s menu on press.
    ///
    /// The menu is rebuilt on every press via `UIDeferredMenuElement.uncached`, so a
    /// button that outlives the article it points at (the card deck's chrome pill,
    /// the inline reader's proxy) always offers options for whatever is on screen
    /// now. `providesMenu` is fixed at install time: when false the button keeps
    /// `fallback` as an ordinary tap action, which is the app extension's
    /// single-verb share.
    public static func install(
        on button: UIButton,
        providesMenu: Bool,
        build: @escaping () -> UIMenu?,
        fallback: @escaping () -> Void
    ) {
        guard providesMenu else {
            button.addAction(UIAction { _ in fallback() }, for: .touchUpInside)
            return
        }
        button.preferredMenuElementOrder = .fixed
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { completion in
                completion(build()?.children ?? [])
            }
        ])
    }
}

//
//  KeyboardFrameObserver.swift
//  LunaWriterEditor
//

import UIKit

public protocol KeyboardFrameObserving: AnyObject {
    /// The keyboard's frame in screen coordinates. `.zero` means it is gone.
    func keyboardFrameDidChange(_ frame: CGRect)
}

/// Follows the keyboard, so the "@" overlay can flip above it and the editor
/// can keep the caret line clear of it.
public final class KeyboardFrameObserver {

    public weak var observer: KeyboardFrameObserving?

    /// The keyboard's last known frame, in SCREEN coordinates — the keyboard
    /// notifications' own frame of reference, per Apple's docs.
    public private(set) var frame: CGRect = .zero

    private let center: NotificationCenter

    public init(center: NotificationCenter = .default) {
        self.center = center
        center.addObserver(
            self, selector: #selector(keyboardWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(
            self, selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    deinit { center.removeObserver(self) }

    public var isVisible: Bool { frame.height > 0 }

    /// How much of `view`'s own bottom the keyboard covers, in `view`'s own
    /// coordinate space. Converts through the window's SCREEN — converting
    /// `frame` `from: nil` (the window) instead is wrong in Split View,
    /// Slide Over and Stage Manager, where the window is smaller than the
    /// screen the keyboard notification is measured against.
    public func keyboardOverlap(in view: UIView) -> CGFloat {
        guard isVisible, let window = view.window else { return 0 }
        let converted = view.convert(frame, from: window.screen.coordinateSpace)
        return Self.overlap(convertedKeyboardFrame: converted, viewBounds: view.bounds)
    }

    /// The pure arithmetic `keyboardOverlap(in:)` reduces to once the
    /// keyboard's frame is already in the view's own coordinate space:
    /// how much of the view's bottom, capped at the view's own height, a
    /// rectangle starting at `convertedKeyboardFrame.minY` covers. Exposed
    /// so a test can pin the geometry without a live window-server
    /// connection, which a plain `UIWindow` in a test process does not have
    /// — `UIScreen.coordinateSpace.convert` degrades to a zero rect there.
    static func overlap(convertedKeyboardFrame: CGRect, viewBounds: CGRect) -> CGFloat {
        max(0, min(viewBounds.maxY - convertedKeyboardFrame.minY, viewBounds.height))
    }

    @objc private func keyboardWillChange(_ note: Notification) {
        guard isLocal(note),
              let value = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue
        else { return }
        frame = value.cgRectValue
        observer?.keyboardFrameDidChange(frame)
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        guard isLocal(note) else { return }
        frame = .zero
        observer?.keyboardFrameDidChange(frame)
    }

    /// False only when another app's keyboard changed on a shared screen
    /// (Split View, Slide Over): this sheet's own layout has nothing to do
    /// with it. Absent on an OS that never sends the key, this reads as
    /// local — the notification came from somewhere, and it usually did.
    private func isLocal(_ note: Notification) -> Bool {
        (note.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool) ?? true
    }
}

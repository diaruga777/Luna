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

    @objc private func keyboardWillChange(_ note: Notification) {
        guard let value = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        frame = value.cgRectValue
        observer?.keyboardFrameDidChange(frame)
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        frame = .zero
        observer?.keyboardFrameDidChange(frame)
    }
}

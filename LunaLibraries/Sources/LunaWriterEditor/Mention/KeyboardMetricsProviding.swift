//
//  KeyboardMetricsProviding.swift
//  LunaWriterEditor
//

import CoreGraphics
import UIKit

/// The keyboard geometry an editor needs, without naming the concrete
/// observer: `keyboardOverlap(in:)` for the typewriter line and the "@"
/// overlay, `isVisible` for whichever caller only needs the yes/no.
public protocol KeyboardMetricsProviding: AnyObject {
    var isVisible: Bool { get }
    func keyboardOverlap(in view: UIView) -> CGFloat
}

/// The Mac root's witness: a window-hosted software keyboard never appears,
/// so nothing ever overlaps.
public final class NoKeyboardMetrics: KeyboardMetricsProviding {
    public init() {}
    public var isVisible: Bool { false }
    public func keyboardOverlap(in view: UIView) -> CGFloat { 0 }
}

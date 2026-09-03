//
//  RenderingAttributeLayer.swift
//  LunaWriterEditor
//

import UIKit

/// Names one rendering layer. The composer keeps at most one layer per id.
public struct LayerID: Hashable, RawRepresentable, ExpressibleByStringLiteral, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let markup: LayerID = "markup"
    public static let syntax: LayerID = "syntax"
    public static let authorship: LayerID = "authorship"
    public static let focus: LayerID = "focus"
    public static let annotation: LayerID = "annotation"
    /// The slot ReadAlong installs its band and trail into.
    public static let reading: LayerID = "reading"
}

/// A range and the rendering attributes one layer wants over it.
public struct RangedAttributes {
    public var range: NSRange
    public var attributes: [NSAttributedString.Key: Any]

    public init(range: NSRange, attributes: [NSAttributedString.Key: Any]) {
        self.range = range
        self.attributes = attributes
    }
}

/// One colouring pass. Layers never change geometry: only colour, background
/// and underline go through here, so a pass can be redone on scroll without
/// relaying out a line (writer-app.md §6.1).
public protocol RenderingAttributeLayer: AnyObject {
    var identifier: LayerID { get }
    /// The attributes this layer wants inside `range`. Called on the main
    /// thread, once per composed pass.
    func contributions(in range: NSRange, text: NSString) -> [RangedAttributes]
}

/// How a layer asks for its colours to be applied again.
public protocol LayerInvalidating: AnyObject {
    /// `nil` means the whole viewport.
    func invalidate(_ range: NSRange?)
}

/// Where the composer asks which characters are on screen.
public protocol RenderingViewportProviding: AnyObject {
    /// The characters on screen plus the slack the composer should also paint.
    var renderingViewportRange: NSRange { get }
}

//
//  SentenceLayoutShim.swift
//  LunaWriterEditor
//
//  Shim: delete when LunaGaze's geometry types merge.
//

import CoreGraphics
import Foundation

public struct WordLayout: Equatable {
    public var textRange: NSRange
    public var rect: CGRect

    public init(textRange: NSRange, rect: CGRect) {
        self.textRange = textRange
        self.rect = rect
    }
}

public struct SentenceLayout: Equatable {
    public var index: Int
    public var textRange: NSRange
    public var lineRects: [CGRect]
    public var words: [WordLayout]

    public init(index: Int, textRange: NSRange, lineRects: [CGRect], words: [WordLayout]) {
        self.index = index
        self.textRange = textRange
        self.lineRects = lineRects
        self.words = words
    }
}

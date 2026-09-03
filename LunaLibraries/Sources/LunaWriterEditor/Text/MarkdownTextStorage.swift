//
//  MarkdownTextStorage.swift
//  LunaWriterEditor
//

import UIKit
import LunaDesignSystem
import LunaWriterText

/// Told when the document model rescanned a range, so the rendering layers
/// drop what they cached about it.
public protocol MarkdownTextStorageObserving: AnyObject {
    func markdownTextStorage(_ storage: MarkdownTextStorage, didRescan range: NSRange)
}

/// The editor's text storage. It keeps a `MarkdownDocumentModel` in step with
/// the characters and restyles only the lines the model rescanned.
public final class MarkdownTextStorage: NSTextStorage {

    private let backing: NSMutableAttributedString
    public let model: MarkdownDocumentModel

    public weak var observer: MarkdownTextStorageObserving?

    /// Bumps on every character edit, so an async job can tell whether its
    /// answer is still about the text on screen.
    public private(set) var revision: Int = 0

    public var styler: LayoutAttributeStyler {
        didSet {
            guard styler != oldValue else { return }
            restyleAll()
        }
    }

    private var pendingEdit: (range: NSRange, replacementLength: Int)?
    private var lastRescan: NSRange?

    public init(text: String = "", styler: LayoutAttributeStyler = LayoutAttributeStyler()) {
        backing = NSMutableAttributedString(string: text)
        model = MarkdownDocumentModel(sharedText: backing.mutableString)
        self.styler = styler
        super.init()
        restyleAll()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("not used") }

    @available(*, unavailable)
    public required init(itemProviderData data: Data, typeIdentifier: String) throws {
        fatalError("not used")
    }

    // MARK: - NSTextStorage

    public override var string: String { backing.string }

    public override func attributes(
        at location: Int, effectiveRange range: NSRangePointer?
    ) -> [NSAttributedString.Key: Any] {
        backing.attributes(at: location, effectiveRange: range)
    }

    public override func replaceCharacters(in range: NSRange, with str: String) {
        let replacementLength = (str as NSString).length
        beginEditing()
        backing.replaceCharacters(in: range, with: str)
        if var pending = pendingEdit {
            // Two edits inside one editing group: widen to cover both.
            let start = min(pending.range.location, range.location)
            let end = max(NSMaxRange(pending.range), NSMaxRange(range))
            pending.range = NSRange(location: start, length: end - start)
            pending.replacementLength += replacementLength - range.length
            pendingEdit = pending
        } else {
            pendingEdit = (range, replacementLength)
        }
        edited(.editedCharacters, range: range, changeInLength: replacementLength - range.length)
        endEditing()
    }

    public override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        beginEditing()
        backing.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
        endEditing()
    }

    public override func processEditing() {
        if let pending = pendingEdit {
            pendingEdit = nil
            revision &+= 1
            model.apply(edit: pending.range, replacementLength: pending.replacementLength)
            let rescanned = model.rescan(
                afterEditIn: NSRange(location: pending.range.location, length: pending.replacementLength))
            styler.apply(model, to: backing, in: rescanned)
            lastRescan = rescanned
            if rescanned.length > 0 {
                edited(.editedAttributes, range: rescanned, changeInLength: 0)
            }
        }
        super.processEditing()
        if let rescanned = lastRescan {
            lastRescan = nil
            observer?.markdownTextStorage(self, didRescan: rescanned)
        }
    }

    // MARK: - Whole document

    /// Replaces everything and scans it again. Used on load and on an external
    /// change the reconciler brought in.
    public func setText(_ text: String) {
        replaceCharacters(in: NSRange(location: 0, length: length), with: text)
    }

    /// Restyles the whole document, after a font or metric change.
    public func restyleAll() {
        let whole = NSRange(location: 0, length: backing.length)
        guard whole.length > 0 else { return }
        beginEditing()
        styler.apply(model, to: backing, in: whole)
        edited(.editedAttributes, range: whole, changeInLength: 0)
        endEditing()
        observer?.markdownTextStorage(self, didRescan: whole)
    }

    /// The paragraph the offset sits in, as the model sees it.
    public func paragraphRange(containing offset: Int) -> NSRange {
        model.paragraphRange(containing: min(max(0, offset), max(0, length - 1)))
    }

    public var nsText: NSString { backing.mutableString }
}

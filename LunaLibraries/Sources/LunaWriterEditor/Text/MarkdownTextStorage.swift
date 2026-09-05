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
    func markdownTextStorage(_ storage: MarkdownTextStorage, didReplace range: NSRange, replacementLength: Int)
}

extension MarkdownTextStorageObserving {
    public func markdownTextStorage(_ storage: MarkdownTextStorage, didReplace range: NSRange, replacementLength: Int) {}
}

/// The editor's text storage. It keeps a `MarkdownDocumentModel` in step with
/// the characters and restyles only the lines the model rescanned.
public final class MarkdownTextStorage: NSTextStorage {

    private let backing: NSMutableAttributedString
    public let model: MarkdownDocumentModel

    private let observers = NSHashTable<AnyObject>.weakObjects()

    /// Observers are held weakly: the geometry provider, the syntax layer and
    /// the session all watch the same storage.
    public func addObserver(_ observer: MarkdownTextStorageObserving) {
        observers.add(observer)
    }

    public func removeObserver(_ observer: MarkdownTextStorageObserving) {
        observers.remove(observer)
    }

    private func notify(_ range: NSRange) {
        for case let observer as MarkdownTextStorageObserving in observers.allObjects {
            observer.markdownTextStorage(self, didRescan: range)
        }
    }

    /// Bumps on every character edit, so an async job can tell whether its
    /// answer is still about the text on screen.
    public private(set) var revision: Int = 0

    public var styler: LayoutAttributeStyler {
        didSet {
            guard styler != oldValue else { return }
            restyleAll()
        }
    }

    /// Seeds the next rescan. `MarkdownDocumentModel` already unions every
    /// edit applied since the last rescan into its own pending-lines range, so
    /// this only needs to name one location the edit touched.
    private var pendingRescanSeed: NSRange?
    private var lastRescan: NSRange?
    private var cachedString: String?

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

    public override var length: Int { backing.length }

    public override var string: String {
        if let cachedString { return cachedString }
        let value = backing.string
        cachedString = value
        return value
    }

    public override func attributes(
        at location: Int, effectiveRange range: NSRangePointer?
    ) -> [NSAttributedString.Key: Any] {
        backing.attributes(at: location, effectiveRange: range)
    }

    public override func replaceCharacters(in range: NSRange, with str: String) {
        let replacementLength = (str as NSString).length
        beginEditing()
        // The model's contract: mutate the shared text, then tell it what
        // changed. `apply` unions this edit into whatever is still pending
        // from an earlier edit in the same editing group, so nothing here
        // needs to reconstruct that union itself.
        backing.replaceCharacters(in: range, with: str)
        cachedString = nil
        for case let observer as MarkdownTextStorageObserving in observers.allObjects {
            observer.markdownTextStorage(self, didReplace: range, replacementLength: replacementLength)
        }
        model.apply(edit: range, replacementLength: replacementLength)
        pendingRescanSeed = NSRange(location: range.location, length: replacementLength)
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
        cachedString = nil
        if let seed = pendingRescanSeed {
            pendingRescanSeed = nil
            revision &+= 1
            let rescanned = model.rescan(afterEditIn: seed)
            styler.apply(model, to: backing, in: rescanned)
            lastRescan = rescanned
            // The characters already edited() this group covered their own
            // attributes; only tell the layout manager about the extra reach
            // of the rescan (a fence toggling colour on lines far below it).
            let covered = editedRange
            if rescanned.length > 0,
               rescanned.location < covered.location || NSMaxRange(rescanned) > NSMaxRange(covered) {
                edited(.editedAttributes, range: rescanned, changeInLength: 0)
            }
        }
        super.processEditing()
        if let rescanned = lastRescan {
            lastRescan = nil
            notify(rescanned)
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
        notify(whole)
    }

    /// The paragraph the offset sits in, as the model sees it.
    public func paragraphRange(containing offset: Int) -> NSRange {
        model.paragraphRange(containing: min(max(0, offset), max(0, length - 1)))
    }

    public var nsText: NSString { backing.mutableString }
}

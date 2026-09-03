//
//  AnnotationPresenter.swift
//  LunaWriterReadAlong
//

import CoreGraphics
import Foundation
import LunaGaze
import LunaModels
import LunaWriterModels
import UIKit

/// Owns the annotations a reader touches: the popover behind a tapped mark,
/// and the edit-menu items that make one by hand.
///
/// A mark made here is `.manual`; only the coordinator makes `.voice` ones.
/// Marks live in the open session (through `ReadAlongTextHosting`); the
/// presenter reads them back through the same host every time rather than
/// holding a copy.
public final class AnnotationPresenter: NSObject, ReadAlongMenuProviding,
                                        AnnotationPopoverDelegate,
                                        UIPopoverPresentationControllerDelegate {

    private let markStore: ReadAlongMarkStore
    private weak var coordinator: ReadAlongCoordinator?
    private weak var host: ReadAlongTextHosting?
    private weak var presenter: UIViewController?

    private var editing: Annotation?

    public init(
        markStore: ReadAlongMarkStore,
        coordinator: ReadAlongCoordinator,
        host: ReadAlongTextHosting,
        presenter: UIViewController?
    ) {
        self.markStore = markStore
        self.coordinator = coordinator
        self.host = host
        self.presenter = presenter
        super.init()
    }

    // MARK: - Tapping

    /// The mark under a point in text-container coordinates, or nil. Uses the
    /// coordinator's cached sentence geometry; nothing is re-laid out for a
    /// tap.
    public func annotation(atContainerPoint point: CGPoint) -> Annotation? {
        guard let host, let coordinator else { return nil }
        var offset: Int?
        search: for sentence in coordinator.layouts {
            for word in sentence.words where word.rect.contains(point) {
                offset = word.textRange.location
                break search
            }
        }
        guard let offset else { return nil }
        return host.storedAnnotations.first { annotation in
            guard let range = host.range(for: annotation.anchor) else { return false }
            return NSLocationInRange(offset, range)
        }
    }

    /// Opens the popover for the mark under `point`, anchored at `rect` in
    /// `sourceView`. Returns false when no mark is there.
    @discardableResult
    public func presentPopover(
        forContainerPoint point: CGPoint, from rect: CGRect, in sourceView: UIView
    ) -> Bool {
        guard let hit = annotation(atContainerPoint: point) else { return false }
        present(hit, from: rect, in: sourceView)
        return true
    }

    public func present(_ annotation: Annotation, from rect: CGRect, in sourceView: UIView) {
        guard let presenter else { return }
        editing = annotation
        let comment = annotation.noteID.flatMap { try? markStore.note($0) }?.text
        let popover = AnnotationPopoverViewController(kind: annotation.kind, commentText: comment)
        popover.delegate = self
        popover.popoverPresentationController?.sourceView = sourceView
        popover.popoverPresentationController?.sourceRect = rect
        popover.popoverPresentationController?.permittedArrowDirections = [.up, .down]
        popover.popoverPresentationController?.delegate = self
        presenter.present(popover, animated: true)
    }

    /// A popover on a compact width would otherwise become a full-screen
    /// modal with no way out; it stays a popover everywhere.
    public func adaptivePresentationStyle(
        for controller: UIPresentationController, traitCollection: UITraitCollection
    ) -> UIModalPresentationStyle {
        .none
    }

    // MARK: - Editing

    /// Makes a mark by hand over `range`.
    @discardableResult
    public func addAnnotation(kind: Annotation.Kind, over range: NSRange) -> Annotation? {
        guard let host, range.length > 0 else { return nil }
        let annotation = Annotation(
            documentID: markStore.documentID,
            kind: kind,
            source: .manual,
            anchor: host.anchor(for: range))
        host.addAnnotation(annotation)
        return annotation
    }

    public func recolour(_ annotation: Annotation, to kind: Annotation.Kind) {
        var changed = annotation
        changed.kind = kind
        host?.updateAnnotation(changed)
    }

    /// Removes the mark, and the note a comment held. A comment with no note
    /// left behind would show an empty popover for ever.
    public func delete(_ annotation: Annotation) {
        host?.removeAnnotation(annotation.id)
        if let noteID = annotation.noteID { try? markStore.deleteNote(noteID) }
    }

    // MARK: - ReadAlongMenuProviding

    public func readAlongMenuElements(for selection: NSRange) -> [UIMenuElement] {
        guard selection.length > 0 else { return [] }
        return Annotation.Kind.allCases.map { kind in
            UIAction(title: ReadAlongTheme.title(for: kind)) { [weak self] _ in
                self?.addAnnotation(kind: kind, over: selection)
            }
        }
    }

    /// The same items behind one submenu, for a host that wants a single
    /// edit-menu entry rather than five.
    public func readAlongMenu(for selection: NSRange) -> UIMenu? {
        let children = readAlongMenuElements(for: selection)
        guard !children.isEmpty else { return nil }
        return UIMenu(
            title: L10n.string("WriterReadAlong_menuAnnotate"), children: children)
    }

    // MARK: - AnnotationPopoverDelegate

    public func annotationPopover(
        _ popover: AnnotationPopoverViewController, didChange kind: Annotation.Kind
    ) {
        guard let editing else { return }
        recolour(editing, to: kind)
        var changed = editing
        changed.kind = kind
        self.editing = changed
    }

    public func annotationPopover(
        _ popover: AnnotationPopoverViewController, didEditComment text: String
    ) {
        guard let editing, let noteID = editing.noteID,
              var note = try? markStore.note(noteID)
        else { return }
        note.text = text
        try? markStore.updateNote(note)
    }

    public func annotationPopoverDidDelete(_ popover: AnnotationPopoverViewController) {
        if let editing { delete(editing) }
        editing = nil
        popover.dismiss(animated: true)
    }
}

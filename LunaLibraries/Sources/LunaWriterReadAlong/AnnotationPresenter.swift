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
public final class AnnotationPresenter: NSObject, ReadAlongMenuProviding,
                                        AnnotationPopoverDelegate {

    private let markStore: ReadAlongMarkStore
    private let layer: AnnotationLayer
    private weak var host: ReadAlongTextHosting?
    private weak var presenter: UIViewController?

    private var editing: ResolvedAnnotation?

    public init(
        markStore: ReadAlongMarkStore,
        layer: AnnotationLayer,
        host: ReadAlongTextHosting,
        presenter: UIViewController?
    ) {
        self.markStore = markStore
        self.layer = layer
        self.host = host
        self.presenter = presenter
        super.init()
    }

    // MARK: - Tapping

    /// The mark under a point in text-container coordinates, or nil.
    public func annotation(atContainerPoint point: CGPoint) -> ResolvedAnnotation? {
        guard let host else { return nil }
        for sentence in host.sentenceLayouts() {
            for word in sentence.words where word.rect.contains(point) {
                if let hit = layer.annotation(at: word.textRange.location) { return hit }
            }
        }
        return nil
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

    public func present(_ hit: ResolvedAnnotation, from rect: CGRect, in sourceView: UIView) {
        guard let presenter else { return }
        editing = hit
        let stored = (try? markStore.annotations())?.first { $0.id == hit.id }
        let comment = stored?.noteID.flatMap { try? markStore.note($0) }?.text
        let popover = AnnotationPopoverViewController(kind: hit.kind, commentText: comment)
        popover.delegate = self
        popover.popoverPresentationController?.sourceView = sourceView
        popover.popoverPresentationController?.sourceRect = rect
        popover.popoverPresentationController?.permittedArrowDirections = [.up, .down]
        presenter.present(popover, animated: true)
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
        try? markStore.append(annotation)
        layer.add(ResolvedAnnotation(id: annotation.id, range: range, kind: kind))
        return annotation
    }

    public func recolour(_ hit: ResolvedAnnotation, to kind: Annotation.Kind) {
        guard var stored = (try? markStore.annotations())?.first(where: { $0.id == hit.id })
        else { return }
        stored.kind = kind
        try? markStore.replace(stored)
        layer.add(ResolvedAnnotation(id: hit.id, range: hit.range, kind: kind))
    }

    public func delete(_ hit: ResolvedAnnotation) {
        try? markStore.remove(hit.id)
        layer.remove(hit.id)
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
        self.editing = ResolvedAnnotation(id: editing.id, range: editing.range, kind: kind)
    }

    public func annotationPopover(
        _ popover: AnnotationPopoverViewController, didEditComment text: String
    ) {
        guard let editing,
              let stored = (try? markStore.annotations())?.first(where: { $0.id == editing.id }),
              let noteID = stored.noteID,
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

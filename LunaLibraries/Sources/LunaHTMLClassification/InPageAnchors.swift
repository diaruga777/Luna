//
//  InPageAnchors.swift
//  LunaHTMLClassification
//

import Foundation
import LunaModels
import SwiftSoup

/// The page's OWN chapter marks: a table of contents whose rows are `#fragment`
/// jumps into headings further down the same page — the pattern long blog entries
/// follow. Two halves of one job live here:
///
/// 1. **Finding** the ToC container and marking it on the DOM *before* the junk
///    strippers run. Nothing else preserves it: a link-dense short list is
///    precisely what `cleanConditionally` deletes, and a `<nav>` wrapper is
///    stripped outright by both extraction layers.
/// 2. **Emitting** it as `.tableOfContents` blocks whose links carry the
///    destination's `anchorID`, and stamping that same `anchorID` onto the
///    destination blocks so the reader can resolve a jump without re-deriving
///    "is this the same page?" from a URL.
///
/// Every gate here errs toward omission, deliberately. A missed table of contents
/// costs nothing — the article reads exactly as it did before — whereas a false
/// positive turns real prose into navigation furniture, which the RSVP reader and
/// read-aloud both skip entirely.
enum InPageAnchors {

    /// Marks an element whose content is an in-page table of contents. It lives on
    /// the parsed DOM only: that document is thrown away after block emission, so
    /// the attribute never reaches persisted content or any renderer.
    static let marker = "data-luna-toc"

    /// A ToC must offer at least this many distinct working jumps. Two links are
    /// a "jump to recipe / jump to comments" pair, not a table of contents.
    static let minimumEntries = 3

    /// …and at least this many must still resolve after all the trimming passes,
    /// or the whole thing is dropped (see `resolvingAnchors`).
    static let minimumSurvivingEntries = 2

    /// The container must be a link list, not prose with links in it.
    private static let minimumLinkTextShare = 0.55

    /// Nearly every link inside the container must be an in-page jump. This is
    /// what separates a ToC from a site `<nav>` or a related-articles rail that
    /// happens to include one anchor.
    private static let minimumInPageLinkShare = 0.8

    /// A sanity bound: past this much text the element is an article body that
    /// merely contains a ToC, not the ToC itself.
    private static let maximumContainerTextLength = 3000

    /// A row's own text (a section title) stays well under this.
    private static let maximumEntryTextLength = 300

    private static let containerTags: Set<String> = ["ul", "ol", "nav", "div", "section"]

    // MARK: - Preparation (runs before any stripping)

    /// Finds the page's in-page anchor targets, normalizes the empty-`<a name>`
    /// idiom onto the element it labels, and marks every table-of-contents
    /// container. Returns the fragments that actually resolve to an element —
    /// the set `anchorID(for:…)` and the block emitter both key off.
    ///
    /// Must be called on a freshly parsed document, before the junk strip: the
    /// marker is what keeps the strip and `cleanConditionally` off the ToC.
    static func prepare(document: Document, baseURL: URL) -> Set<String> {
        let referenced = referencedFragments(in: document, baseURL: baseURL)
        guard !referenced.isEmpty else { return [] }
        normalizeEmptyAnchors(in: document, referenced: referenced)
        let resolvable = referenced.filter { targetElement(for: $0, in: document) != nil }
        // A single "jump to recipe" link is not a table of contents, but it IS an
        // in-page jump — resolution is per link, only the ToC needs a quorum.
        if resolvable.count >= minimumEntries {
            markContainers(in: document, resolvable: resolvable, baseURL: baseURL)
        }
        return resolvable
    }

    /// Every fragment some link on the page points at.
    private static func referencedFragments(in document: Document, baseURL: URL) -> Set<String> {
        guard let anchors = try? document.select("a[href]").array() else { return [] }
        return Set(anchors.compactMap { fragment(ofLink: $0, baseURL: baseURL) })
    }

    /// The fragment a link jumps to WITHIN this same document, or nil for an
    /// ordinary outbound link. A bare `#section` href is the common form; some
    /// CMSs write the whole path back out (`/post#section`), which counts only
    /// when it resolves to this very document.
    static func fragment(ofLink element: Element, baseURL: URL) -> String? {
        let raw = ((try? element.attr("href")) ?? "").trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("#") { return canonicalFragment(String(raw.dropFirst())) }
        guard raw.contains("#"),
              let absolute = try? element.attr("abs:href"),
              let url = URL(string: absolute),
              let fragment = url.fragment,
              isSameDocument(url, as: baseURL)
        else { return nil }
        return canonicalFragment(fragment)
    }

    /// Markup ids arrive already decoded by the HTML parser while hrefs may be
    /// percent-encoded, so both sides are compared in decoded form.
    private static func canonicalFragment(_ raw: String) -> String? {
        let decoded = (raw.removingPercentEncoding ?? raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : decoded
    }

    /// Same page, ignoring the fragment. Trailing slashes are normalized because
    /// `/post` and `/post/` are one document to every CMS that emits both.
    private static func isSameDocument(_ url: URL, as baseURL: URL) -> Bool {
        guard url.scheme?.lowercased() == baseURL.scheme?.lowercased(),
              url.host?.lowercased() == baseURL.host?.lowercased(),
              url.query == baseURL.query
        else { return false }
        func path(_ url: URL) -> String {
            let path = url.path
            return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        return path(url) == path(baseURL)
    }

    /// The element a fragment names — `id`, or the legacy `<a name>`.
    private static func targetElement(for fragment: String, in document: Document) -> Element? {
        if let byID = try? document.getElementById(fragment) { return byID }
        guard let named = try? document.select("a[name]").array() else { return nil }
        return named.first { identifier(of: $0) == fragment }
    }

    /// The `<a name="x"></a>` immediately-before-the-heading idiom: an empty
    /// anchor carries the id, and the heading a reader wants to land on is its
    /// SIBLING, so no id would ever reach a block. Hoist the id onto the element
    /// the anchor labels (its next sibling, else its parent) so ordinary capture
    /// finds it.
    private static func normalizeEmptyAnchors(in document: Document, referenced: Set<String>) {
        guard let anchors = try? document.select("a[name], a[id]").array() else { return }
        for anchor in anchors {
            guard let id = identifier(of: anchor), referenced.contains(id),
                  ((try? anchor.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            let host = (try? anchor.nextElementSibling()) ?? anchor.parent()
            guard let host, host.tagName() != "body", host.tagName() != "html",
                  identifier(of: host) == nil
            else { continue }
            _ = try? host.attr("id", id)
        }
    }

    /// The `id`/`name` an element is reachable by, if any.
    private static func identifier(of element: Element) -> String? {
        if let id = try? element.attr("id"), !id.isEmpty { return id }
        if element.tagName() == "a", let name = try? element.attr("name"), !name.isEmpty {
            return name
        }
        return nil
    }

    // MARK: - Container detection

    /// Marks EVERY qualifying element, not just the outermost: the marker's other
    /// job is to shield the ToC from the strip passes, and a `<nav class="toc">`
    /// wrapper has to survive on its own account for the `<ul>` inside it to
    /// reach block emission. A wrapper that does NOT qualify (a sidebar holding a
    /// ToC plus a newsletter box) is deliberately left strippable — losing the
    /// ToC with it is the omission side of the trade.
    ///
    /// The links are gathered ONCE for the whole page and credited to every
    /// container above them, rather than asking each container for its own
    /// descendant links. SwiftSoup builds a lazy query index and a selector
    /// cache on every element that answers a `select`, so a per-container
    /// query on a page with hundreds of `<div>`s and thousands of links
    /// (a reference-heavy paper) allocated tens of megabytes that lived until
    /// the document was released, and re-derived each link's fragment once
    /// per ancestor. The verdict per container is unchanged: the same link
    /// set, the same counts, the same text tests.
    private static func markContainers(in document: Document, resolvable: Set<String>, baseURL: URL) {
        guard let candidates = try? document.select(containerTags.sorted().joined(separator: ", ")),
              let anchors = try? document.select("a")
        else { return }

        var linksByContainer: [ObjectIdentifier: ContainerLinks] = [:]
        for anchor in anchors.array() {
            let inPageFragment = fragment(ofLink: anchor, baseURL: baseURL)
                .flatMap { resolvable.contains($0) ? $0 : nil }
            var parent = anchor.parent()
            while let current = parent {
                if containerTags.contains(current.tagName()) {
                    linksByContainer[ObjectIdentifier(current), default: ContainerLinks()]
                        .add(anchor, inPageFragment: inPageFragment)
                }
                parent = current.parent()
            }
        }

        for candidate in candidates.array() {
            guard let links = linksByContainer[ObjectIdentifier(candidate)],
                  qualifiesAsTableOfContents(candidate, links: links)
            else { continue }
            _ = try? candidate.attr(marker, "1")
        }
    }

    /// Every link inside one container, in document order, with the in-page
    /// tally already taken.
    private struct ContainerLinks {
        var anchors: [Element] = []
        var inPageCount = 0
        var distinctInPageFragments: Set<String> = []

        mutating func add(_ anchor: Element, inPageFragment: String?) {
            anchors.append(anchor)
            if let inPageFragment {
                inPageCount += 1
                distinctInPageFragments.insert(inPageFragment)
            }
        }
    }

    private static func qualifiesAsTableOfContents(
        _ element: Element, links: ContainerLinks
    ) -> Bool {
        guard !links.anchors.isEmpty,
              links.distinctInPageFragments.count >= minimumEntries,
              Double(links.inPageCount) >= minimumInPageLinkShare * Double(links.anchors.count)
        else { return false }

        let text = ((try? element.text()) ?? "")
        guard !text.isEmpty, text.count <= maximumContainerTextLength else { return false }
        let linkTextLength = links.anchors.reduce(0) { $0 + (((try? $1.text()) ?? "")).count }
        return Double(linkTextLength) >= minimumLinkTextShare * Double(text.count)
    }

    // MARK: - Marker queries (used by the strip passes and block emission)

    /// Whether removing this element would take a marked ToC with it.
    static func isProtected(_ element: Element) -> Bool {
        element.hasAttr(marker)
    }

    /// The outermost marked element of a nesting chain — the one whose rows are
    /// emitted (so a `<nav>`'s "Table of contents" label is included).
    static func isTableOfContentsRoot(_ element: Element) -> Bool {
        element.hasAttr(marker) && !hasMarkedAncestor(element)
    }

    /// True for anything inside a marked ToC: the generic block walk must skip it,
    /// or a nested `<li>` list would collapse its sub-entries into one bullet and
    /// the rows would be emitted twice.
    static func isInsideTableOfContents(_ element: Element) -> Bool {
        hasMarkedAncestor(element)
    }

    private static func hasMarkedAncestor(_ element: Element) -> Bool {
        var parent = element.parent()
        while let current = parent {
            if current.hasAttr(marker) { return true }
            parent = current.parent()
        }
        return false
    }

    // MARK: - Block emission

    /// One `.tableOfContents` block per distinct jump, in document order, plus the
    /// list's own label when it has one. Built from the anchors directly rather
    /// than from the `<li>` walk, so a two-level ToC stays one row per entry.
    static func blocks(
        forTableOfContentsRoot root: Element, baseURL: URL, resolvable: Set<String>
    ) -> [ArticleContent.Block] {
        guard let anchors = try? root.select("a").array() else { return [] }
        var rows: [ArticleContent.Block] = []
        var seen = Set<String>()
        for anchor in anchors {
            guard let fragment = fragment(ofLink: anchor, baseURL: baseURL),
                  resolvable.contains(fragment),
                  seen.insert(fragment).inserted
            else { continue }
            let text = collapsedText(of: anchor)
            guard text.count > 1, text.count <= maximumEntryTextLength else { continue }
            let urlString = ((try? anchor.attr("abs:href")) ?? "#\(fragment)")
            rows.append(ArticleContent.Block(
                kind: .tableOfContents, text: text,
                links: [ArticleContent.Link(
                    start: 0, length: text.utf16.count,
                    urlString: urlString, anchorID: fragment)]))
        }
        guard rows.count >= minimumEntries else { return [] }
        if let label = label(in: root) {
            rows.insert(
                ArticleContent.Block(kind: .tableOfContents, text: label, links: []), at: 0)
        }
        return rows
    }

    /// A short, link-free heading inside the container ("Table of contents", "In
    /// this article") — furniture too, so it rides along as an unlinked row and
    /// is skipped by the word stream with the rest of the list.
    private static func label(in root: Element) -> String? {
        guard let candidates = try? root.select("h1, h2, h3, h4, h5, h6, summary, strong, p").array()
        else { return nil }
        for candidate in candidates {
            guard ((try? candidate.select("a").array()) ?? []).isEmpty else { continue }
            let text = collapsedText(of: candidate)
            guard text.count > 1, text.count <= 80 else { continue }
            return text
        }
        return nil
    }

    private static func collapsedText(of element: Element) -> String {
        ((try? element.text()) ?? "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Anchor capture for destination blocks

    /// The `anchorID` to stamp on the block being emitted from `element`, or nil
    /// (the overwhelming majority). Only fragments the page actually references
    /// are recorded — an id no link points at is not a destination.
    ///
    /// Checked in priority order: the element itself (`<h2 id="intro">`), then
    /// something inside it (`<h2><a name="intro"></a>Intro</h2>`), then an
    /// unclaimed wrapper it is the FIRST emitted block of (`<section id="intro">
    /// <h2>Intro</h2>…`). `claimed` makes that last rule first-come, so a
    /// section's id lands on its heading rather than on every paragraph in it.
    static func anchorID(
        for element: Element, within container: Element,
        resolvable: Set<String>, claimed: inout Set<String>
    ) -> String? {
        guard !resolvable.isEmpty else { return nil }
        var candidates: [Element] = [element]
        appendIdentifiedElements(in: element, to: &candidates)
        var parent = element.parent()
        while let current = parent, current !== container {
            candidates.append(current)
            parent = current.parent()
        }
        for candidate in candidates {
            guard let id = identifier(of: candidate),
                  resolvable.contains(id), !claimed.contains(id)
            else { continue }
            claimed.insert(id)
            return id
        }
        return nil
    }

    /// `element` and its descendants that carry an `id` (or, for `<a>`, a
    /// `name`), in document order: what `select("[id], a[name]")` answers,
    /// walked by hand. This runs once per emitted block, and a `select` on
    /// each of several hundred block elements would leave a query index and
    /// selector cache on every one of them for the life of the document.
    private static func appendIdentifiedElements(in element: Element, to candidates: inout [Element]) {
        if element.hasAttr("id") || (element.tagName() == "a" && element.hasAttr("name")) {
            candidates.append(element)
        }
        for child in element.children() {
            appendIdentifiedElements(in: child, to: &candidates)
        }
    }

    // MARK: - Final validation

    /// Runs after every trimming pass, on the blocks that actually survived.
    ///
    /// A ToC row whose destination was trimmed away loses its link (plain text
    /// beats a tap that reopens the live page), and a table of contents left with
    /// fewer than `minimumSurvivingEntries` working jumps is dropped whole — a ToC
    /// that can't navigate is noise, not content. An in-page link in PROSE (a
    /// footnote marker) instead loses just its `anchorID`, falling back to the
    /// ordinary link behavior it had before.
    static func resolvingAnchors(_ blocks: [ArticleContent.Block]) -> [ArticleContent.Block] {
        let available = Set(blocks.compactMap(\.anchorID))
        var result = blocks
        for index in result.indices {
            guard result[index].links.contains(where: \.isInPageAnchor) else { continue }
            if result[index].kind == .tableOfContents {
                result[index].links = result[index].links.filter { link in
                    guard let anchorID = link.anchorID else { return false }
                    return available.contains(anchorID)
                }
            } else {
                for linkIndex in result[index].links.indices {
                    guard let anchorID = result[index].links[linkIndex].anchorID,
                          !available.contains(anchorID)
                    else { continue }
                    result[index].links[linkIndex].anchorID = nil
                }
            }
        }
        guard result.contains(where: { $0.kind == .tableOfContents }) else { return result }
        var dropped = Set<Int>()
        var runStart: Int?
        func closeRun(end: Int) {
            guard let start = runStart else { return }
            runStart = nil
            let working = (start..<end).filter { !result[$0].links.isEmpty }
            guard working.count < minimumSurvivingEntries else { return }
            dropped.formUnion(start..<end)
        }
        for index in result.indices {
            if result[index].kind == .tableOfContents {
                if runStart == nil { runStart = index }
            } else {
                closeRun(end: index)
            }
        }
        closeRun(end: result.count)
        guard !dropped.isEmpty else { return result }
        return result.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
    }
}

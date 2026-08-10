//
//  OnboardingHeadlineTransition.swift
//  Luna
//

import CoreText
import UIKit

/// What two states of one headline share, and what each of them says on either
/// side of that.
///
/// The rule is a single CONTINUOUS run of characters: the longest one both
/// states carry. Everything before it and everything after it belongs to one
/// state or the other, so a headline's second beat is exactly “these glyphs
/// leave, those glyphs arrive, the run between them never moves”. Whitespace
/// and punctuation are ordinary characters here — “Miss a sale” → “Never miss a
/// sale” keeps “iss a sale” and animates the capital away, and “Sign up to
/// watch.” → “No sign up needed.” keeps “ign up ” with fragments
/// arriving on BOTH sides of it.
///
/// Pure text, deliberately: which glyphs animate is decided here, where it can
/// be reasoned about and tested without a view or a font.
struct OnboardingHeadlineTransition: Equatable {
    /// An anchor has to be worth standing still for. One character — very often
    /// a lone space or a stray “a” — reads as a rendering fault rather than a
    /// word held in place, so a run that short is no anchor at all and the
    /// headline replaces itself outright.
    private static let minimumAnchorLength = 2

    /// The run both states carry. Empty when they share nothing usable.
    let shared: String
    let initialPrefix: String
    let initialSuffix: String
    let finalPrefix: String
    let finalSuffix: String

    var initialText: String { initialPrefix + shared + initialSuffix }
    var finalText: String { finalPrefix + shared + finalSuffix }

    /// True when there is no anchor: everything the first state said leaves and
    /// everything the second says arrives, each centred on its own.
    var isFullReplacement: Bool { shared.isEmpty }

    /// The fragments the FIRST beat puts on screen, and the second takes away.
    var departingFragments: [String] {
        [initialPrefix, initialSuffix].filter { !$0.isEmpty }
    }

    /// The fragments only the SECOND beat brings in.
    var arrivingFragments: [String] {
        [finalPrefix, finalSuffix].filter { !$0.isEmpty }
    }

    init(from initialText: String, to finalText: String) {
        let initial = Array(initialText)
        let final = Array(finalText)
        guard let run = Self.longestSharedRun(initial, final) else {
            shared = ""
            initialPrefix = initialText
            initialSuffix = ""
            finalPrefix = finalText
            finalSuffix = ""
            return
        }
        shared = String(initial[run.initialStart..<(run.initialStart + run.length)])
        initialPrefix = String(initial[0..<run.initialStart])
        initialSuffix = String(initial[(run.initialStart + run.length)...])
        finalPrefix = String(final[0..<run.finalStart])
        finalSuffix = String(final[(run.finalStart + run.length)...])
    }

    private struct Run {
        var initialStart: Int
        var finalStart: Int
        var length: Int
    }

    /// The longest run of characters common to both, or nil when the best one
    /// is not an anchor. Ties go to the run that appears earliest in the FINAL
    /// text (then earliest in the initial): an arbitrary choice, but a stable
    /// one, so the same copy always animates the same way.
    private static func longestSharedRun(
        _ initial: [Character],
        _ final: [Character]
    ) -> Run? {
        guard !initial.isEmpty, !final.isEmpty else { return nil }
        var previousRow = [Int](repeating: 0, count: final.count + 1)
        var best: Run?
        for i in initial.indices {
            var row = [Int](repeating: 0, count: final.count + 1)
            for j in final.indices where initial[i] == final[j] {
                let length = previousRow[j] + 1
                row[j + 1] = length
                let candidate = Run(
                    initialStart: i - length + 1,
                    finalStart: j - length + 1,
                    length: length)
                if Self.isBetter(candidate, than: best) { best = candidate }
            }
            previousRow = row
        }
        guard let best, best.length >= minimumAnchorLength else { return nil }
        // A run of nothing but spaces and punctuation is a coincidence of
        // typography, not a word the eye tracks: “Hi!” → “Ho!” should replace
        // itself rather than pin its exclamation mark.
        let candidate = initial[best.initialStart..<(best.initialStart + best.length)]
        guard candidate.contains(where: { $0.isLetter || $0.isNumber }) else {
            return nil
        }
        return best
    }

    private static func isBetter(_ candidate: Run, than best: Run?) -> Bool {
        guard let best else { return true }
        if candidate.length != best.length { return candidate.length > best.length }
        if candidate.finalStart != best.finalStart {
            return candidate.finalStart < best.finalStart
        }
        return candidate.initialStart < best.initialStart
    }
}

/// One sentence becoming another in two beats, with the words they share never
/// moving.
///
/// Beat one is the initial sentence arriving under the lunar front. Beat two is
/// the difference: every fragment the two states do not share either leaves or
/// arrives, and the shared run — already on screen, already in its FINAL
/// position — is not touched at all.
///
/// The geometry is the whole trick. The finished sentence is centred; the
/// initial one is typeset wherever it has to sit for the shared run to land in
/// that same place, which is left of centre when the sentence grows on the
/// right (“Read.” → “Read more.”) and right of centre when it grows on the left
/// (“Miss a sale” → “Never miss a sale”). Nothing translates, because nothing
/// was ever anywhere else.
///
/// Every fragment renders the WHOLE composition it belongs to with every
/// character but its own in clear ink, so a fragment's position comes from the
/// real typesetting of its sentence rather than a measured offset. Their
/// occluders are clear because they overlap: a front hides text by removing it
/// from the mask geometrically, and a black disc wide enough to cover one
/// fragment would cover its neighbours too.
///
/// The departures get their own fronts rather than sharing the arrivals'. A
/// period's ink sits a whole x-height below “more”'s, so one edge descending
/// through the shared frame uncovers the top of the “m” a third of a second
/// before it reaches the period still standing to its left — long enough to
/// read the wrong sentence. Each departing fragment's front is placed against
/// its own ink instead, so it goes out as the arrivals come in.
///
/// **A headline may be more than one line**, and each line runs this whole
/// arrangement on its own copy (`OnboardingIntroCopy.lines`). The view is as
/// tall as all of them from the moment it is built, so a line the second beat
/// brings in occupies room that was reserved for it rather than pushing the
/// line above it anywhere: the Downloader says the same first line in both
/// states — nothing to animate, nothing to move — and its second line, which
/// the initial copy does not contain at all, arrives under its own front while
/// the first stands still.
final class OnboardingIntroHeadlineView: UIView {
    static let lineHeight: CGFloat = 44
    /// The size the copy is set at when it fits. Narrow cards shrink from here;
    /// nothing ever grows past it.
    static let baseFontSize: CGFloat = 25
    /// The floor a shrink stops at. Copy that still overflows here overhangs
    /// the headline rather than becoming unreadable — this view never clips.
    static let minimumFontSize: CGFloat = 13

    /// The five places a fragment can be. A nil is a fragment the copy does not
    /// have: “Read.” → “Read more.” has no prefixes at all.
    struct Fragments {
        var initialPrefix: MoonRevealLineView?
        var shared: MoonRevealLineView?
        var initialSuffix: MoonRevealLineView?
        var finalPrefix: MoonRevealLineView?
        var finalSuffix: MoonRevealLineView?

        /// What the first beat puts on screen: the initial sentence, whole.
        var initialSentence: [MoonRevealLineView] {
            [initialPrefix, shared, initialSuffix].compactMap { $0 }
        }
        /// What the second beat takes away.
        var departing: [MoonRevealLineView] {
            [initialPrefix, initialSuffix].compactMap { $0 }
        }
        /// What the second beat brings in.
        var arriving: [MoonRevealLineView] {
            [finalPrefix, finalSuffix].compactMap { $0 }
        }
        var all: [MoonRevealLineView] {
            [initialPrefix, initialSuffix, shared, finalPrefix, finalSuffix]
                .compactMap { $0 }
        }
    }

    /// One LINE of the headline: its own two states, and the fragment views
    /// that draw them. Most copy is a single line; a headline whose second beat
    /// adds a line beneath the first, rather than growing the sentence already
    /// on screen, is two.
    final class Line {
        let transition: OnboardingHeadlineTransition
        /// Empty until the view has a width to typeset against.
        fileprivate(set) var fragments = Fragments()

        fileprivate init(transition: OnboardingHeadlineTransition) {
            self.transition = transition
        }
    }

    /// Never empty: copy with no newline in it is one line.
    let lines: [Line]

    /// The first line's transition — the whole of it for the single-line copy
    /// every app but the Downloader ships.
    var transition: OnboardingHeadlineTransition { lines[0].transition }
    /// The first line's fragment views, for the same reason.
    var fragments: Fragments { lines[0].fragments }

    /// What the headline says in each beat, lines and all. A line that says
    /// nothing in a beat contributes nothing to it rather than a blank line, so
    /// this is exactly the copy — and exactly what is spoken.
    var initialText: String { joined(lines.map { $0.transition.initialText }) }
    var finalText: String { joined(lines.map { $0.transition.finalText }) }
    /// Room for every line from the start, so one arriving later moves nothing.
    var height: CGFloat { Self.lineHeight * CGFloat(lines.count) }

    /// Every fragment on the view, whichever line it belongs to.
    var allFragments: [MoonRevealLineView] { lines.flatMap { $0.fragments.all } }

    /// The size the fragments were built at, once they exist.
    private(set) var font: UIFont?

    private var didStartBeats = false
    private var showsFinishedState = false

    init(copy: OnboardingIntroCopy) {
        lines = copy.lines.map {
            Line(transition: OnboardingHeadlineTransition(
                from: $0.initialText, to: $0.finalText))
        }
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        // Nothing is spoken until a beat has actually put glyphs on screen: a
        // sentence still waiting behind its front is not on the card yet.
        isAccessibilityElement = false
        clipsToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let fitted = fittedFont(in: bounds.width)
        // Rebuilding means new labels with new compositions, which a running
        // front would lose. A beat that has begun keeps the size it began at.
        if font != fitted, !didStartBeats { rebuild(with: fitted) }
        positionFragments()
    }

    /// How far ahead of the arrivals a departing fragment's front starts, by
    /// fragment text. Zero for a fragment whose own ink is already at least as
    /// high as everything arriving beside it — “beside it” being its OWN line,
    /// since a fragment two lines down is not something it has to go out with.
    func frontLead(forDeparting fragment: String, onLine index: Int = 0) -> CGFloat {
        guard let font, lines.indices.contains(index) else { return 0 }
        let arriving = lines[index].transition.arrivingFragments
        guard !arriving.isEmpty else { return 0 }
        let reference = arriving
            .map { Self.inkTopAboveBaseline($0, font: font) }
            .max() ?? 0
        return max(reference - Self.inkTopAboveBaseline(fragment, font: font), 0)
    }

    /// The initial sentence arrives, whole, under one front. A line the initial
    /// copy does not reach has nothing here and stays behind its own front.
    func revealFirstBeat(duration: TimeInterval, completion: @escaping () -> Void) {
        didStartBeats = true
        sweep(
            lines.flatMap { $0.fragments.initialSentence }.map { fragment in
                { done in fragment.reveal(duration: duration, completion: done) }
            },
            spokenText: initialText,
            completion: completion)
    }

    /// The difference plays: fragments arrive as fragments leave, all in the
    /// same turn and at the same pace, and the shared run is not part of it. A
    /// line whose two states are identical contributes no operation at all —
    /// which is how a first line stands perfectly still while a second arrives.
    func revealSecondBeat(duration: TimeInterval, completion: @escaping () -> Void) {
        didStartBeats = true
        var operations: [(@escaping () -> Void) -> Void] = []
        for (index, line) in lines.enumerated() {
            operations += line.fragments.arriving.map { fragment in
                { done in fragment.reveal(duration: duration, completion: done) }
            }
            operations += zip(
                line.fragments.departing, line.transition.departingFragments
            ).map { fragment, text in
                { done in
                    fragment.conceal(
                        duration: duration,
                        frontLead: self.frontLead(forDeparting: text, onLine: index),
                        completion: done)
                }
            }
        }
        sweep(operations, spokenText: finalText, completion: completion)
    }

    /// The headline as both beats leave it, with neither beat playing. A card
    /// paged back to shows the sentence it already said rather than saying it
    /// again — the reveal belongs to the launch.
    func showFinishedState() {
        showsFinishedState = true
        applyFinishedState()
    }

    private func applyFinishedState() {
        for line in lines {
            for fragment in line.fragments.departing { fragment.showFullyConcealed() }
            for fragment in [line.fragments.shared] + line.fragments.arriving.map(Optional.some) {
                fragment?.showFullyRevealed()
            }
        }
        for fragment in allFragments { fragment.isAccessibilityElement = false }
        isAccessibilityElement = true
        accessibilityLabel = finalText
    }

    /// The lines that have something to say in a beat, joined the way the copy
    /// was written. A line contributing nothing is dropped rather than left as
    /// a blank one, so VoiceOver reads the sentence and not the layout.
    private func joined(_ texts: [String]) -> String {
        texts.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func sweep(
        _ operations: [(@escaping () -> Void) -> Void],
        spokenText: String,
        completion: @escaping () -> Void
    ) {
        // One sentence, one element: the fragments are typography, not several
        // separate things to swipe through.
        let finish = { [weak self] in
            guard let self else { return }
            for fragment in self.allFragments { fragment.isAccessibilityElement = false }
            self.isAccessibilityElement = true
            self.accessibilityLabel = spokenText
            completion()
        }
        // A beat with nothing to do still ends — two states that share
        // everything but say it identically owe the caller its completion.
        guard !operations.isEmpty else {
            finish()
            return
        }
        var remaining = operations.count
        let step = {
            remaining -= 1
            guard remaining == 0 else { return }
            finish()
        }
        for operation in operations { operation(step) }
    }

    // MARK: - Building

    private func rebuild(with font: UIFont) {
        for fragment in allFragments { fragment.removeFromSuperview() }
        self.font = font
        for line in lines { line.fragments = Self.build(line.transition, font: font) }
        // Departures go behind, so their own bloom never washes over the words
        // that stay; arrivals go in front of nothing they could hide.
        for line in lines {
            let built = line.fragments
            for fragment in built.departing
                + [built.shared].compactMap({ $0 }) + built.arriving
            {
                addSubview(fragment)
            }
        }
        if showsFinishedState { applyFinishedState() }
    }

    private static func build(
        _ transition: OnboardingHeadlineTransition,
        font: UIFont
    ) -> Fragments {
        let initial = transition.initialText as NSString
        let final = transition.finalText as NSString
        let initialPrefixLength = (transition.initialPrefix as NSString).length
        let finalPrefixLength = (transition.finalPrefix as NSString).length
        let sharedLength = (transition.shared as NSString).length

        var built = Fragments()
        if initialPrefixLength > 0 {
            built.initialPrefix = Self.line(
                initial, font: font,
                visible: NSRange(location: 0, length: initialPrefixLength))
        }
        let initialSuffixStart = initialPrefixLength + sharedLength
        if initial.length > initialSuffixStart {
            built.initialSuffix = Self.line(
                initial, font: font,
                visible: NSRange(
                    location: initialSuffixStart,
                    length: initial.length - initialSuffixStart))
        }
        // The shared run is drawn from the FINAL composition: it is where that
        // sentence puts it that everything else is arranged around.
        if sharedLength > 0 {
            built.shared = Self.line(
                final, font: font,
                visible: NSRange(location: finalPrefixLength, length: sharedLength))
        }
        if finalPrefixLength > 0 {
            built.finalPrefix = Self.line(
                final, font: font,
                visible: NSRange(location: 0, length: finalPrefixLength))
        }
        let finalSuffixStart = finalPrefixLength + sharedLength
        if final.length > finalSuffixStart {
            built.finalSuffix = Self.line(
                final, font: font,
                visible: NSRange(
                    location: finalSuffixStart,
                    length: final.length - finalSuffixStart))
        }
        return built
    }

    private func positionFragments() {
        guard let font else { return }
        for (index, line) in lines.enumerated() {
            let metrics = Metrics(transition: line.transition, font: font)
            let origins = metrics.origins(inContainerWidth: bounds.width)
            // Each line keeps its own band, reserved whether or not it has
            // anything on it yet, so a line arriving in the second beat lands
            // where it always was rather than displacing the one above it.
            let top = CGFloat(index) * Self.lineHeight
            // Left-aligned from one shared origin per sentence: every fragment
            // then lands where its own sentence puts it, whatever the trailing
            // glyphs of its composition are. The two points of slack keep a
            // label whose text measures its own width from shrinking to fit
            // itself.
            let initialBlock = CGRect(
                x: origins.initial,
                y: top,
                width: metrics.initialWidth.rounded(.up) + 2,
                height: Self.lineHeight)
            let finalBlock = CGRect(
                x: origins.final,
                y: top,
                width: metrics.finalWidth.rounded(.up) + 2,
                height: Self.lineHeight)
            for fragment in line.fragments.departing { fragment.frame = initialBlock }
            for fragment in ([line.fragments.shared] + line.fragments.arriving)
                .compactMap({ $0 })
            {
                fragment.frame = finalBlock
            }
        }
    }

    /// The widest line decides the size: one headline is set in one font, so a
    /// line that has to shrink takes the others down with it.
    private func unionWidth(at font: UIFont) -> CGFloat {
        lines.map { Metrics(transition: $0.transition, font: font).unionWidth }
            .max() ?? 0
    }

    private func fittedFont(in width: CGFloat) -> UIFont {
        let base = Self.font(ofSize: Self.baseFontSize)
        let needed = unionWidth(at: base)
        guard needed > width, width > 0 else { return base }
        // Advances are very nearly linear in point size, so one division lands
        // at or just past the answer; the loop covers the hinting that makes it
        // “very nearly”.
        var size = max(
            Self.minimumFontSize,
            (Self.baseFontSize * width / needed).rounded(.down))
        var font = Self.font(ofSize: size)
        while size > Self.minimumFontSize, unionWidth(at: font) > width {
            size -= 0.5
            font = Self.font(ofSize: size)
        }
        return font
    }

    private static func font(ofSize size: CGFloat) -> UIFont {
        .systemFont(ofSize: size, weight: .semibold)
    }

    /// Where each sentence's block starts, and how wide the two of them are
    /// together. The final sentence is centred; the initial one sits wherever
    /// the shared run's final position puts it.
    private struct Metrics {
        let initialWidth: CGFloat
        let finalWidth: CGFloat
        /// How far the initial sentence's block sits from the final one's.
        let initialOffset: CGFloat

        init(transition: OnboardingHeadlineTransition, font: UIFont) {
            initialWidth = Metrics.width(transition.initialText, font: font)
            finalWidth = Metrics.width(transition.finalText, font: font)
            initialOffset = transition.isFullReplacement
                // Nothing is anchored, so each sentence is simply centred; the
                // offset is whatever keeps both midpoints together.
                ? (finalWidth - initialWidth) / 2
                : Metrics.width(transition.finalPrefix, font: font)
                    - Metrics.width(transition.initialPrefix, font: font)
        }

        /// The room both sentences need side by side — what a shrink has to fit.
        var unionWidth: CGFloat {
            max(finalWidth, initialOffset + initialWidth) - min(0, initialOffset)
        }

        func origins(inContainerWidth width: CGFloat) -> (initial: CGFloat, final: CGFloat) {
            let final = max(((width - finalWidth) / 2).rounded(), 0)
            // Unrounded on purpose: the initial sentence's own fragments share
            // one origin whatever it is, and the seam that matters — its
            // prefix meeting the shared run — is exact only if this is.
            return (final + initialOffset, final)
        }

        /// Kerning off, ligatures off: every fragment's advance widths are then
        /// the plain sum of its glyphs', so the two compositions agree on where
        /// the shared run begins and a fragment can be measured on its own.
        private static func width(_ string: String, font: UIFont) -> CGFloat {
            guard !string.isEmpty else { return 0 }
            return NSAttributedString(
                string: string,
                attributes: [.font: font, .kern: 0, .ligature: 0]
            ).size().width
        }
    }

    private static func line(
        _ composition: NSString,
        font: UIFont,
        visible: NSRange
    ) -> MoonRevealLineView {
        MoonRevealLineView(
            text: composition.substring(with: visible),
            styledText: styled(composition, font: font, visible: visible),
            font: font,
            textAlignment: .left,
            minimumScaleFactor: 1,
            occluderColor: .clear)
    }

    /// The whole composition, with only `visible` in white ink.
    private static func styled(
        _ composition: NSString,
        font: UIFont,
        visible: NSRange
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byClipping
        let text = NSMutableAttributedString(
            string: composition as String,
            attributes: [
                .font: font,
                .kern: 0,
                .ligature: 0,
                .foregroundColor: UIColor.clear,
                .paragraphStyle: paragraph,
            ])
        text.addAttribute(.foregroundColor, value: UIColor.white, range: visible)
        return text
    }

    /// How high a fragment's visible ink reaches above the sentence's baseline.
    /// Ink, not typography: the line box of a period is as tall as the line box
    /// of an “m”, and it is the visible dot that has to go out when the “m”
    /// arrives.
    private static func inkTopAboveBaseline(_ string: String, font: UIFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: string, attributes: [.font: font]))
        return CTLineGetImageBounds(line, nil).maxY
    }
}

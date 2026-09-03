//
//  ReadAlongDiagnosticsView.swift
//  LunaWriterReadAlong
//

import CoreGraphics
import Foundation
import LunaDesignSystem
import LunaGaze
import LunaModels
import LunaWriterModels
import UIKit

/// One frame of what read-along believes, for the diagnostics overlay.
public struct ReadAlongDiagnosticsSnapshot: Equatable {
    /// The calibrated gaze, in text-container coordinates.
    public var gaze: CGPoint?
    public var fixation: Fixation?
    public var gate: GateReason
    public var reading: ReadingState
    public var wordsPerMinute: Double
    public var grade: CalibrationVerdict.Grade?
    /// Text-container origin minus content offset.
    public var offset: CGPoint
    public var sentences: [SentenceLayout]
    public var pointsPerDegree: CGFloat

    public init(
        gaze: CGPoint?,
        fixation: Fixation?,
        gate: GateReason,
        reading: ReadingState,
        wordsPerMinute: Double,
        grade: CalibrationVerdict.Grade?,
        offset: CGPoint,
        sentences: [SentenceLayout],
        pointsPerDegree: CGFloat
    ) {
        self.gaze = gaze
        self.fixation = fixation
        self.gate = gate
        self.reading = reading
        self.wordsPerMinute = wordsPerMinute
        self.grade = grade
        self.offset = offset
        self.sentences = sentences
        self.pointsPerDegree = pointsPerDegree
    }
}

/// Shows the gaze estimate over the text: the raw dot, the fixation it is in,
/// a likelihood bar beside each visible sentence, and one panel of numbers.
///
/// The bars are the view's OWN estimate of the vertical likelihood, drawn from
/// the gaze and the sentence bands. `ReadingTracker` keeps its per-sentence
/// scores private, and a diagnostic that had to be fed from inside the model
/// would change what it measures.
public final class ReadAlongDiagnosticsView: UIView {

    private var snapshot: ReadAlongDiagnosticsSnapshot?
    private let panel = UILabel()

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        panel.numberOfLines = 0
        panel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        panel.textColor = LunaColors.primaryText
        panel.backgroundColor = LunaColors.secondaryBackground.withAlphaComponent(0.85)
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 8),
            panel.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
        ])
        registerForTraitChanges([LunaSkyTrait.self]) {
            (self: ReadAlongDiagnosticsView, _: UITraitCollection) in
            self.setNeedsDisplay()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public func update(_ snapshot: ReadAlongDiagnosticsSnapshot) {
        self.snapshot = snapshot
        panel.text = Self.panelText(snapshot)
        setNeedsDisplay()
    }

    /// The numbers, in the order they are read while debugging: what the gate
    /// says, what the model is doing, and how far off it is.
    static func panelText(_ snapshot: ReadAlongDiagnosticsSnapshot) -> String {
        let residual = snapshot.reading.residual / max(snapshot.pointsPerDegree, 1e-6)
        let grade = snapshot.grade?.rawValue ?? "—"
        return String(
            format: "gate %@\nmode %@\nquality %.2f\nresidual %.2f°\nwpm %.0f\ngrade %@",
            snapshot.gate.rawValue,
            snapshot.reading.mode.rawValue,
            snapshot.reading.quality,
            Double(residual),
            snapshot.wordsPerMinute,
            grade)
    }

    public override func draw(_ rect: CGRect) {
        guard let snapshot, let context = UIGraphicsGetCurrentContext() else { return }
        drawBars(snapshot, in: context)
        drawFixation(snapshot, in: context)
        drawGaze(snapshot, in: context)
    }

    private func drawBars(_ snapshot: ReadAlongDiagnosticsSnapshot, in context: CGContext) {
        guard let gaze = snapshot.gaze else { return }
        let sigma = Double(2.0 * snapshot.pointsPerDegree)
        for sentence in snapshot.sentences {
            let bounds = sentence.bounds.offsetBy(dx: snapshot.offset.x, dy: snapshot.offset.y)
            guard bounds.maxY > 0, bounds.minY < self.bounds.height else { continue }
            let dy = Double(sentence.bounds.midY - gaze.y)
            let likelihood = exp(-0.5 * (dy / sigma) * (dy / sigma))
            let width = CGFloat(likelihood) * 46
            guard width > 0.5 else { continue }
            let bar = CGRect(x: 2, y: bounds.midY - 2, width: width, height: 4)
            let active = sentence.index == snapshot.reading.activeSentence
            context.setFillColor(
                (active ? ReadAlongTheme.keep : LunaColors.tertiaryText)
                    .resolvedColor(with: traitCollection).withAlphaComponent(0.8).cgColor)
            context.fill(bar)
        }
    }

    private func drawFixation(_ snapshot: ReadAlongDiagnosticsSnapshot, in context: CGContext) {
        guard let fixation = snapshot.fixation else { return }
        let centre = CGPoint(
            x: fixation.point.x + snapshot.offset.x, y: fixation.point.y + snapshot.offset.y)
        let radius = 1.3 * snapshot.pointsPerDegree
        context.setStrokeColor(
            ReadAlongTheme.expand.resolvedColor(with: traitCollection)
                .withAlphaComponent(0.7).cgColor)
        context.setLineWidth(1)
        context.strokeEllipse(
            in: CGRect(
                x: centre.x - radius, y: centre.y - radius,
                width: radius * 2, height: radius * 2))
    }

    private func drawGaze(_ snapshot: ReadAlongDiagnosticsSnapshot, in context: CGContext) {
        guard let gaze = snapshot.gaze else { return }
        let centre = CGPoint(x: gaze.x + snapshot.offset.x, y: gaze.y + snapshot.offset.y)
        context.setFillColor(
            ReadAlongTheme.cut.resolvedColor(with: traitCollection).cgColor)
        context.fillEllipse(
            in: CGRect(x: centre.x - 4, y: centre.y - 4, width: 8, height: 8))
    }
}

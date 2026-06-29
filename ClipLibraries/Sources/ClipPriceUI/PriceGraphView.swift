//
//  PriceGraphView.swift
//  ShareKit
//

import ClipDesignSystem
import ClipModels
import UIKit

/// A compact price-history line chart with a press-and-drag scrubber. Given the
/// aggregated `PriceGraphPoint` series + display currency, it draws the line, y-axis
/// min/max, and x-axis endpoint dates; pressing/dragging highlights the nearest
/// point and shows a callout with its value, date, and store host.
public final class PriceGraphView: UIView {

    private var points: [PriceGraphPoint] = []
    private var currency = "USD"
    private var selectedIndex: Int?
    /// When true, draws a faux "graph-shaped" skeleton + caption instead of real data.
    private var isPlaceholder = false

    private let calloutView = UIView()
    private let calloutLabel = UILabel()
    private let plotInsets = UIEdgeInsets(top: 14, left: 58, bottom: 34, right: 16)

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = false
        configureCallout()
        let press = UILongPressGestureRecognizer(target: self, action: #selector(scrub(_:)))
        press.minimumPressDuration = 0
        addGestureRecognizer(press)
    }
    public required init?(coder: NSCoder) { fatalError("not used") }

    public func setData(_ points: [PriceGraphPoint], currency: String) {
        self.points = points
        self.currency = currency
        self.selectedIndex = nil
        self.isPlaceholder = false
        calloutView.isHidden = true
        setNeedsDisplay()
    }

    /// Shows a graph-shaped placeholder (faint axes + a dashed sample line + caption)
    /// so the empty state reads as "a graph will appear here", not just text.
    public func showPlaceholder() {
        self.points = []
        self.selectedIndex = nil
        self.isPlaceholder = true
        calloutView.isHidden = true
        setNeedsDisplay()
    }

    // MARK: - Drawing

    public override func draw(_ rect: CGRect) {
        if isPlaceholder { drawPlaceholder(rect); return }
        guard points.count >= 2, let context = UIGraphicsGetCurrentContext() else { return }
        let plot = rect.inset(by: plotInsets)
        let prices = points.map { ($0.price as NSDecimalNumber).doubleValue }
        let rawMinPrice = prices.min() ?? 0
        let rawMaxPrice = prices.max() ?? 0
        let domain = yDomain(min: rawMinPrice, max: rawMaxPrice)
        let priceSpan = max(domain.max - domain.min, 0.0001)
        let dates = points.map { $0.date.timeIntervalSinceReferenceDate }
        let minDate = dates.first ?? 0, maxDate = dates.last ?? 1
        let dateSpan = max(maxDate - minDate, 1)

        func point(at index: Int) -> CGPoint {
            let x = plot.minX + CGFloat((dates[index] - minDate) / dateSpan) * plot.width
            let y = plot.maxY - CGFloat((prices[index] - domain.min) / priceSpan) * plot.height
            return CGPoint(x: x, y: y)
        }

        func y(for price: Double) -> CGFloat {
            plot.maxY - CGFloat((price - domain.min) / priceSpan) * plot.height
        }

        drawGrid(in: plot, context: context)

        // Filled area + line.
        let line = UIBezierPath()
        for index in points.indices {
            let p = point(at: index)
            if index == 0 { line.move(to: p) } else { line.addLine(to: p) }
        }
        let accent = GlassStyle.readingAccent
        accent.withAlphaComponent(0.12).setFill()
        let fill = line.copy() as! UIBezierPath
        fill.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        fill.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
        fill.close()
        fill.fill()
        accent.setStroke()
        line.lineWidth = 2
        line.lineJoinStyle = .round
        line.stroke()

        // y-axis labels live in a dedicated left gutter and are anchored to the actual
        // price value they describe. A flat series therefore gets one label on the line,
        // not duplicate labels at the padded domain bounds.
        drawYAxisLabels(
            candidates: [
                (price: rawMaxPrice, y: y(for: rawMaxPrice)),
                (price: rawMinPrice, y: y(for: rawMinPrice)),
            ],
            labelX: plot.minX - 6,
            plot: plot)
        // x-axis endpoint dates sit below the plot baseline.
        drawAxisLabel(Self.axisDate(points.first!.date),
                      at: CGPoint(x: plot.minX, y: plot.maxY + 8), align: .left)
        drawAxisLabel(Self.axisDate(points.last!.date),
                      at: CGPoint(x: plot.maxX, y: plot.maxY + 8), align: .right)

        // Scrubber.
        if let index = selectedIndex, points.indices.contains(index) {
            let p = point(at: index)
            context.setStrokeColor(UIColor.tertiaryLabel.cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: p.x, y: plot.minY))
            context.addLine(to: CGPoint(x: p.x, y: plot.maxY))
            context.strokePath()
            accent.setFill()
            UIBezierPath(ovalIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)).fill()
            UIColor.systemBackground.setStroke()
            let ring = UIBezierPath(ovalIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }

    /// A clean empty-state skeleton: faint horizontal gridlines, solid x/y axes,
    /// and "Price"/"Time" axis labels — so it reads as a price-over-time chart that
    /// just has no data yet (no faux trend line).
    private func drawPlaceholder(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let plot = rect.inset(by: plotInsets)
        drawGrid(in: plot, context: context)
        // Solid x and y axes.
        context.setStrokeColor(UIColor.tertiaryLabel.cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: plot.minX, y: plot.minY))
        context.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
        context.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        context.strokePath()
        // Axis labels (price on y, time on x) + a faint centered caption.
        drawAxisLabel("Price", at: CGPoint(x: plot.minX - 6, y: plot.minY - 1), align: .right)
        drawAxisLabel("Time", at: CGPoint(x: plot.maxX, y: plot.maxY + 8), align: .right)
        let caption = "Awaiting more data"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: UIColor.tertiaryLabel,
        ]
        let size = (caption as NSString).size(withAttributes: attrs)
        (caption as NSString).draw(
            at: CGPoint(x: plot.midX - size.width / 2, y: plot.midY - size.height / 2), withAttributes: attrs)
    }

    private enum LabelAlign { case left, right }
    private static let axisLabelHeight: CGFloat = 13

    private func yDomain(min: Double, max: Double) -> (min: Double, max: Double) {
        if abs(max - min) < 0.0001 {
            let padding = Swift.max(abs(max) * 0.02, 1)
            return (min - padding, max + padding)
        }
        let padding = (max - min) * 0.12
        return (min - padding, max + padding)
    }

    private func drawGrid(in plot: CGRect, context: CGContext) {
        context.setStrokeColor(UIColor.quaternaryLabel.withAlphaComponent(0.45).cgColor)
        context.setLineWidth(1)
        let rows = 3
        for i in 0...rows {
            let y = plot.minY + plot.height * CGFloat(i) / CGFloat(rows)
            context.move(to: CGPoint(x: plot.minX, y: y))
            context.addLine(to: CGPoint(x: plot.maxX, y: y))
        }
        context.strokePath()
    }

    private func drawYAxisLabels(
        candidates: [(price: Double, y: CGFloat)],
        labelX: CGFloat,
        plot: CGRect
    ) {
        var labels: [(text: String, y: CGFloat, count: Int)] = []
        for candidate in candidates {
            let text = PriceFormatting.string(amount: Decimal(candidate.price), currency: currency)
            if let index = labels.firstIndex(where: { $0.text == text }) {
                let existing = labels[index]
                labels[index] = (
                    text: existing.text,
                    y: (existing.y * CGFloat(existing.count) + candidate.y) / CGFloat(existing.count + 1),
                    count: existing.count + 1)
            } else {
                labels.append((text: text, y: candidate.y, count: 1))
            }
        }

        for label in labels {
            let y = min(
                max(label.y - Self.axisLabelHeight / 2, plot.minY - 1),
                plot.maxY - Self.axisLabelHeight + 1)
            drawAxisLabel(label.text, at: CGPoint(x: labelX, y: y), align: .right)
        }
    }

    private func drawAxisLabel(_ text: String, at origin: CGPoint, align: LabelAlign) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: UIColor.secondaryLabel,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let x = align == .right ? origin.x - size.width : origin.x
        (text as NSString).draw(at: CGPoint(x: x, y: origin.y), withAttributes: attrs)
    }

    public static func axisDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    // MARK: - Scrubbing

    @objc private func scrub(_ gesture: UILongPressGestureRecognizer) {
        guard points.count >= 2 else { return }
        switch gesture.state {
        case .began, .changed:
            let plot = bounds.inset(by: plotInsets)
            let x = min(max(gesture.location(in: self).x, plot.minX), plot.maxX)
            let dates = points.map { $0.date.timeIntervalSinceReferenceDate }
            let minDate = dates.first ?? 0, maxDate = dates.last ?? 1
            let target = minDate + Double((x - plot.minX) / max(plot.width, 1)) * (maxDate - minDate)
            let index = dates.enumerated().min(by: {
                abs($0.element - target) < abs($1.element - target)
            })?.offset ?? 0
            selectedIndex = index
            showCallout(for: index, plot: plot)
            setNeedsDisplay()
        default:
            selectedIndex = nil
            calloutView.isHidden = true
            setNeedsDisplay()
        }
    }

    private func configureCallout() {
        calloutView.backgroundColor = .secondarySystemBackground
        calloutView.layer.cornerRadius = 8
        calloutView.layer.cornerCurve = .continuous
        calloutView.isHidden = true
        calloutView.isUserInteractionEnabled = false
        calloutLabel.numberOfLines = 3
        calloutLabel.font = .systemFont(ofSize: 11, weight: .medium)
        calloutLabel.textColor = .label
        calloutLabel.translatesAutoresizingMaskIntoConstraints = false
        calloutView.addSubview(calloutLabel)
        NSLayoutConstraint.activate([
            calloutLabel.topAnchor.constraint(equalTo: calloutView.topAnchor, constant: 6),
            calloutLabel.bottomAnchor.constraint(equalTo: calloutView.bottomAnchor, constant: -6),
            calloutLabel.leadingAnchor.constraint(equalTo: calloutView.leadingAnchor, constant: 8),
            calloutLabel.trailingAnchor.constraint(equalTo: calloutView.trailingAnchor, constant: -8),
        ])
        addSubview(calloutView)
    }

    private func showCallout(for index: Int, plot: CGRect) {
        let p = points[index]
        let host = URL(string: p.storeURLString)?.host?.replacingOccurrences(of: "www.", with: "")
            ?? p.storeURLString
        calloutLabel.text = "\(PriceFormatting.string(amount: p.price, currency: p.currency))\n"
            + "\(Self.calloutDate(p.date))\n\(host)"
        calloutView.isHidden = false
        calloutView.sizeToFit()
        let size = calloutView.systemLayoutSizeFitting(
            CGSize(width: 180, height: 80),
            withHorizontalFittingPriority: .fittingSizeLevel, verticalFittingPriority: .required)
        let dates = points.map { $0.date.timeIntervalSinceReferenceDate }
        let minDate = dates.first ?? 0, maxDate = dates.last ?? 1
        let x = plot.minX + CGFloat((dates[index] - minDate) / max(maxDate - minDate, 1)) * plot.width
        let originX = min(max(x - size.width / 2, 4), bounds.width - size.width - 4)
        calloutView.frame = CGRect(x: originX, y: 2, width: size.width, height: size.height)
    }

    public static func calloutDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }
}

//
//  PriceGraphView.swift
//  ShareKit
//

import UIKit

/// A compact price-history line chart with a press-and-drag scrubber. Given the
/// aggregated `PriceGraphPoint` series + display currency, it draws the line, y-axis
/// min/max, and x-axis endpoint dates; pressing/dragging highlights the nearest
/// point and shows a callout with its value, date, and store host.
final class PriceGraphView: UIView {

    private var points: [PriceGraphPoint] = []
    private var currency = "USD"
    private var selectedIndex: Int?

    private let calloutView = UIView()
    private let calloutLabel = UILabel()
    private let plotInsets = UIEdgeInsets(top: 16, left: 12, bottom: 22, right: 12)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = false
        configureCallout()
        let press = UILongPressGestureRecognizer(target: self, action: #selector(scrub(_:)))
        press.minimumPressDuration = 0
        addGestureRecognizer(press)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func setData(_ points: [PriceGraphPoint], currency: String) {
        self.points = points
        self.currency = currency
        self.selectedIndex = nil
        calloutView.isHidden = true
        setNeedsDisplay()
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard points.count >= 2, let context = UIGraphicsGetCurrentContext() else { return }
        let plot = rect.inset(by: plotInsets)
        let prices = points.map { ($0.price as NSDecimalNumber).doubleValue }
        let minPrice = prices.min() ?? 0, maxPrice = prices.max() ?? 0
        let priceSpan = max(maxPrice - minPrice, 0.0001)
        let dates = points.map { $0.date.timeIntervalSinceReferenceDate }
        let minDate = dates.first ?? 0, maxDate = dates.last ?? 1
        let dateSpan = max(maxDate - minDate, 1)

        func point(at index: Int) -> CGPoint {
            let x = plot.minX + CGFloat((dates[index] - minDate) / dateSpan) * plot.width
            let y = plot.maxY - CGFloat((prices[index] - minPrice) / priceSpan) * plot.height
            return CGPoint(x: x, y: y)
        }

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

        // y-axis min/max labels.
        drawAxisLabel(PriceFormatting.string(amount: Decimal(maxPrice), currency: currency),
                      at: CGPoint(x: plot.minX, y: rect.minY + 1), align: .left)
        drawAxisLabel(PriceFormatting.string(amount: Decimal(minPrice), currency: currency),
                      at: CGPoint(x: plot.minX, y: plot.maxY + 4), align: .left)
        // x-axis endpoint dates.
        drawAxisLabel(Self.axisDate(points.first!.date),
                      at: CGPoint(x: plot.minX, y: rect.maxY - 14), align: .left)
        drawAxisLabel(Self.axisDate(points.last!.date),
                      at: CGPoint(x: plot.maxX, y: rect.maxY - 14), align: .right)

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

    private enum LabelAlign { case left, right }
    private func drawAxisLabel(_ text: String, at origin: CGPoint, align: LabelAlign) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: UIColor.secondaryLabel,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let x = align == .right ? origin.x - size.width : origin.x
        (text as NSString).draw(at: CGPoint(x: x, y: origin.y), withAttributes: attrs)
    }

    static func axisDate(_ date: Date) -> String {
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

    static func calloutDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }
}

//
//  PriceGraphView.swift
//  LunaPriceUI
//

import LunaDesignSystem
import LunaModels
import UIKit

/// A compact price-history chart. Points can be tapped for detail; alert editing
/// belongs exclusively to `AlertThresholdRow`. When an alert exists the chart
/// mirrors its live slider value as a dashed line with one bell marker.
public final class PriceGraphView: UIView {

    private var points: [PriceGraphPoint] = []
    private var currency = "USD"
    private var baselinePrice: Decimal?
    private var thresholdPrice: Decimal?
    private var selectedIndex: Int?

    private let thresholdColor = LunaSurfacePalette.baseColor(for: .priceTracker)
    private static let topInset: CGFloat = 22
    private static let bottomInset: CGFloat = 24
    private static let rightInset: CGFloat = 8
    private static let minimumPlotWidth: CGFloat = 44
    /// Axis labels, in points. 9 was small enough that the price axis read as
    /// texture at arm's length.
    private static let axisFontSize: CGFloat = 10

    private let thresholdMarker = UIButton(type: .custom)

    private let calloutView = UIView()
    private let calloutLabel = UILabel()

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = false
        configureThresholdControls()
        configureCallout()

        let pointTap = UITapGestureRecognizer(target: self, action: #selector(pointTapped(_:)))
        addGestureRecognizer(pointTap)
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    /// Backwards-compatible graph-only configuration (email snapshots and callers
    /// that do not own an alert threshold).
    public func setData(_ points: [PriceGraphPoint], currency: String) {
        setData(points, currency: currency, thresholdPrice: nil, baselinePrice: nil)
    }

    /// Configures the complete graph. A nil threshold means there is no alert, so
    /// neither a line nor a marker is drawn.
    public func setData(
        _ points: [PriceGraphPoint],
        currency: String,
        thresholdPrice: Decimal?,
        baselinePrice: Decimal?
    ) {
        self.points = points
        self.currency = currency
        self.thresholdPrice = thresholdPrice
        self.baselinePrice = baselinePrice
        selectedIndex = nil
        thresholdMarker.isHidden = thresholdPrice == nil
        calloutView.isHidden = true
        syncThresholdAccessibilityValue()
        setNeedsLayout()
        setNeedsDisplay()
    }

    /// Moves the alert line WITHOUT rebuilding the series.
    ///
    /// The alert row's slider and this line are two views of one number, so each
    /// drives the other while it is being dragged. Going through `setData` would
    /// work and would also drop the tapped-point callout and re-lay everything
    /// out sixty times a second, which is what "the graph flickered while you
    /// moved the slider" was.
    public func setThresholdPrice(_ price: Decimal) {
        thresholdPrice = price
        thresholdMarker.isHidden = false
        syncThresholdAccessibilityValue()
        setNeedsLayout()
        setNeedsDisplay()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        layoutThresholdMarker()
        if let selectedIndex, points.indices.contains(selectedIndex) {
            layoutCallout(for: selectedIndex)
        }
    }

    // MARK: - Drawing

    public override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let plot = plotRect(in: rect)
        drawGrid(in: plot, context: context)
        drawAxes(in: plot, context: context)

        if !points.isEmpty {
            drawSeries(in: plot, context: context)
            drawDateLabels(in: plot)
        } else {
            drawEmptyCaption(in: plot)
        }
        drawThreshold(in: plot, context: context)
    }

    private func drawSeries(in plot: CGRect, context: CGContext) {
        let line = UIBezierPath()
        for index in points.indices {
            let point = plotPoint(at: index, in: plot)
            if index == points.startIndex {
                line.move(to: point)
            } else {
                line.addLine(to: point)
            }
        }
        LunaColors.secondaryText.withAlphaComponent(0.78).setStroke()
        line.lineWidth = 2
        line.lineJoinStyle = .round
        line.lineCapStyle = .round
        line.stroke()

        let selected = selectedIndex
        for index in points.indices {
            let point = plotPoint(at: index, in: plot)
            let belowThreshold = thresholdPrice.map { points[index].price < $0 } ?? false
            let color = belowThreshold ? thresholdColor : LunaColors.secondaryText
            color.setFill()
            let radius: CGFloat = index == selected ? 5 : (belowThreshold ? 4 : 2.5)
            UIBezierPath(
                ovalIn: CGRect(
                    x: point.x - radius, y: point.y - radius,
                    width: radius * 2, height: radius * 2)
            ).fill()
            if index == selected {
                LunaColors.background.setStroke()
                let ring = UIBezierPath(
                    ovalIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
                ring.lineWidth = 1.5
                ring.stroke()
            }
        }

        let prices = points.map { ($0.price as NSDecimalNumber).doubleValue }
        if let minimum = prices.min(), let maximum = prices.max() {
            drawYAxisLabels(
                candidates: [
                    (maximum, yPosition(for: maximum, in: plot)),
                    (minimum, yPosition(for: minimum, in: plot)),
                ],
                labelX: plot.minX - 7,
                plot: plot)
        }
    }

    private func drawThreshold(in plot: CGRect, context: CGContext) {
        guard let thresholdPrice else { return }
        let y = yPosition(for: decimalDouble(thresholdPrice), in: plot)
        context.saveGState()
        context.setStrokeColor(thresholdColor.cgColor)
        context.setLineWidth(2)
        context.setLineDash(phase: 0, lengths: [7, 5])
        context.move(to: CGPoint(x: plot.minX, y: y))
        context.addLine(to: CGPoint(x: plot.maxX, y: y))
        context.strokePath()
        context.restoreGState()
    }

    private func drawGrid(in plot: CGRect, context: CGContext) {
        context.setStrokeColor(LunaColors.quaternaryText.withAlphaComponent(0.34).cgColor)
        context.setLineWidth(1)
        for row in 0...3 {
            let y = plot.minY + plot.height * CGFloat(row) / 3
            context.move(to: CGPoint(x: plot.minX, y: y))
            context.addLine(to: CGPoint(x: plot.maxX, y: y))
        }
        context.strokePath()
    }

    private func drawAxes(in plot: CGRect, context: CGContext) {
        context.setStrokeColor(LunaColors.tertiaryText.withAlphaComponent(0.7).cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: plot.minX, y: plot.minY))
        context.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
        context.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        context.strokePath()
        drawAxisLabel(
            PriceFormatting.axisCurrencySymbol(currency: currency),
            at: CGPoint(x: plot.minX - 7, y: max(bounds.minY, plot.minY - 17)),
            align: .right)
    }

    private func drawDateLabels(in plot: CGRect) {
        guard let first = points.first, let last = points.last else { return }
        drawAxisLabel(
            Self.axisDate(first.date),
            at: CGPoint(x: plot.minX, y: plot.maxY + 8), align: .left)
        if points.count > 1 {
            drawAxisLabel(
                Self.axisDate(last.date),
                at: CGPoint(x: plot.maxX, y: plot.maxY + 8), align: .right)
        }
    }

    private func drawEmptyCaption(in plot: CGRect) {
        let caption = L10n.string("PriceTracker_graph_emptyCaption")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: LunaColors.tertiaryText,
        ]
        let drawRect = CGRect(
            x: plot.minX + 4, y: plot.midY - 10,
            width: max(plot.width - 8, 1), height: 20)
        (caption as NSString).draw(
            in: drawRect, withAttributes: attributes.merging([
                .paragraphStyle: centeredParagraphStyle,
            ]) { _, new in new })
    }

    // MARK: - Alert marker

    private func configureThresholdControls() {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(
            systemName: "bell.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 3, leading: 3, bottom: 3, trailing: 3)
        configuration.baseForegroundColor = thresholdColor
        configuration.background.backgroundColor = LunaColors.background.withAlphaComponent(0.90)
        configuration.background.cornerRadius = 9
        thresholdMarker.configuration = configuration
        thresholdMarker.isUserInteractionEnabled = false
        thresholdMarker.isHidden = true
        thresholdMarker.accessibilityLabel = L10n.string("PriceTracker_alertThreshold_title")
        addSubview(thresholdMarker)
    }

    private func layoutThresholdMarker() {
        guard let thresholdPrice else { return }
        let plot = plotRect(in: bounds)
        let y = yPosition(for: decimalDouble(thresholdPrice), in: plot)
        let markerY = min(max(y - 11, plot.minY - 1), plot.maxY - 21)
        thresholdMarker.frame = CGRect(x: plot.minX + 5, y: markerY, width: 22, height: 22)
        bringSubviewToFront(thresholdMarker)
    }

    private func syncThresholdAccessibilityValue() {
        thresholdMarker.accessibilityValue = thresholdPrice.map {
            PriceFormatting.string(amount: $0, currency: currency)
        }
    }

    // MARK: - Point tooltip

    private func configureCallout() {
        calloutView.backgroundColor = LunaColors.secondaryBackground.withAlphaComponent(0.96)
        calloutView.layer.cornerRadius = 8
        calloutView.layer.cornerCurve = .continuous
        calloutView.layer.borderWidth = 0.5
        calloutView.layer.borderColor = LunaColors.separator.cgColor
        calloutView.isHidden = true
        calloutView.isUserInteractionEnabled = false
        calloutLabel.numberOfLines = 3
        calloutLabel.font = .systemFont(ofSize: 10, weight: .medium)
        calloutLabel.textColor = LunaColors.primaryText
        calloutLabel.translatesAutoresizingMaskIntoConstraints = false
        calloutView.addSubview(calloutLabel)
        NSLayoutConstraint.activate([
            calloutLabel.topAnchor.constraint(equalTo: calloutView.topAnchor, constant: 5),
            calloutLabel.bottomAnchor.constraint(equalTo: calloutView.bottomAnchor, constant: -5),
            calloutLabel.leadingAnchor.constraint(equalTo: calloutView.leadingAnchor, constant: 7),
            calloutLabel.trailingAnchor.constraint(equalTo: calloutView.trailingAnchor, constant: -7),
        ])
        addSubview(calloutView)
    }

    @objc private func pointTapped(_ gesture: UITapGestureRecognizer) {
        guard !points.isEmpty else {
            selectedIndex = nil
            calloutView.isHidden = true
            setNeedsDisplay()
            return
        }
        let location = gesture.location(in: self)
        let plot = plotRect(in: bounds)
        let nearest = points.indices.min {
            distanceSquared(location, plotPoint(at: $0, in: plot))
                < distanceSquared(location, plotPoint(at: $1, in: plot))
        }
        guard let nearest,
              distanceSquared(location, plotPoint(at: nearest, in: plot)) <= 34 * 34
        else {
            selectedIndex = nil
            calloutView.isHidden = true
            setNeedsDisplay()
            return
        }
        selectedIndex = nearest
        updateCalloutText(for: nearest)
        calloutView.isHidden = false
        layoutCallout(for: nearest)
        setNeedsDisplay()
    }

    private func updateCalloutText(for index: Int) {
        let point = points[index]
        let host = URL(string: point.storeURLString)?.host?
            .replacingOccurrences(of: "www.", with: "") ?? point.storeURLString
        calloutLabel.text =
            "\(PriceFormatting.string(amount: point.price, currency: point.currency))\n"
            + "\(Self.calloutDate(point.date))\n\(host)"
    }

    private func layoutCallout(for index: Int) {
        let plot = plotRect(in: bounds)
        let point = plotPoint(at: index, in: plot)
        var size = calloutView.systemLayoutSizeFitting(
            CGSize(width: min(170, max(bounds.width - 6, 1)), height: 70),
            withHorizontalFittingPriority: .fittingSizeLevel,
            verticalFittingPriority: .required)
        size.width = min(size.width, max(bounds.width - 6, 1))
        size.height = min(size.height, max(bounds.height - 2, 1))
        let x = min(max(point.x - size.width / 2, 3), bounds.width - size.width - 3)
        let above = point.y - size.height - 10
        let y = above >= 1 ? above : min(point.y + 10, bounds.height - size.height - 1)
        calloutView.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        bringSubviewToFront(calloutView)
    }

    // MARK: - Geometry and formatting

    private func plotRect(in rect: CGRect) -> CGRect {
        let maximumLeft = max(18, rect.width - Self.rightInset - Self.minimumPlotWidth)
        let desiredLeft = max(axisLabelWidths(in: rect).max() ?? 0, currencyLabelWidth) + 8
        let left = min(max(28, ceil(desiredLeft)), maximumLeft)
        let width = max(rect.width - left - Self.rightInset, 1)
        let height = max(rect.height - Self.topInset - Self.bottomInset, 1)
        return CGRect(x: rect.minX + left, y: rect.minY + Self.topInset, width: width, height: height)
    }

    private var priceDomain: (min: Double, max: Double) {
        var values = points.map { decimalDouble($0.price) }
        if let baselinePrice { values.append(decimalDouble(baselinePrice)) }
        if let thresholdPrice { values.append(decimalDouble(thresholdPrice)) }
        let rawMaximum = max(values.max() ?? 1, 0.01)
        let rawMinimum = max(values.min() ?? 0, 0)
        if points.isEmpty {
            return (0, max(rawMaximum * 1.12, 1))
        }
        let span = max(rawMaximum - rawMinimum, rawMaximum * 0.12, 1)
        return (max(0, rawMinimum - span * 0.18), rawMaximum + span * 0.18)
    }

    private func yPosition(for price: Double, in plot: CGRect) -> CGFloat {
        let domain = priceDomain
        let fraction = (price - domain.min) / max(domain.max - domain.min, 0.0001)
        return plot.maxY - CGFloat(min(max(fraction, 0), 1)) * plot.height
    }

    private func plotPoint(at index: Int, in plot: CGRect) -> CGPoint {
        let dates = points.map { $0.date.timeIntervalSinceReferenceDate }
        let minimumDate = dates.min() ?? 0
        let maximumDate = dates.max() ?? minimumDate
        let x: CGFloat
        if maximumDate - minimumDate < 1 {
            x = plot.midX
        } else {
            x = plot.minX
                + CGFloat((dates[index] - minimumDate) / (maximumDate - minimumDate)) * plot.width
        }
        return CGPoint(
            x: x,
            y: yPosition(for: decimalDouble(points[index].price), in: plot))
    }

    private enum LabelAlign { case left, right }

    private func drawYAxisLabels(
        candidates: [(price: Double, y: CGFloat)],
        labelX: CGFloat,
        plot: CGRect
    ) {
        var used = Set<String>()
        for candidate in candidates {
            let text = axisLabel(for: candidate.price, in: bounds)
            guard used.insert(text).inserted else { continue }
            let y = min(max(candidate.y - 6, plot.minY - 1), plot.maxY - 12)
            drawAxisLabel(text, at: CGPoint(x: labelX, y: y), align: .right)
        }
    }

    private var axisLabelAttributes: [NSAttributedString.Key: Any] {
        [
            .font: UIFont.systemFont(ofSize: Self.axisFontSize, weight: .medium),
            .foregroundColor: LunaColors.secondaryText,
        ]
    }

    private var currencyLabelWidth: CGFloat {
        (PriceFormatting.axisCurrencySymbol(currency: currency) as NSString)
            .size(withAttributes: axisLabelAttributes).width
    }

    private func axisLabelWidths(in rect: CGRect) -> [CGFloat] {
        let prices = points.map { decimalDouble($0.price) }
        guard let minimum = prices.min(), let maximum = prices.max() else { return [] }
        return [minimum, maximum].map {
            (axisLabel(for: $0, in: rect) as NSString)
                .size(withAttributes: axisLabelAttributes).width
        }
    }

    /// Uses the precise label while it fits the share of the graph that an axis
    /// can reasonably claim. If a multi-digit value exhausts that share, cents
    /// are the first detail to go; five-digit values have already compacted.
    private func axisLabel(for price: Double, in rect: CGRect) -> String {
        let amount = Decimal(price)
        let precise = PriceFormatting.axisString(amount: amount, currency: currency)
        let budget = max(24, min(64, rect.width * 0.20))
        let preciseWidth = (precise as NSString).size(withAttributes: axisLabelAttributes).width
        guard abs(price) >= 10, preciseWidth > budget else { return precise }
        return PriceFormatting.axisString(
            amount: amount, currency: currency, showsFractionalDigits: false)
    }

    private func drawAxisLabel(_ text: String, at origin: CGPoint, align: LabelAlign) {
        let attributes = axisLabelAttributes
        let size = (text as NSString).size(withAttributes: attributes)
        let x = align == .right ? origin.x - size.width : origin.x
        (text as NSString).draw(
            at: CGPoint(x: x, y: origin.y), withAttributes: attributes)
    }

    private func decimalDouble(_ value: Decimal) -> Double {
        (value as NSDecimalNumber).doubleValue
    }

    private func distanceSquared(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private var centeredParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        return style
    }

    private static let axisFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    private static let calloutFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
        return formatter
    }()

    private static func axisDate(_ date: Date) -> String {
        axisFormatter.string(from: date)
    }

    private static func calloutDate(_ date: Date) -> String {
        calloutFormatter.string(from: date)
    }
}

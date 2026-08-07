//
//  PriceGraphView.swift
//  LunaPriceUI
//

import LunaDesignSystem
import LunaModels
import UIKit

/// A compact price-history chart with an optional threshold editor.
///
/// The price series is deliberately non-interactive except for taps on a point.
/// Threshold editing belongs to the green line's leading handle: dragging it moves
/// the line, while tapping its price label opens a number-pad field. A pending edit
/// is explicit — checkmark commits, xmark restores the value that began the edit.
///
/// With `allowsThresholdEditing` and NO threshold (`thresholdPrice: nil` — a product
/// tracked before the user was ever asked about notifications) there is no line to
/// drag, so the graph shows a **"Set price alert"** pill instead and reports the tap
/// through `onThresholdRequested`. The host seeds the default threshold there, which
/// is also where the notification-permission prompt is raised; the line, handle and
/// label then arrive with the next `setData`.
public final class PriceGraphView: UIView, UITextFieldDelegate {

    public var onThresholdChanged: ((Decimal) -> Void)?
    public var onThresholdCommitted: ((Decimal) -> Void)?
    /// Fired when the user asks for an alert on a tracker that has none. The host
    /// decides the starting threshold (and asks for notification permission).
    public var onThresholdRequested: (() -> Void)?

    private var points: [PriceGraphPoint] = []
    private var currency = "USD"
    private var baselinePrice: Decimal?
    private var thresholdPrice: Decimal?
    private var allowsThresholdEditing = false
    private var selectedIndex: Int?
    private var editingOriginalThreshold: Decimal?

    private let thresholdColor = LunaSurfacePalette.baseColor(for: .priceTracker)
    private let plotInsets = UIEdgeInsets(top: 34, left: 58, bottom: 32, right: 14)

    private let thresholdHandle = UIButton(type: .custom)
    /// Shown in place of the line's controls while the tracker has no threshold.
    private let setThresholdButton = UIButton(type: .system)
    private let thresholdPan = UIPanGestureRecognizer()
    private let thresholdLabel = UIButton(type: .system)
    private let thresholdEditor = UIVisualEffectView(effect: GlassStyle.barEffect())
    private let thresholdField = UITextField()
    private let commitButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)

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

    /// Lets an enclosing vertical scroll view defer to the handle's drag. The
    /// recognizer is attached only to the small handle, so requiring it to fail
    /// does not delay ordinary scrolling elsewhere on the card.
    public var thresholdDragGestureRecognizer: UIPanGestureRecognizer { thresholdPan }

    /// Backwards-compatible graph-only configuration (email snapshots and callers
    /// that do not own an alert threshold).
    public func setData(_ points: [PriceGraphPoint], currency: String) {
        setData(
            points, currency: currency, thresholdPrice: nil,
            baselinePrice: nil, allowsThresholdEditing: false)
    }

    /// Configures the complete graph. An empty `points` array still draws axes and
    /// the threshold line, making a new tracker immediately editable.
    public func setData(
        _ points: [PriceGraphPoint],
        currency: String,
        thresholdPrice: Decimal?,
        baselinePrice: Decimal?,
        allowsThresholdEditing: Bool
    ) {
        self.points = points
        self.currency = currency
        self.thresholdPrice = thresholdPrice
        self.baselinePrice = baselinePrice
        self.allowsThresholdEditing = allowsThresholdEditing
        selectedIndex = nil
        editingOriginalThreshold = nil
        thresholdEditor.isHidden = true
        thresholdLabel.isHidden = thresholdPrice == nil
        thresholdHandle.isHidden = thresholdPrice == nil
        // No threshold + editable = the tracker has no alert yet, and the graph is
        // the only place to make one on the card. Read-only graphs (the email
        // snapshot, the legacy editor's line) stay untouched.
        setThresholdButton.isHidden = !(thresholdPrice == nil && allowsThresholdEditing)
        calloutView.isHidden = true
        syncThresholdText()
        setNeedsLayout()
        setNeedsDisplay()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        layoutThresholdControls()
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
        let size = (caption as NSString).size(withAttributes: attributes)
        (caption as NSString).draw(
            at: CGPoint(x: plot.midX - size.width / 2, y: plot.midY - size.height / 2),
            withAttributes: attributes)
    }

    // MARK: - Threshold controls

    private func configureThresholdControls() {
        thresholdHandle.backgroundColor = thresholdColor
        thresholdHandle.layer.cornerRadius = 9
        thresholdHandle.layer.cornerCurve = .continuous
        thresholdHandle.layer.borderWidth = 2
        thresholdHandle.layer.borderColor = LunaColors.background.cgColor
        thresholdHandle.accessibilityLabel = L10n.string("PriceTracker_alertThreshold_title")
        thresholdHandle.accessibilityHint = L10n.string("PriceTracker_graph_thresholdHandleHint")
        addSubview(thresholdHandle)

        thresholdPan.addTarget(self, action: #selector(thresholdDragged(_:)))
        thresholdHandle.addGestureRecognizer(thresholdPan)

        var labelConfiguration = UIButton.Configuration.plain()
        labelConfiguration.contentInsets = NSDirectionalEdgeInsets(
            top: 3, leading: 7, bottom: 3, trailing: 7)
        labelConfiguration.baseForegroundColor = thresholdColor
        labelConfiguration.background.backgroundColor = LunaColors.background.withAlphaComponent(0.86)
        labelConfiguration.background.cornerRadius = 7
        thresholdLabel.configuration = labelConfiguration
        thresholdLabel.titleLabel?.font = .systemFont(ofSize: 11, weight: .bold)
        thresholdLabel.addTarget(self, action: #selector(thresholdLabelTapped), for: .touchUpInside)
        addSubview(thresholdLabel)

        var setConfiguration = UIButton.Configuration.plain()
        setConfiguration.title = L10n.string("PriceTracker_alertThreshold_setButtonTitle")
        setConfiguration.image = UIImage(
            systemName: "bell.badge",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        setConfiguration.imagePadding = 5
        setConfiguration.contentInsets = NSDirectionalEdgeInsets(
            top: 5, leading: 9, bottom: 5, trailing: 10)
        setConfiguration.baseForegroundColor = thresholdColor
        setConfiguration.background.backgroundColor = LunaColors.background.withAlphaComponent(0.86)
        setConfiguration.background.strokeColor = thresholdColor.withAlphaComponent(0.55)
        setConfiguration.background.strokeWidth = 1
        setConfiguration.background.cornerRadius = 9
        setThresholdButton.configuration = setConfiguration
        setThresholdButton.titleLabel?.font = .systemFont(ofSize: 11, weight: .bold)
        setThresholdButton.isHidden = true
        setThresholdButton.accessibilityHint = L10n.string("PriceTracker_graph_setButtonHint")
        setThresholdButton.addTarget(
            self, action: #selector(setThresholdTapped), for: .touchUpInside)
        addSubview(setThresholdButton)

        thresholdEditor.layer.cornerRadius = 9
        thresholdEditor.layer.cornerCurve = .continuous
        thresholdEditor.clipsToBounds = true
        thresholdEditor.isHidden = true
        addSubview(thresholdEditor)

        thresholdField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        thresholdField.textColor = thresholdColor
        thresholdField.textAlignment = .right
        thresholdField.keyboardType = .decimalPad
        thresholdField.returnKeyType = .done
        thresholdField.delegate = self
        thresholdField.accessibilityLabel = L10n.string("PriceTracker_graph_thresholdFieldLabel")
        thresholdField.addTarget(self, action: #selector(thresholdFieldChanged), for: .editingChanged)

        configureEditorButton(commitButton, symbol: "checkmark", action: #selector(commitThreshold))
        configureEditorButton(cancelButton, symbol: "xmark", action: #selector(cancelThreshold))
        thresholdEditor.contentView.addSubview(thresholdField)
        thresholdEditor.contentView.addSubview(commitButton)
        thresholdEditor.contentView.addSubview(cancelButton)
    }

    private func configureEditorButton(_ button: UIButton, symbol: String, action: Selector) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))
        configuration.contentInsets = .zero
        configuration.baseForegroundColor = thresholdColor
        button.configuration = configuration
        button.addTarget(self, action: action, for: .touchUpInside)
        button.accessibilityLabel = symbol == "checkmark"
            ? L10n.string("PriceTracker_graph_saveThresholdLabel")
            : L10n.string("PriceTracker_graph_cancelThresholdLabel")
    }

    private func layoutThresholdControls() {
        guard let thresholdPrice else {
            layoutSetThresholdButton()
            return
        }
        let plot = plotRect(in: bounds)
        let y = yPosition(for: decimalDouble(thresholdPrice), in: plot)
        thresholdHandle.frame = CGRect(x: plot.minX - 9, y: y - 9, width: 18, height: 18)

        if thresholdEditor.isHidden {
            thresholdLabel.sizeToFit()
            let size = thresholdLabel.systemLayoutSizeFitting(
                CGSize(width: 150, height: 28),
                withHorizontalFittingPriority: .fittingSizeLevel,
                verticalFittingPriority: .required)
            thresholdLabel.frame = CGRect(
                x: plot.minX + 8,
                y: max(bounds.minY + 2, y - size.height - 5),
                width: size.width,
                height: size.height)
        } else {
            let width = min(max(bounds.width * 0.56, 172), 226)
            let editorY = max(bounds.minY + 2, y - 34)
            thresholdEditor.frame = CGRect(
                x: plot.minX + 8, y: editorY, width: width, height: 32)
            cancelButton.frame = CGRect(x: width - 30, y: 1, width: 28, height: 30)
            commitButton.frame = CGRect(x: width - 60, y: 1, width: 28, height: 30)
            thresholdField.frame = CGRect(x: 8, y: 2, width: width - 70, height: 28)
        }
    }

    /// The no-alert pill sits at the top-left of the plot — where the line's own
    /// price label would be, so setting an alert leaves the eye where it already is.
    private func layoutSetThresholdButton() {
        guard !setThresholdButton.isHidden else { return }
        let plot = plotRect(in: bounds)
        let size = setThresholdButton.systemLayoutSizeFitting(
            CGSize(width: max(plot.width, 1), height: 30),
            withHorizontalFittingPriority: .fittingSizeLevel,
            verticalFittingPriority: .required)
        setThresholdButton.frame = CGRect(
            x: plot.minX + 8, y: max(bounds.minY + 2, plot.minY - size.height - 4),
            width: min(size.width, max(plot.width - 8, 1)), height: size.height)
    }

    @objc private func setThresholdTapped() {
        guard allowsThresholdEditing, thresholdPrice == nil else { return }
        onThresholdRequested?()
    }

    private func syncThresholdText() {
        guard let thresholdPrice else { return }
        let formatted = PriceFormatting.string(amount: thresholdPrice, currency: currency)
        thresholdLabel.setTitle(formatted, for: .normal)
        thresholdLabel.accessibilityValue = formatted
        thresholdHandle.accessibilityValue = formatted
        thresholdField.text = decimalEditingString(thresholdPrice)
    }

    @objc private func thresholdLabelTapped() {
        guard allowsThresholdEditing else { return }
        beginThresholdEditing(focusField: true)
    }

    @objc private func thresholdDragged(_ gesture: UIPanGestureRecognizer) {
        guard allowsThresholdEditing, thresholdPrice != nil else { return }
        let plot = plotRect(in: bounds)
        switch gesture.state {
        case .began:
            beginThresholdEditing(focusField: false)
            updateThreshold(fromY: gesture.location(in: self).y, plot: plot)
        case .changed:
            updateThreshold(fromY: gesture.location(in: self).y, plot: plot)
        default:
            break
        }
    }

    private func beginThresholdEditing(focusField: Bool) {
        guard let thresholdPrice else { return }
        if editingOriginalThreshold == nil {
            editingOriginalThreshold = thresholdPrice
        }
        thresholdLabel.isHidden = true
        thresholdEditor.isHidden = false
        syncThresholdText()
        setNeedsLayout()
        layoutIfNeeded()
        if focusField { thresholdField.becomeFirstResponder() }
    }

    private func updateThreshold(fromY y: CGFloat, plot: CGRect) {
        let clampedY = min(max(y, plot.minY), plot.maxY)
        let domain = priceDomain
        let fraction = Double((plot.maxY - clampedY) / max(plot.height, 1))
        let value = domain.min + fraction * (domain.max - domain.min)
        let edited = clampedThreshold(Decimal(value))
        thresholdPrice = edited
        syncThresholdText()
        setNeedsLayout()
        setNeedsDisplay()
        onThresholdChanged?(edited)
    }

    @objc private func thresholdFieldChanged() {
        guard let value = parsedThresholdFieldValue() else { return }
        thresholdPrice = clampedThreshold(value)
        let formatted = PriceFormatting.string(amount: thresholdPrice!, currency: currency)
        thresholdLabel.setTitle(formatted, for: .normal)
        thresholdLabel.accessibilityValue = formatted
        thresholdHandle.accessibilityValue = formatted
        setNeedsLayout()
        setNeedsDisplay()
        onThresholdChanged?(thresholdPrice!)
    }

    @objc private func commitThreshold() {
        guard let parsed = parsedThresholdFieldValue() ?? thresholdPrice else { return }
        let committed = clampedThreshold(parsed)
        thresholdPrice = committed
        editingOriginalThreshold = nil
        thresholdField.resignFirstResponder()
        thresholdEditor.isHidden = true
        thresholdLabel.isHidden = false
        syncThresholdText()
        setNeedsLayout()
        setNeedsDisplay()
        onThresholdCommitted?(committed)
    }

    @objc private func cancelThreshold() {
        guard let original = editingOriginalThreshold else { return }
        thresholdPrice = original
        editingOriginalThreshold = nil
        thresholdField.resignFirstResponder()
        thresholdEditor.isHidden = true
        thresholdLabel.isHidden = false
        syncThresholdText()
        setNeedsLayout()
        setNeedsDisplay()
        onThresholdChanged?(original)
    }

    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        commitThreshold()
        return true
    }

    private func parsedThresholdFieldValue() -> Decimal? {
        guard var text = thresholdField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        let separator = Locale.current.decimalSeparator ?? "."
        if separator != "." { text = text.replacingOccurrences(of: separator, with: ".") }
        text = text.filter { $0.isNumber || $0 == "." || $0 == "-" }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }

    private func clampedThreshold(_ value: Decimal) -> Decimal {
        let number = decimalDouble(value)
        if let baselinePrice {
            let baseline = decimalDouble(baselinePrice)
            return Decimal(min(max(number, baseline * 0.05), baseline * 0.99))
        }
        return Decimal(min(max(number, priceDomain.min), priceDomain.max))
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
        let size = calloutView.systemLayoutSizeFitting(
            CGSize(width: 170, height: 70),
            withHorizontalFittingPriority: .fittingSizeLevel,
            verticalFittingPriority: .required)
        let x = min(max(point.x - size.width / 2, 3), bounds.width - size.width - 3)
        let above = point.y - size.height - 10
        let y = above >= 1 ? above : min(point.y + 10, bounds.height - size.height - 1)
        calloutView.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        bringSubviewToFront(calloutView)
    }

    // MARK: - Geometry and formatting

    private func plotRect(in rect: CGRect) -> CGRect {
        rect.inset(by: plotInsets)
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
            let text = PriceFormatting.string(amount: Decimal(candidate.price), currency: currency)
            guard used.insert(text).inserted else { continue }
            let y = min(max(candidate.y - 6, plot.minY - 1), plot.maxY - 12)
            drawAxisLabel(text, at: CGPoint(x: labelX, y: y), align: .right)
        }
    }

    private func drawAxisLabel(_ text: String, at origin: CGPoint, align: LabelAlign) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: LunaColors.secondaryText,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let x = align == .right ? origin.x - size.width : origin.x
        (text as NSString).draw(
            at: CGPoint(x: x, y: origin.y), withAttributes: attributes)
    }

    private func decimalEditingString(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        formatter.usesGroupingSeparator = false
        return formatter.string(from: value as NSDecimalNumber)
            ?? NSDecimalNumber(decimal: value).stringValue
    }

    private func decimalDouble(_ value: Decimal) -> Double {
        (value as NSDecimalNumber).doubleValue
    }

    private func distanceSquared(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
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

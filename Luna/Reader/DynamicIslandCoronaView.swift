//
//  DynamicIslandCoronaView.swift
//  Luna
//
//  A quiet, procedural lunar-eclipse corona around the physical Dynamic Island.
//  It draws only light outside the system-owned black capsule and never handles input.
//

import UIKit

final class DynamicIslandCoronaView: UIView {

    private static let tagValue = 0xEC11_5E

    static func installIfSupported(in window: UIWindow) {
        guard AppSurfaceConfig.current == .reader,
              window.viewWithTag(tagValue) == nil else { return }
        window.layoutIfNeeded()
        // Dynamic-Island iPhones expose a taller portrait safe area than notch
        // devices. UIKit intentionally offers no hardware-cutout API, so geometry
        // is the least invasive public signal; hide again whenever it changes.
        guard window.safeAreaInsets.top >= 51 else { return }

        let corona = DynamicIslandCoronaView(frame: CGRect(
            x: 0, y: 0, width: window.bounds.width,
            height: min(window.safeAreaInsets.top + 24, 92)))
        corona.tag = tagValue
        corona.autoresizingMask = [.flexibleWidth]
        window.addSubview(corona)
        corona.startAnimating()
    }

    static func setActive(_ active: Bool, in window: UIWindow?) {
        guard let corona = window?.viewWithTag(tagValue) as? DynamicIslandCoronaView else { return }
        active ? corona.startAnimating() : corona.stopAnimating()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let windowBounds = window?.bounds ?? .zero
        isHidden = windowBounds.width > windowBounds.height || (window?.safeAreaInsets.top ?? 0) < 51
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard !isHidden, let context = UIGraphicsGetCurrentContext() else { return }
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let island = CGRect(x: bounds.midX - 63, y: 11, width: 126, height: 37)
        let center = CGPoint(x: island.midX, y: island.midY)

        context.saveGState()
        context.setBlendMode(.plusLighter)

        // Fine polar streamers: deterministic irregular lengths keep the edge
        // astronomical instead of reading as a uniform drop shadow.
        context.setLineCap(.round)
        for index in 0..<112 {
            let angle = CGFloat(index) / 112 * .pi * 2
            let direction = CGPoint(x: cos(angle), y: sin(angle))
            let boundaryRadius = 1 / sqrt(
                pow(direction.x / (island.width * 0.5), 2) +
                pow(direction.y / (island.height * 0.5), 2))
            let texture = sin(CGFloat(index) * 2.399) * 0.5 + 0.5
            let longStreamer = index % 17 == 0 || index % 29 == 0
            let length: CGFloat = (longStreamer ? 21 : 7) + texture * (longStreamer ? 16 : 10)
            let start = boundaryRadius + 1.5
            let end = start + length
            context.move(to: CGPoint(
                x: center.x + direction.x * start,
                y: center.y + direction.y * start))
            context.addLine(to: CGPoint(
                x: center.x + direction.x * end,
                y: center.y + direction.y * end))
            let alpha: CGFloat = (longStreamer ? 0.17 : 0.07) * (0.65 + texture * 0.35)
            context.setStrokeColor(UIColor(
                red: 0.82 + texture * 0.12, green: 0.88 + texture * 0.09,
                blue: 1, alpha: alpha).cgColor)
            context.setLineWidth(longStreamer ? 0.75 : 0.45)
            context.strokePath()
        }

        // Layered rim glows. Their source strokes sit beneath the system-owned
        // island; only the soft exterior survives visually on a real device.
        let capsule = UIBezierPath(roundedRect: island, cornerRadius: island.height / 2).cgPath
        for (blur, width, color) in [
            (18.0, 1.0, UIColor(red: 0.46, green: 0.65, blue: 1, alpha: 0.18)),
            (8.0, 0.8, UIColor(red: 0.88, green: 0.93, blue: 1, alpha: 0.42)),
            (3.0, 0.55, UIColor(red: 1, green: 0.79, blue: 0.49, alpha: 0.34)),
        ] {
            context.saveGState()
            context.addPath(capsule)
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(width * scale / max(scale, 1))
            context.setShadow(offset: .zero, blur: blur, color: color.cgColor)
            context.strokePath()
            context.restoreGState()
        }
        context.restoreGState()
    }

    func startAnimating() {
        guard !UIAccessibility.isReduceMotionEnabled else {
            layer.removeAnimation(forKey: "coronaBreathing")
            layer.opacity = 1
            return
        }
        guard layer.animation(forKey: "coronaBreathing") == nil else { return }
        let breathing = CAKeyframeAnimation(keyPath: "opacity")
        breathing.values = [0.82, 1.0, 0.88, 0.96, 0.82]
        breathing.keyTimes = [0, 0.24, 0.51, 0.76, 1]
        breathing.duration = 5.8
        breathing.repeatCount = .infinity
        breathing.isRemovedOnCompletion = false
        layer.add(breathing, forKey: "coronaBreathing")
    }

    func stopAnimating() {
        layer.removeAnimation(forKey: "coronaBreathing")
        layer.opacity = 0.82
    }
}

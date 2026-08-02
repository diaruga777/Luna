//
//  RSVPGazeDebugOverlay.swift
//  LunaReaderUI
//

import LunaDesignSystem
import UIKit

/// Diagnostics-only overlay drawn across the RSVP reader while the hidden
/// "Gaze Debug Overlay" switch (Settings → 5-tap Diagnostics) is on. Shows the
/// raw gaze estimate, the calibrated estimate, the focus radius around the
/// focal word, and a numeric readout — enough to tell a systematic projection
/// bias from noise on a real device, which is the one thing the simulator
/// test suite can never see. Touch-transparent; never shipped active.
public final class RSVPGazeDebugOverlay: UIView {

    private let focusCircle = CAShapeLayer()
    private let rawDot = UIView()
    private let calibratedDot = UIView()
    private let readout = UILabel()

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false

        focusCircle.fillColor = nil
        focusCircle.strokeColor = LunaColors.secondaryText.withAlphaComponent(0.6).cgColor
        focusCircle.lineWidth = 1
        focusCircle.lineDashPattern = [4, 4]
        layer.addSublayer(focusCircle)

        rawDot.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        rawDot.layer.cornerRadius = 4
        rawDot.backgroundColor = LunaColors.secondaryText
        rawDot.isHidden = true
        addSubview(rawDot)

        calibratedDot.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
        calibratedDot.layer.cornerRadius = 6
        calibratedDot.backgroundColor = GlassStyle.readingAccent
        calibratedDot.layer.borderWidth = 1.5
        calibratedDot.layer.borderColor = UIColor.black.cgColor
        calibratedDot.isHidden = true
        addSubview(calibratedDot)

        readout.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        readout.textColor = LunaColors.primaryText
        readout.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        readout.numberOfLines = 0
        readout.text = "gaze overlay: waiting for samples"
        addSubview(readout)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public override func layoutSubviews() {
        super.layoutSubviews()
        readout.frame = CGRect(
            x: 8, y: bounds.maxY - safeAreaInsets.bottom - 64,
            width: bounds.width - 16, height: 56)
    }

    func render(_ frame: GazeDebugFrame) {
        focusCircle.path = UIBezierPath(
            arcCenter: frame.focus, radius: frame.focusRadius,
            startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath

        rawDot.isHidden = frame.raw == nil
        if let raw = frame.raw { rawDot.center = raw }
        calibratedDot.isHidden = frame.calibrated == nil
        if let calibrated = frame.calibrated { calibratedDot.center = calibrated }

        readout.text = Self.readoutText(for: frame)
    }

    private static func readoutText(for frame: GazeDebugFrame) -> String {
        var lines: [String] = []
        switch frame.signal {
        case .faceLost:
            lines.append("face lost — not judging")
        case .offScreen:
            lines.append("off screen (no plane intersection)")
        case .point:
            if let raw = frame.raw {
                lines.append("raw Δ" + delta(raw, from: frame.focus))
            }
            if let calibrated = frame.calibrated {
                let distance = hypot(
                    calibrated.x - frame.focus.x, calibrated.y - frame.focus.y)
                lines.append(
                    "cal Δ" + delta(calibrated, from: frame.focus)
                        + String(format: "  d=%.0fpt", distance)
                        + (distance <= frame.focusRadius ? " (reading)" : " (away)"))
            }
        }
        if let offset = frame.offset {
            lines.append(String(format: "offset (%+.0f, %+.0f)", offset.dx, offset.dy)
                + (frame.isWarmingUp ? "  re-anchoring…" : ""))
        } else {
            lines.append(frame.isWarmingUp
                ? "calibrating — keep reading…" : "uncalibrated (press play)")
        }
        lines.append(String(
            format: "away %3.0f%%%@", frame.awayProgress * 100, frame.isAway ? " ←" : ""))
        return lines.joined(separator: "\n")
    }

    private static func delta(_ point: CGPoint, from focus: CGPoint) -> String {
        String(format: "(%+.0f, %+.0f)", point.x - focus.x, point.y - focus.y)
    }
}

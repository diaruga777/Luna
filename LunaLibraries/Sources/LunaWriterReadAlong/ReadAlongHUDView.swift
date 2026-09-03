//
//  ReadAlongHUDView.swift
//  LunaWriterReadAlong
//

import Foundation
import LunaDesignSystem
import LunaModels
import UIKit

/// The reader of the HUD chip's menu.
public protocol ReadAlongHUDViewDelegate: AnyObject {
    func readAlongHUD(_ hud: ReadAlongHUDView, didRequestCalibration style: GazeCalibrationStyle)
    /// Pause or resume tracking, keeping the user's gaze setting.
    func readAlongHUDDidTogglePause(_ hud: ReadAlongHUDView)
    func readAlongHUDDidToggleGaze(_ hud: ReadAlongHUDView)
    func readAlongHUDDidToggleVoice(_ hud: ReadAlongHUDView)
    func readAlongHUDDidToggleDiagnostics(_ hud: ReadAlongHUDView)
    func readAlongHUDDidRequestClearAnnotations(_ hud: ReadAlongHUDView)
}

/// The read-along chip: a glass pill carrying a tracking dot and a mic dot,
/// with the whole session's menu behind it.
///
/// It states two things and offers six. Anything more belongs in Settings —
/// the chip sits over the writer's own text and must not grow into a toolbar.
public final class ReadAlongHUDView: UIView {

    public weak var delegate: ReadAlongHUDViewDelegate?
    public private(set) var state = ReadAlongState()
    /// Whether the diagnostics overlay is showing, for the menu's tick.
    public var diagnosticsVisible = false

    private let background = UIVisualEffectView(effect: GlassStyle.barEffect())
    private let button = UIButton(type: .system)
    private let trackingDot = CAShapeLayer()
    private let micDot = CAShapeLayer()
    private let stack = UIStackView()

    private static let dotSize: CGFloat = 9
    private static let height: CGFloat = 34

    public override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func build() {
        background.translatesAutoresizingMaskIntoConstraints = false
        background.layer.cornerRadius = Self.height / 2
        background.layer.cornerCurve = .continuous
        background.clipsToBounds = true
        background.isUserInteractionEnabled = false
        addSubview(background)

        for dot in [trackingDot, micDot] {
            dot.actions = ["fillColor": NSNull(), "path": NSNull()]
            dot.path = UIBezierPath(
                ovalIn: CGRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize)).cgPath
            layer.addSublayer(dot)
        }

        button.translatesAutoresizingMaskIntoConstraints = false
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = L10n.string("WriterReadAlong_hudAccessibilityLabel")
        addSubview(button)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isUserInteractionEnabled = false

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
            widthAnchor.constraint(equalToConstant: 66),
        ])

        registerForTraitChanges([LunaSkyTrait.self]) {
            (self: ReadAlongHUDView, _: UITraitCollection) in
            self.refreshDots()
        }
        refreshDots()
        rebuildMenu()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let y = (bounds.height - Self.dotSize) / 2
        trackingDot.frame = CGRect(
            x: 18, y: y, width: Self.dotSize, height: Self.dotSize)
        micDot.frame = CGRect(
            x: bounds.width - 18 - Self.dotSize, y: y,
            width: Self.dotSize, height: Self.dotSize)
    }

    // MARK: - State

    public func apply(_ state: ReadAlongState) {
        self.state = state
        refreshDots()
        rebuildMenu()
    }

    private func refreshDots() {
        trackingDot.fillColor = Self.colour(
            for: state.trackingIndicator, traits: traitCollection).cgColor
        micDot.fillColor = Self.colour(
            for: state.micIndicator, traits: traitCollection).cgColor
    }

    private static func colour(
        for indicator: ReadAlongIndicator, traits: UITraitCollection
    ) -> UIColor {
        let colour: UIColor
        switch indicator {
        case .off: colour = LunaColors.quaternaryText
        case .ok: colour = ReadAlongTheme.keep
        case .warn: colour = ReadAlongTheme.comment
        case .busy: colour = LunaColors.tertiaryText
        }
        return colour.resolvedColor(with: traits)
    }

    // MARK: - Menu

    private func rebuildMenu() {
        var items: [UIMenuElement] = []
        if state.gazeAvailable {
            items.append(
                action(L10n.string("WriterReadAlong_menuCalibrate"), "scope") { [weak self] in
                    guard let self else { return }
                    self.delegate?.readAlongHUD(self, didRequestCalibration: .full)
                })
            items.append(
                action(
                    L10n.string("WriterReadAlong_menuQuickTouchUp"), "wand.and.sparkles"
                ) { [weak self] in
                    guard let self else { return }
                    self.delegate?.readAlongHUD(self, didRequestCalibration: .quick)
                })
            items.append(
                toggle(
                    L10n.string("WriterReadAlong_menuGaze"), "eye", on: state.gazeEnabled
                ) { [weak self] in
                    guard let self else { return }
                    self.delegate?.readAlongHUDDidToggleGaze(self)
                })
            if state.gazeEnabled {
                let title = state.isPaused
                    ? L10n.string("WriterReadAlong_menuResumeTracking")
                    : L10n.string("WriterReadAlong_menuPauseTracking")
                items.append(
                    action(title, state.isPaused ? "play" : "pause") { [weak self] in
                        guard let self else { return }
                        self.delegate?.readAlongHUDDidTogglePause(self)
                    })
            }
        }
        if state.voiceAvailable {
            items.append(
                toggle(
                    L10n.string("WriterReadAlong_menuVoice"), "mic", on: state.voiceEnabled
                ) { [weak self] in
                    guard let self else { return }
                    self.delegate?.readAlongHUDDidToggleVoice(self)
                })
        }
        items.append(
            toggle(
                L10n.string("WriterReadAlong_menuDiagnostics"), "waveform.path.ecg",
                on: diagnosticsVisible
            ) { [weak self] in
                guard let self else { return }
                self.delegate?.readAlongHUDDidToggleDiagnostics(self)
            })
        var clear = action(
            L10n.string("WriterReadAlong_menuClearAnnotations"), "trash"
        ) { [weak self] in
            guard let self else { return }
            self.delegate?.readAlongHUDDidRequestClearAnnotations(self)
        }
        clear.attributes = .destructive
        items.append(clear)
        button.menu = UIMenu(children: items)
    }

    private func action(
        _ title: String, _ symbol: String, handler: @escaping () -> Void
    ) -> UIAction {
        UIAction(title: title, image: UIImage(systemName: symbol)) { _ in handler() }
    }

    private func toggle(
        _ title: String, _ symbol: String, on: Bool, handler: @escaping () -> Void
    ) -> UIAction {
        let item = action(title, symbol, handler: handler)
        item.state = on ? .on : .off
        return item
    }
}

//
//  GazeCalibrationViewController.swift
//  LunaWriterReadAlong
//

import CoreGraphics
import Foundation
import LunaDesignSystem
import LunaGaze
import LunaModels
import UIKit

/// The reader of a calibration run's outcome.
public protocol GazeCalibrationViewControllerDelegate: AnyObject {
    func gazeCalibration(
        _ controller: GazeCalibrationViewController,
        didFinishWith calibration: GazeAffineCalibration,
        verdict: CalibrationVerdict?)
    /// The user asked to fix one quadrant rather than accept the fit.
    func gazeCalibration(
        _ controller: GazeCalibrationViewController,
        didRequestTouchUp quadrant: GazeScreenQuadrant)
    func gazeCalibrationDidCancel(_ controller: GazeCalibrationViewController)
}

/// The full-screen calibration: follow a dot, turn your head, look at four
/// corners, read the verdict.
///
/// The verdict is stated in DEGREES because that is the number that means
/// something to a reader — a pixel error means nothing without knowing the
/// screen and how far away it is held.
public final class GazeCalibrationViewController: UIViewController,
                                                  GazeTrackingDelegate, ReadAlongTickReceiving {

    public weak var delegate: GazeCalibrationViewControllerDelegate?

    public let style: GazeCalibrationStyle
    public private(set) var flow: GazeCalibrationFlow?

    private let gazeTracker: GazeTracking
    private let ticker: ReadAlongTicking
    private let clock: ReadAlongClock
    private let store: GazeCalibrationStore
    private let pointsPerDegree: CGFloat
    private let portraitScreenSize: CGSize

    private let dotLayer = CAShapeLayer()
    private let haloLayer = CAShapeLayer()
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let panel = UIStackView()
    private let primaryButton = UIButton(type: .system)
    private let secondaryButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)

    private var hasBegun = false

    // MARK: - Life cycle

    public init(
        style: GazeCalibrationStyle,
        gazeTracker: GazeTracking? = nil,
        ticker: ReadAlongTicking = DisplayLinkTicker(),
        clock: ReadAlongClock = SystemReadAlongClock(),
        store: GazeCalibrationStore = GazeCalibrationStore(),
        screenSize: CGSize = UIScreen.main.fixedCoordinateSpace.bounds.size,
        idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom
    ) {
        self.style = style
        self.gazeTracker = gazeTracker ?? ARFaceGazeTracker()
        self.ticker = ticker
        self.clock = clock
        self.store = store
        self.portraitScreenSize = screenSize
        self.pointsPerDegree = VisualAngle.pointsPerDegree(idiom: idiom)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        gazeTracker.stop()
        ticker.stop()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background
        buildDot()
        buildPanel()
        installGestures()
        registerForTraitChanges([LunaSkyTrait.self]) {
            (self: GazeCalibrationViewController, _: UITraitCollection) in
            self.refreshColours()
        }
        showIntro()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        gazeTracker.delegate = self
        ticker.target = self
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        gazeTracker.stop()
        ticker.stop()
    }

    public override var prefersStatusBarHidden: Bool { true }

    public override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))]
    }

    // MARK: - Chrome

    private func buildDot() {
        for layer in [haloLayer, dotLayer] {
            layer.actions = ["path": NSNull(), "fillColor": NSNull(), "opacity": NSNull()]
            layer.isHidden = true
            view.layer.addSublayer(layer)
        }
        refreshColours()
    }

    private func buildPanel() {
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.textAlignment = .center
        bodyLabel.font = .preferredFont(forTextStyle: .body)
        bodyLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.numberOfLines = 0
        bodyLabel.textAlignment = .center

        primaryButton.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)
        secondaryButton.addTarget(self, action: #selector(secondaryTapped), for: .touchUpInside)
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        cancelButton.setTitle(L10n.string("WriterReadAlong_calibrationCancel"), for: .normal)

        panel.axis = .vertical
        panel.spacing = 16
        panel.alignment = .fill
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addArrangedSubview(titleLabel)
        panel.addArrangedSubview(bodyLabel)
        panel.addArrangedSubview(primaryButton)
        panel.addArrangedSubview(secondaryButton)
        panel.addArrangedSubview(cancelButton)
        view.addSubview(panel)

        NSLayoutConstraint.activate([
            panel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            panel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            panel.widthAnchor.constraint(
                lessThanOrEqualToConstant: LunaLayout.readableWidth),
            panel.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 28),
            panel.trailingAnchor.constraint(
                lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -28),
        ])
        refreshColours()
    }

    private func installGestures() {
        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(cancel))
        swipe.direction = .down
        view.addGestureRecognizer(swipe)
    }

    private func refreshColours() {
        titleLabel.textColor = LunaColors.primaryText
        bodyLabel.textColor = LunaColors.secondaryText
        cancelButton.setTitleColor(LunaColors.secondaryText, for: .normal)
        let accent = GlassStyle.readingAccent.resolvedColor(with: traitCollection)
        dotLayer.fillColor = accent.cgColor
        haloLayer.fillColor = accent.withAlphaComponent(0.18).cgColor
    }

    // MARK: - Stages

    private func showIntro() {
        hasBegun = false
        titleLabel.text = L10n.string("WriterReadAlong_calibrationIntroTitle")
        bodyLabel.text = introBody
        primaryButton.configuration = GlassStyle.primaryActionButtonConfiguration(
            title: L10n.string("WriterReadAlong_calibrationBegin"), symbol: "eye")
        primaryButton.isHidden = false
        secondaryButton.isHidden = true
        cancelButton.isHidden = false
        panel.isHidden = false
        hideDot()
    }

    private var introBody: String {
        switch style {
        case .full: return L10n.string("WriterReadAlong_calibrationIntroFull")
        case .quick: return L10n.string("WriterReadAlong_calibrationIntroQuick")
        case .region: return L10n.string("WriterReadAlong_calibrationIntroRegion")
        }
    }

    @objc private func primaryTapped() {
        guard hasBegun else {
            begin()
            return
        }
        finish()
    }

    @objc private func secondaryTapped() {
        guard let quadrant = flow?.touchUpQuadrant else { return }
        delegate?.gazeCalibration(self, didRequestTouchUp: quadrant)
    }

    @objc private func cancel() {
        flow?.cancel()
        gazeTracker.stop()
        ticker.stop()
        delegate?.gazeCalibrationDidCancel(self)
    }

    private func begin() {
        hasBegun = true
        let bounds = view.bounds.inset(by: view.safeAreaInsets)
        let flow = GazeCalibrationFlow(
            style: style, bounds: bounds, pointsPerDegree: pointsPerDegree)
        self.flow = flow
        panel.isHidden = false
        primaryButton.isHidden = true
        secondaryButton.isHidden = true
        gazeTracker.delegate = self
        ticker.target = self
        gazeTracker.start()
        ticker.start()
        flow.begin(at: clock.now)
        render(stage: flow.stage)
    }

    private func finish() {
        gazeTracker.stop()
        ticker.stop()
        guard let flow, let calibration = flow.calibration else {
            delegate?.gazeCalibrationDidCancel(self)
            return
        }
        store.save(calibration, for: currentOrientation)
        delegate?.gazeCalibration(self, didFinishWith: calibration, verdict: flow.verdict)
    }

    private var currentOrientation: UIInterfaceOrientation {
        view.window?.windowScene?.interfaceOrientation ?? .portrait
    }

    // MARK: - Frames

    public func readAlongDidTick(at time: TimeInterval) {
        guard let flow else { return }
        let before = flow.stage
        let stage = flow.tick(at: time)
        if stage != before { render(stage: stage) }
        layoutDot(at: flow.dotPosition)
    }

    public func gazeTracker(_ tracker: GazeTracking, didProduce sample: GazeSample) {
        guard let flow else { return }
        let time = clock.now
        var raw = CGPoint.zero
        var faceTracked = true
        switch sample {
        case .point(let point):
            raw = GazeScreenProjection.orientedScreenPoint(
                fromPortraitPoint: point,
                portraitSize: portraitScreenSize,
                orientation: currentOrientation)
        case .offScreen:
            faceTracked = true
        case .faceLost:
            faceTracked = false
        }
        // `GazeTracking` reports neither blend shapes nor iris units, so the
        // blink filter is inert and the saccade filter reads the estimate's
        // own speed, normalised by the screen. `GazeCalibrationFlow
        // .saccadeVelocity` is set for that space.
        let size = view.bounds.size
        let units = CGPoint(
            x: raw.x / max(size.width, 1), y: raw.y / max(size.height, 1))
        flow.ingest(
            CalibrationFrame(
                time: time, raw: raw, eyeUnits: units, blink: 0, isFaceTracked: faceTracked))
    }

    // MARK: - Rendering

    private func render(stage: GazeCalibrationStage) {
        switch stage {
        case .intro:
            showIntro()
        case .pursuit:
            panel.isHidden = true
            showDot()
        case .headTurn:
            panel.isHidden = false
            titleLabel.text = L10n.string("WriterReadAlong_calibrationHeadTurnTitle")
            bodyLabel.text = L10n.string("WriterReadAlong_calibrationHeadTurnBody")
            primaryButton.isHidden = true
            secondaryButton.isHidden = true
            cancelButton.isHidden = true
            showDot()
        case .validation:
            panel.isHidden = true
            showDot()
        case .verdict:
            hideDot()
            showVerdict()
        case .failed:
            hideDot()
            showFailure()
        }
    }

    private func showVerdict() {
        guard let flow, let verdict = flow.verdict else {
            showFailure()
            return
        }
        panel.isHidden = false
        cancelButton.isHidden = false
        titleLabel.text = gradeTitle(verdict.grade)
        bodyLabel.text = L10n.string(
            "WriterReadAlong_calibrationVerdictBody",
            Double(verdict.degrees))
        primaryButton.isHidden = false
        primaryButton.configuration = GlassStyle.primaryActionButtonConfiguration(
            title: L10n.string("WriterReadAlong_calibrationDone"), symbol: "checkmark")
        if let quadrant = flow.touchUpQuadrant {
            secondaryButton.isHidden = false
            secondaryButton.configuration = GlassStyle.actionButtonConfiguration(
                title: L10n.string(
                    "WriterReadAlong_calibrationTouchUp", quadrantName(quadrant)),
                symbol: "scope")
        } else {
            secondaryButton.isHidden = true
        }
    }

    private func showFailure() {
        panel.isHidden = false
        titleLabel.text = L10n.string("WriterReadAlong_calibrationFailedTitle")
        bodyLabel.text = L10n.string("WriterReadAlong_calibrationFailedBody")
        primaryButton.isHidden = true
        secondaryButton.isHidden = true
        cancelButton.isHidden = false
    }

    private func gradeTitle(_ grade: CalibrationVerdict.Grade) -> String {
        switch grade {
        case .good: return L10n.string("WriterReadAlong_calibrationGradeGood")
        case .usable: return L10n.string("WriterReadAlong_calibrationGradeUsable")
        case .rough: return L10n.string("WriterReadAlong_calibrationGradeRough")
        }
    }

    private func quadrantName(_ quadrant: GazeScreenQuadrant) -> String {
        switch quadrant {
        case .topLeft: return L10n.string("WriterReadAlong_quadrantTopLeft")
        case .topRight: return L10n.string("WriterReadAlong_quadrantTopRight")
        case .bottomLeft: return L10n.string("WriterReadAlong_quadrantBottomLeft")
        case .bottomRight: return L10n.string("WriterReadAlong_quadrantBottomRight")
        }
    }

    private func showDot() {
        dotLayer.isHidden = false
        haloLayer.isHidden = false
    }

    private func hideDot() {
        dotLayer.isHidden = true
        haloLayer.isHidden = true
    }

    private func layoutDot(at point: CGPoint?) {
        guard let point else {
            hideDot()
            return
        }
        dotLayer.path = UIBezierPath(
            arcCenter: point, radius: 7, startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
        haloLayer.path = UIBezierPath(
            arcCenter: point, radius: 20, startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
    }
}

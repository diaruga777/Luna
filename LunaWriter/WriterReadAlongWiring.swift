import UIKit
import LunaGaze
import LunaWriterEditor
import LunaWriterLibraryUI
import LunaWriterModels
import LunaWriterReadAlong
import LunaWriterStorage
import LunaWriterText
import LunaWriterVoice

/// Carries a read-along rendering layer into the editor's composer as its
/// `.reading` layer, so the band and the marks draw as rendering attributes.
final class ReadAlongLayerBridge: RenderingAttributeLayer, ReadAlongRenderingLayerInvalidating {
    let identifier: LayerID = .reading
    private let layer: ReadAlongRenderingLayer
    private weak var editor: EditorViewController?

    init(layer: ReadAlongRenderingLayer, editor: EditorViewController) {
        self.layer = layer
        self.editor = editor
        layer.invalidationDelegate = self
    }

    func contributions(in range: NSRange, text: NSString) -> [RangedAttributes] {
        layer.attributes(in: range).map { RangedAttributes(range: $0.0, attributes: $0.1) }
    }

    func renderingLayer(_ layer: ReadAlongRenderingLayer, didInvalidate range: NSRange) {
        editor?.invalidateRendering(range)
    }
}

extension WriterEditorScreen: ReadAlongTextHosting {
    var hostView: UIView { editor.readAlongHost }
    var scrollView: UIScrollView { editor.textView }
    var textLength: Int { session.storage.nsText.length }

    func sentenceLayouts() -> [SentenceLayout] {
        editor.sentenceGeometry.layout(for: NSRange(location: 0, length: textLength))
    }

    func textContainerOrigin() -> CGPoint {
        let inset = editor.textView.textContainerInset
        return CGPoint(x: inset.left + editor.textView.textContainer.lineFragmentPadding, y: inset.top)
    }

    func installOverlayLayer(_ layer: ReadAlongRenderingLayer) {
        editor.installOverlayLayer(ReadAlongLayerBridge(layer: layer, editor: editor))
    }

    func removeOverlayLayer() { editor.removeOverlayLayer() }

    func anchor(for range: NSRange) -> TextAnchor {
        TextAnchorResolver.make(range: range, in: session.storage.nsText)
    }

    func range(for anchor: TextAnchor) -> NSRange? {
        TextAnchorResolver.resolve(anchor, in: session.storage.nsText)
    }
}

/// One read-along session per open editor: the coordinator, its HUD chip and
/// the calibration screen. Absent on a device with neither gaze nor voice.
@MainActor final class WriterReadAlongChrome: NSObject, ReadAlongChromeProviding, ReadAlongSettingsHandling,
    ReadAlongHUDViewDelegate, ReadAlongCoordinatorDelegate, GazeCalibrationViewControllerDelegate {

    private let storage: WriterStorageStack
    private let availability: ReadAlongAvailability
    private var sessions: [ObjectIdentifier: Session] = [:]

    private final class Session {
        let coordinator: ReadAlongCoordinator
        let hud: ReadAlongHUDView
        weak var screen: WriterEditorScreen?
        init(coordinator: ReadAlongCoordinator, hud: ReadAlongHUDView, screen: WriterEditorScreen) {
            self.coordinator = coordinator; self.hud = hud; self.screen = screen
        }
    }

    init?(storage: WriterStorageStack) {
        let availability = ReadAlongAvailability.resolve(transcriber: SpeechTranscriberFactory.make(locale: .current))
        guard availability.gaze || availability.voice else { return nil }
        self.storage = storage
        self.availability = availability
    }

    // MARK: ReadAlongChromeProviding

    func readAlongChrome(for editor: UIViewController & DocumentEditing) -> UIView? {
        guard let screen = editor as? WriterEditorScreen else { return nil }
        prune()
        let coordinator = ReadAlongCoordinator(
            documentID: screen.document.id, host: screen,
            marks: storage.library, notes: storage.library, settings: storage.settings)
        coordinator.delegate = self
        let hud = ReadAlongHUDView(frame: .zero)
        hud.delegate = self
        hud.apply(coordinator.state)
        sessions[ObjectIdentifier(hud)] = Session(coordinator: coordinator, hud: hud, screen: screen)
        if coordinator.state.gazeEnabled || coordinator.state.voiceEnabled {
            coordinator.start()
        }
        return hud
    }

    private func prune() {
        sessions = sessions.filter { $0.value.screen != nil }
    }

    private func session(for hud: ReadAlongHUDView) -> Session? { sessions[ObjectIdentifier(hud)] }

    private func session(for coordinator: ReadAlongCoordinator) -> Session? {
        sessions.values.first { $0.coordinator === coordinator }
    }

    // MARK: ReadAlongSettingsHandling

    var gazeAvailable: Bool { availability.gaze }
    var voiceAvailable: Bool { availability.voice }
    var lastCalibrationGrade: String? { storage.settings.lastCalibrationGrade }

    func presentCalibration(from presenter: UIViewController) {
        present(style: .full, from: presenter, applyingTo: nil)
    }

    private func present(style: GazeCalibrationStyle, from presenter: UIViewController, applyingTo coordinator: ReadAlongCoordinator?) {
        let screen = GazeCalibrationViewController(style: style)
        screen.delegate = self
        screen.modalPresentationStyle = .fullScreen
        pendingCalibrationTarget = coordinator
        presenter.present(screen, animated: true)
    }

    private weak var pendingCalibrationTarget: ReadAlongCoordinator?

    // MARK: ReadAlongHUDViewDelegate

    func readAlongHUD(_ hud: ReadAlongHUDView, didRequestCalibration style: GazeCalibrationStyle) {
        guard let session = session(for: hud), let screen = session.screen else { return }
        present(style: style, from: screen, applyingTo: session.coordinator)
    }

    func readAlongHUDDidTogglePause(_ hud: ReadAlongHUDView) { session(for: hud)?.coordinator.togglePause() }

    func readAlongHUDDidToggleGaze(_ hud: ReadAlongHUDView) {
        guard let session = session(for: hud) else { return }
        session.coordinator.setGazeEnabled(!session.coordinator.state.gazeEnabled)
    }

    func readAlongHUDDidToggleVoice(_ hud: ReadAlongHUDView) {
        guard let session = session(for: hud) else { return }
        session.coordinator.setVoiceEnabled(!session.coordinator.state.voiceEnabled)
    }

    func readAlongHUDDidToggleDiagnostics(_ hud: ReadAlongHUDView) {
        guard let session = session(for: hud) else { return }
        session.coordinator.setDiagnosticsVisible(!session.coordinator.isDiagnosticsVisible)
        hud.diagnosticsVisible = session.coordinator.isDiagnosticsVisible
    }

    func readAlongHUDDidRequestClearAnnotations(_ hud: ReadAlongHUDView) {
        session(for: hud)?.coordinator.clearAnnotations()
    }

    // MARK: ReadAlongCoordinatorDelegate

    func readAlongCoordinator(_ coordinator: ReadAlongCoordinator, didChange state: ReadAlongState) {
        session(for: coordinator)?.hud.apply(state)
        if let grade = state.calibrationGrade { storage.settings.lastCalibrationGrade = grade.rawValue }
    }

    func readAlongCoordinatorNeedsRecalibration(_ coordinator: ReadAlongCoordinator) {
        guard let screen = session(for: coordinator)?.screen else { return }
        present(style: .quick, from: screen, applyingTo: coordinator)
    }

    // MARK: GazeCalibrationViewControllerDelegate

    func gazeCalibration(_ controller: GazeCalibrationViewController, didFinishWith calibration: GazeAffineCalibration, verdict: CalibrationVerdict?) {
        pendingCalibrationTarget?.apply(calibration, verdict: verdict)
        if let grade = verdict?.grade { storage.settings.lastCalibrationGrade = grade.rawValue }
        controller.dismiss(animated: true)
    }

    func gazeCalibration(_ controller: GazeCalibrationViewController, didRequestTouchUp quadrant: GazeScreenQuadrant) {
        guard let presenter = controller.presentingViewController else { return }
        let target = pendingCalibrationTarget
        controller.dismiss(animated: true) { [weak self] in
            self?.present(style: .region(quadrant), from: presenter, applyingTo: target)
        }
    }

    func gazeCalibrationDidCancel(_ controller: GazeCalibrationViewController) {
        controller.dismiss(animated: true)
    }
}

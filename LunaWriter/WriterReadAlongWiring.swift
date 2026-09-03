import UIKit
import LunaGaze
import LunaModels
import LunaWriterEditor
import LunaWriterLibraryUI
import LunaWriterModels
import LunaWriterReadAlong
import LunaWriterStorage
import LunaWriterText
import LunaWriterVoice

/// Carries a read-along rendering layer into the editor's composer under the
/// given id, so the band draws as rendering attributes.
final class ReadAlongLayerBridge: RenderingAttributeLayer, ReadAlongRenderingLayerInvalidating {
    let identifier: LayerID
    private let layer: ReadAlongRenderingLayer
    private weak var editor: EditorViewController?

    init(identifier: LayerID, layer: ReadAlongRenderingLayer, editor: EditorViewController) {
        self.identifier = identifier
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
        editor.installOverlayLayer(ReadAlongLayerBridge(identifier: .reading, layer: layer, editor: editor))
    }

    func removeOverlayLayer() { editor.removeOverlayLayer() }

    func anchor(for range: NSRange) -> TextAnchor {
        TextAnchorResolver.make(range: range, in: session.storage.nsText)
    }

    func range(for anchor: TextAnchor) -> NSRange? {
        TextAnchorResolver.resolve(anchor, in: session.storage.nsText)
    }

    var storedAnnotations: [Annotation] { session.allStoredAnnotations }
    func addAnnotation(_ annotation: Annotation) { session.add(annotation) }
    func updateAnnotation(_ annotation: Annotation) { session.updateAnnotation(annotation) }
    func removeAnnotation(_ id: AnnotationID) { session.removeAnnotation(id) }
}

/// One read-along session per open editor: the coordinator, its HUD chip, the
/// annotation popover and the calibration screen. Absent on a device with
/// neither gaze nor voice.
@MainActor final class WriterReadAlongChrome: NSObject, ReadAlongChromeProviding, ReadAlongSettingsHandling,
    ReadAlongHUDViewDelegate, ReadAlongCoordinatorDelegate, GazeCalibrationViewControllerDelegate {

    private let storage: WriterStorageStack
    private let trackerMaker: GazeTrackerMaking?
    private var availability: ReadAlongAvailability
    private var sessions: [ObjectIdentifier: Session] = [:]
    private var lifecycleObservers: [NSObjectProtocol] = []

    /// Everything one open sheet's read-along owns. The screen is held weakly
    /// and the coordinator holds it weakly too, so a closed sheet's session
    /// is torn down by `tearDownReadAlong` and, failing that, pruned.
    private final class Session: NSObject, EditorLayoutObserving, EditorMenuAugmenting,
        UIGestureRecognizerDelegate
    {
        let coordinator: ReadAlongCoordinator
        let hud: ReadAlongHUDView
        let presenter: AnnotationPresenter
        weak var screen: WriterEditorScreen?
        let tap: UITapGestureRecognizer

        init(coordinator: ReadAlongCoordinator, hud: ReadAlongHUDView, presenter: AnnotationPresenter, screen: WriterEditorScreen) {
            self.coordinator = coordinator
            self.hud = hud
            self.presenter = presenter
            self.screen = screen
            self.tap = UITapGestureRecognizer()
            super.init()
            tap.cancelsTouchesInView = false
            tap.delegate = self
            tap.addTarget(self, action: #selector(textTapped(_:)))
            screen.editor.textView.addGestureRecognizer(tap)
            screen.layoutObserver = self
            screen.editor.menuAugmenter = self
            syncGeometry(from: screen.editor)
        }

        func tearDown() {
            coordinator.stop()
            screen?.editor.textView.removeGestureRecognizer(tap)
            if screen?.layoutObserver === self { screen?.layoutObserver = nil }
            if screen?.editor.menuAugmenter === self { screen?.editor.menuAugmenter = nil }
        }

        /// The window scene's orientation and display size, once the editor
        /// is on screen. Both change on rotation, which is a relayout.
        private func syncGeometry(from editor: EditorViewController) {
            guard let scene = editor.view.window?.windowScene else { return }
            coordinator.portraitScreenSize = scene.screen.fixedCoordinateSpace.bounds.size
            coordinator.interfaceOrientation = scene.interfaceOrientation
        }

        // MARK: EditorLayoutObserving

        func editorDidRelayout(_ editor: EditorViewController) {
            syncGeometry(from: editor)
            coordinator.viewDidResize(to: editor.textView.bounds.size)
        }

        /// The assist's own scrolling arrives here too; only the user's
        /// finger counts as the user scrolling.
        func editorDidScroll(_ editor: EditorViewController) {
            let scrollView = editor.textView
            guard scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating else { return }
            coordinator.userDidScroll()
        }

        // MARK: EditorMenuAugmenting

        func editor(_ editor: EditorViewController, menuElementsFor selection: NSRange) -> [UIMenuElement] {
            presenter.readAlongMenu(for: selection).map { [$0] } ?? []
        }

        // MARK: Tap on a mark

        /// `point` in the text view, as a text-container point.
        private func containerPoint(for point: CGPoint, in screen: WriterEditorScreen) -> CGPoint {
            let origin = screen.textContainerOrigin()
            return CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        }

        /// A tap recogniser on a `UITextView` competes with the text view's
        /// own tap, which is what places the caret and raises the keyboard.
        /// This one takes a touch only when a mark is under it, and even then
        /// lets the text view's recognisers run beside it.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let screen else { return false }
            let point = containerPoint(for: touch.location(in: screen.editor.textView), in: screen)
            return presenter.annotation(atContainerPoint: point) != nil
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc private func textTapped(_ recognizer: UITapGestureRecognizer) {
            guard let screen else { return }
            let container = containerPoint(for: recognizer.location(in: screen.editor.textView), in: screen)
            let rect = CGRect(origin: recognizer.location(in: screen.editor.readAlongHost), size: .zero)
                .insetBy(dx: -4, dy: -12)
            presenter.presentPopover(forContainerPoint: container, from: rect, in: screen.editor.readAlongHost)
        }
    }

    init?(storage: WriterStorageStack, trackerMaker: GazeTrackerMaking?) {
        let availability = ReadAlongAvailability.resolve(transcriber: SpeechTranscriberFactory.make(locale: .current))
        let gaze = availability.gaze && trackerMaker != nil
        guard gaze || availability.voice || availability.voiceIsUnasked else { return nil }
        self.storage = storage
        self.trackerMaker = trackerMaker
        self.availability = availability
        super.init()
        observeLifecycle()
    }

    deinit {
        for observer in lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Backgrounding suspends every session; the foreground resumes them
    /// with a fresh availability read, since a permission may have changed
    /// in Settings meanwhile.
    private func observeLifecycle() {
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessions.values.forEach { $0.coordinator.suspend() } }
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.availability = ReadAlongAvailability.resolve(
                    transcriber: SpeechTranscriberFactory.make(locale: .current))
                self.sessions.values.forEach { $0.coordinator.resume() }
            }
        })
    }

    // MARK: ReadAlongChromeProviding

    func readAlongChrome(for editor: UIViewController & DocumentEditing) -> UIView? {
        guard let screen = editor as? WriterEditorScreen else { return nil }
        prune()
        let display = Self.displayGeometry(for: screen)
        let coordinator = ReadAlongCoordinator(
            documentID: screen.document.id, host: screen,
            notes: storage.library, settings: storage.settings,
            gazeTracker: trackerMaker?.makeGazeTracker(),
            transcriber: SpeechTranscriberFactory.make(locale: .current),
            screenSize: display.size, idiom: display.idiom)
        coordinator.delegate = self
        let hud = ReadAlongHUDView(frame: .zero)
        hud.delegate = self
        hud.apply(coordinator.state)
        let presenter = AnnotationPresenter(
            markStore: coordinator.markStore, coordinator: coordinator, host: screen, presenter: screen)
        sessions[ObjectIdentifier(screen)] = Session(
            coordinator: coordinator, hud: hud, presenter: presenter, screen: screen)
        if coordinator.state.gazeEnabled || coordinator.state.voiceEnabled {
            coordinator.start()
        }
        return hud
    }

    func tearDownReadAlong(for editor: UIViewController & DocumentEditing) {
        guard let session = sessions.removeValue(forKey: ObjectIdentifier(editor)) else { return }
        session.tearDown()
    }

    /// The display the screen is on. Before the screen is in a window (the
    /// container builds the chrome in `viewDidLoad`) the main screen stands
    /// in; the session corrects it on the first layout pass.
    private static func displayGeometry(for screen: UIViewController) -> (size: CGSize, idiom: UIUserInterfaceIdiom) {
        let uiScreen = screen.view.window?.windowScene?.screen ?? UIScreen.main
        return (uiScreen.fixedCoordinateSpace.bounds.size, screen.traitCollection.userInterfaceIdiom == .unspecified
            ? UIDevice.current.userInterfaceIdiom : screen.traitCollection.userInterfaceIdiom)
    }

    private func prune() {
        for (key, session) in sessions where session.screen == nil {
            session.tearDown()
            sessions[key] = nil
        }
    }

    private func session(for hud: ReadAlongHUDView) -> Session? {
        sessions.values.first { $0.hud === hud }
    }

    private func session(for coordinator: ReadAlongCoordinator) -> Session? {
        sessions.values.first { $0.coordinator === coordinator }
    }

    // MARK: ReadAlongSettingsHandling

    var gazeAvailable: Bool { availability.gaze && trackerMaker != nil }
    var voiceAvailable: Bool { availability.voice || availability.voiceIsUnasked }
    var lastCalibrationGrade: String? { storage.settings.lastCalibrationGrade }

    func presentCalibration(from presenter: UIViewController) {
        present(style: .full, from: presenter, applyingTo: nil)
    }

    /// While the calibration screen runs its own tracker every session is
    /// suspended: ARKit runs one face-tracking session per app, and two
    /// would fight for the camera.
    private func present(style: GazeCalibrationStyle, from presenter: UIViewController, applyingTo coordinator: ReadAlongCoordinator?) {
        let display = Self.displayGeometry(for: presenter)
        let screen = GazeCalibrationViewController(
            style: style, gazeTracker: trackerMaker?.makeGazeTracker(),
            screenSize: display.size, idiom: display.idiom)
        screen.delegate = self
        screen.modalPresentationStyle = .fullScreen
        pendingCalibrationTarget = coordinator
        sessions.values.forEach { $0.coordinator.suspend() }
        presenter.present(screen, animated: true)
    }

    private weak var pendingCalibrationTarget: ReadAlongCoordinator?

    private func resumeAfterCalibration() {
        pendingCalibrationTarget = nil
        sessions.values.forEach { $0.coordinator.resume() }
    }

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
        guard let session = session(for: coordinator) else { return }
        session.hud.apply(state)
        if !coordinator.isRunning, state.gazeEnabled || state.voiceEnabled {
            coordinator.start()
        }
        if let grade = state.calibrationGrade { storage.settings.lastCalibrationGrade = grade.rawValue }
    }

    func readAlongCoordinatorNeedsRecalibration(_ coordinator: ReadAlongCoordinator) {
        guard let screen = session(for: coordinator)?.screen else { return }
        present(style: .quick, from: screen, applyingTo: coordinator)
    }

    func readAlongCoordinator(_ coordinator: ReadAlongCoordinator, didRefusePermissionFor half: ReadAlongHalf) {
        guard let screen = session(for: coordinator)?.screen else { return }
        let title: String
        let body: String
        switch half {
        case .gaze:
            title = L10n.string("WriterReadAlong_permissionRefusedGazeTitle")
            body = L10n.string("WriterReadAlong_permissionRefusedGazeBody")
        case .voice:
            title = L10n.string("WriterReadAlong_permissionRefusedVoiceTitle")
            body = L10n.string("WriterReadAlong_permissionRefusedVoiceBody")
        }
        let alert = UIAlertController(title: title, message: body, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("Common_openSettings"), style: .default) { _ in
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        })
        screen.present(alert, animated: true)
    }

    // MARK: GazeCalibrationViewControllerDelegate

    /// A fit made from the HUD applies to that sheet; one made from Settings
    /// applies to every open sheet, since the store it was saved to is what
    /// they all read on resume.
    func gazeCalibration(_ controller: GazeCalibrationViewController, didFinishWith calibration: GazeAffineCalibration, verdict: CalibrationVerdict?) {
        if let target = pendingCalibrationTarget {
            target.apply(calibration, verdict: verdict)
        } else {
            sessions.values.forEach { $0.coordinator.apply(calibration, verdict: verdict) }
        }
        if let grade = verdict?.grade { storage.settings.lastCalibrationGrade = grade.rawValue }
        controller.dismiss(animated: true)
        resumeAfterCalibration()
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
        resumeAfterCalibration()
    }
}

//
//  GazeTracker.swift
//  LunaGaze
//

import ARKit
import AVFoundation
import CoreGraphics
import Foundation
import UIKit

/// The reader of a gaze source's samples.
public protocol GazeTrackingDelegate: AnyObject {
    /// Called on the main queue for every usable camera frame. Points are in
    /// `UIScreen.fixedCoordinateSpace` (portrait-origin) coordinates.
    func gazeTracker(_ tracker: GazeTracking, didProduce sample: GazeSample)
    /// Called alongside `gazeTracker(_:didProduce:)`, with the same frame's
    /// blink state added. Optional: the Reader's RSVP tracking has no use for
    /// blink and implements only the method above.
    func gazeTracker(_ tracker: GazeTracking, didProduce frame: GazeFrame)
}

extension GazeTrackingDelegate {
    public func gazeTracker(_ tracker: GazeTracking, didProduce frame: GazeFrame) {}
}

/// A source of gaze estimates. The RSVP reader talks to this rather than to
/// ARKit directly, so its wiring can be exercised with a stub.
public protocol GazeTracking: AnyObject {
    var delegate: GazeTrackingDelegate? { get set }
    var isRunning: Bool { get }
    func start()
    func stop()
}

/// Whether gaze tracking can run in this process at all.
public enum GazeTrackingAvailability {

    /// Test seam. `nil` (the default) means "ask the device".
    static var supportOverride: Bool?

    /// True only in a host app on hardware with a TrueDepth camera.
    ///
    /// App extensions are excluded outright: the share/action extensions embed
    /// the same RSVP reader but carry their own Info.plists with no camera
    /// usage description, so asking for authorization there would be a crash
    /// rather than a prompt.
    public static var isSupported: Bool {
        if let supportOverride { return supportOverride }
        guard !isAppExtension else { return false }
        return ARFaceTrackingConfiguration.isSupported
    }

    static var isAppExtension: Bool {
        Bundle.main.bundleURL.pathExtension == "appex"
    }
}

/// Camera authorization, which is what "permission to track your eyes" means on
/// iOS — ARKit face tracking is a front-camera capture session.
///
/// The prompt is deliberately NOT requested at launch, nor when the RSVP reader
/// opens: it is requested the first time the user turns the toggle on, so the
/// system alert arrives with the feature it is for.
public enum GazeTrackingPermission {

    public enum Status: Equatable { case granted, denied, undetermined }

    /// Test seam, mirroring `GazeTrackingAvailability.supportOverride`.
    static var statusOverride: Status?

    public static var status: Status {
        if let statusOverride { return statusOverride }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .notDetermined: return .undetermined
        default: return .denied
        }
    }

    /// Requests access if it has never been asked, then reports the outcome on
    /// the main queue.
    public static func request(_ completion: @escaping (Status) -> Void) {
        if statusOverride != nil {
            completion(status)
            return
        }
        guard status == .undetermined else {
            completion(status)
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { completion(granted ? .granted : .denied) }
        }
    }
}

/// Drives a bare `ARSession` with `ARFaceTrackingConfiguration` — no renderer,
/// no view — and publishes one `GazeSample` per frame.
///
/// ARKit calls every `ARSessionDelegate` method on the main queue when
/// `session.delegateQueue` is left nil (Apple's documented default, which
/// this class never overrides), and `start()`/`stop()` are always called from
/// the same main-thread coordinators that receive those callbacks — so
/// `isRunning` has one writer at a time despite having no lock of its own.
public final class ARFaceGazeTracker: NSObject, GazeTracking, ARSessionDelegate {

    public weak var delegate: GazeTrackingDelegate?
    public private(set) var isRunning = false

    private lazy var session: ARSession = {
        let session = ARSession()
        session.delegate = self
        return session
    }()

    private let pointsPerMetre: CGFloat
    private let screenSizeProvider: () -> CGSize
    /// Captured once in `start()`, not read per frame: `UIScreen.main` is
    /// deprecated and, under Stage Manager, does not name any one screen.
    private var screenSize: CGSize = .zero

    public init(
        idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom,
        screenSize: @autoclosure @escaping () -> CGSize = UIScreen.main.fixedCoordinateSpace.bounds.size
    ) {
        self.pointsPerMetre = GazeScreenProjection.pointsPerMetre(idiom: idiom)
        self.screenSizeProvider = screenSize
        super.init()
    }

    public func start() {
        guard !isRunning, GazeTrackingAvailability.isSupported,
              ARFaceTrackingConfiguration.isSupported
        else { return }
        screenSize = screenSizeProvider()
        let configuration = ARFaceTrackingConfiguration()
        configuration.isLightEstimationEnabled = false
        // One face is all that can be reading the screen; tracking more would
        // only cost frames.
        configuration.maximumNumberOfTrackedFaces = 1
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        session.pause()
        isRunning = false
    }

    // MARK: - ARSessionDelegate

    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isRunning else { return }
        guard let face = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first,
              face.isTracked
        else {
            emit(.faceLost, blinkLeft: 0, blinkRight: 0, isFaceTracked: false)
            return
        }
        let blink = GazeGate.blink(from: face.blendShapes)
        emit(
            sample(for: face, camera: frame.camera),
            blinkLeft: blink.left, blinkRight: blink.right, isFaceTracked: true)
    }

    public func session(_ session: ARSession, didFailWithError error: Error) {
        emit(.faceLost, blinkLeft: 0, blinkRight: 0, isFaceTracked: false)
        isRunning = false
    }

    public func sessionWasInterrupted(_ session: ARSession) {
        emit(.faceLost, blinkLeft: 0, blinkRight: 0, isFaceTracked: false)
    }

    /// The interruption that ended (a phone call, Control Center, another
    /// app taking the camera) leaves the session paused rather than tracking
    /// — resume the same configuration, or stay stopped if that itself fails.
    public func sessionInterruptionEnded(_ session: ARSession) {
        guard isRunning, ARFaceTrackingConfiguration.isSupported else {
            isRunning = false
            return
        }
        let configuration = ARFaceTrackingConfiguration()
        configuration.isLightEstimationEnabled = false
        configuration.maximumNumberOfTrackedFaces = 1
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    /// Projects one face anchor's gaze onto the display.
    ///
    /// The ray starts between the eyes rather than at either one — the two eye
    /// transforms disagree by a few millimetres of parallax at reading
    /// distance, and the midpoint is both steadier and closer to what the
    /// reader would call "where I'm looking".
    private func sample(for face: ARFaceAnchor, camera: ARCamera) -> GazeSample {
        let faceToCamera = camera.viewMatrix(for: .portrait) * face.transform
        let leftEye = face.leftEyeTransform.columns.3
        let rightEye = face.rightEyeTransform.columns.3
        let eyeMidpoint = (leftEye + rightEye) / 2

        let origin = (faceToCamera * eyeMidpoint).xyz
        let target = (faceToCamera * simd_float4(face.lookAtPoint, 1)).xyz

        // The point is emitted even when it lands beyond the display: the
        // coordinator subtracts the calibrated bias BEFORE deciding whether
        // the reader is looking past the phone, and a bias large enough to
        // push a fixated gaze off the display is exactly the case calibration
        // exists to rescue. `.offScreen` is reserved for a ray that never
        // meets the display plane at all.
        guard let point = GazeScreenProjection.screenPoint(
            eyeOrigin: origin, lookAt: target,
            screenSize: screenSize, pointsPerMetre: pointsPerMetre)
        else { return .offScreen }
        return .point(point)
    }

    private func emit(
        _ sample: GazeSample, blinkLeft: Double, blinkRight: Double, isFaceTracked: Bool
    ) {
        guard let delegate else { return }
        let frame = GazeFrame(
            sample: sample, blinkLeft: blinkLeft, blinkRight: blinkRight,
            isFaceTracked: isFaceTracked)
        if Thread.isMainThread {
            delegate.gazeTracker(self, didProduce: sample)
            delegate.gazeTracker(self, didProduce: frame)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                delegate.gazeTracker(self, didProduce: sample)
                delegate.gazeTracker(self, didProduce: frame)
            }
        }
    }
}

private extension simd_float4 {
    /// The positional part of a homogeneous point.
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}

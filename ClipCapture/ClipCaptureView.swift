//
//  ClipCaptureView.swift
//  ClipCapture
//

import AVFoundation
import AVKit
import CoreImage
import LockedCameraCapture
import SwiftUI
import UIKit
import UserNotifications

/// SwiftUI entry the LockedCameraCapture scene presents. Hosts the capture
/// view controller full-screen.
struct ClipCaptureView: View {
    let session: LockedCameraCaptureSession

    var body: some View {
        PocketCaptureControllerRepresentable()
            .ignoresSafeArea()
            .background(Color.black)
    }
}

private struct PocketCaptureControllerRepresentable: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> PocketCaptureViewController {
        PocketCaptureViewController()
    }
    func updateUIViewController(_ controller: PocketCaptureViewController, context: Context) {}
}

/// Minimal capture surface for the pocket trigger. Starts the back camera, waits a
/// few frames for exposure to settle, analyzes one frame's brightness, and — if it
/// looks like the inside of a pocket (very dark / uniform) — fires the trigger
/// notification. The hardware Camera Control / volume button forces an immediate
/// analysis via `AVCaptureEventInteraction`.
final class PocketCaptureViewController: UIViewController {

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "clip.capture.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let analyzer = PocketSceneAnalyzer()

    private let statusLabel = UILabel()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    /// Frames seen since start; the first few are skipped while auto-exposure settles.
    private var framesSeen = 0
    private var hasFired = false
    private var analysisResults: [PocketSceneAnalyzer.Result] = []
    private static let warmupFrames = 8
    /// Aggregate a handful of post-warmup frames (majority vote) so one noisy frame
    /// doesn't decide it.
    private static let analysisFrames = 6

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupStatusLabel()
        setupHardwareButton()
        sessionQueue.async { [weak self] in self?.configureSession() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    // MARK: - UI

    private func setupStatusLabel() {
        statusLabel.text = "Checking…"
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 18, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40),
        ])
    }

    /// Hardware Camera Control / volume button → force an immediate analysis even if
    /// the warmup window hasn't elapsed.
    private func setupHardwareButton() {
        let interaction = AVCaptureEventInteraction { [weak self] event in
            guard event.phase == .ended else { return }
            // framesSeen is owned by sessionQueue (where the sample-buffer delegate
            // reads it); mutate it there to avoid a cross-thread race.
            self?.sessionQueue.async { self?.framesSeen = Self.warmupFrames }
        } secondary: { _ in }
        view.addInteraction(interaction)
    }

    // MARK: - Camera

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video)
        guard let device,
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.statusLabel.text = "Camera unavailable" }
            return
        }
        session.addInput(input)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        session.commitConfiguration()
        session.startRunning()

        DispatchQueue.main.async { [weak self] in self?.installPreview() }
    }

    private func installPreview() {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
    }

    private func fire() {
        guard !hasFired, !analysisResults.isEmpty else { return }
        hasFired = true
        sessionQueue.async { [weak self] in self?.session.stopRunning() }

        let pocketVotes = analysisResults.filter(\.isPocket).count
        let isPocket = pocketVotes * 2 >= analysisResults.count  // majority
        let avgBrightness = analysisResults.map(\.brightness).reduce(0, +) / Double(analysisResults.count)

        if isPocket {
            ClipTriggerNotifier.fire(brightness: avgBrightness)
            DispatchQueue.main.async { [weak self] in
                self?.statusLabel.text = "Pocket detected — triggered ✓"
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.statusLabel.text = "Not a pocket shot"
            }
        }
    }
}

extension PocketCaptureViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !hasFired else { return }
        framesSeen += 1
        guard framesSeen >= Self.warmupFrames else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        analysisResults.append(analyzer.analyze(pixelBuffer))
        if analysisResults.count >= Self.analysisFrames {
            fire()
        }
    }
}

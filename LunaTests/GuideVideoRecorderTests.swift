//
//  GuideVideoRecorderTests.swift
//  LunaTests
//
//  Not a real test: a recorder, gated behind an env flag (mirroring the
//  `RECORD_SNAPSHOTS` pattern in `SnapshotTesting.swift`), that renders one loop of
//  a bundled `OnboardingAnimationView` illustration to an H.264 mp4 — the source
//  clips for the onboarding PiP guide videos (`Luna/OnboardingGuideVideo.swift`).
//
//  Regenerate with (see claudedocs/onboarding.md):
//    xcodebuild test -scheme Luna -only-testing:LunaTests/GuideVideoRecorderTests \
//      TEST_RUNNER_RECORD_GUIDE_VIDEOS=1 \
//      TEST_RUNNER_GUIDE_VIDEO_OUTPUT_DIR=/path/to/Luna/Resources ...
//

import AVFoundation
import CoreVideo
import LunaSocialUI
import UIKit
import XCTest

final class GuideVideoRecorderTests: XCTestCase {

    func testRecordSafariExtensionGuide() throws {
        try recordGuideVideo(kind: .safariExtension, filename: "SafariExtensionGuide")
    }

    func testRecordActionButtonGuide() throws {
        try recordGuideVideo(kind: .actionButtonSettings, filename: "ActionButtonGuide")
    }

    // MARK: - Recording

    /// The illustration's own fixed intrinsic size (`OnboardingAnimationView.init`'s
    /// per-kind `height`/`width`), before the 2x scale-up applied for recording.
    private func naturalSize(for kind: OnboardingAnimationView.Kind) -> CGSize {
        switch kind {
        case .safariExtension: return CGSize(width: 220, height: 360)
        case .actionButtonSettings: return CGSize(width: 280, height: 300)
        default: return CGSize(width: 260, height: 150)
        }
    }

    private func recordGuideVideo(
        kind: OnboardingAnimationView.Kind, filename: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        guard ProcessInfo.processInfo.environment["RECORD_GUIDE_VIDEOS"] == "1" else {
            throw XCTSkip("Set RECORD_GUIDE_VIDEOS=1 (with GUIDE_VIDEO_OUTPUT_DIR) to (re)generate guide videos.")
        }
        guard let outputDir = ProcessInfo.processInfo.environment["GUIDE_VIDEO_OUTPUT_DIR"], !outputDir.isEmpty
        else {
            XCTFail("GUIDE_VIDEO_OUTPUT_DIR must be set alongside RECORD_GUIDE_VIDEOS=1", file: file, line: line)
            return
        }

        // A clean 2x of the illustration's own even-dimension size — fills the
        // recorded frame exactly (no letterboxing) at a reasonably crisp PiP size.
        let scale: CGFloat = 2
        let natural = naturalSize(for: kind)
        let size = CGSize(width: natural.width * scale, height: natural.height * scale)

        let animation = OnboardingAnimationView(kind: kind)
        animation.backgroundColor = .systemBackground
        animation.transform = CGAffineTransform(scaleX: scale, y: scale)

        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = .light
        window.backgroundColor = .systemBackground
        window.addSubview(animation)
        animation.center = CGPoint(x: size.width / 2, y: size.height / 2)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        animation.start()

        // Wait out the animation's own one-time start-up delay so the recorded
        // clip begins right at the loop's clean seam.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        let outputURL = URL(fileURLWithPath: outputDir).appendingPathComponent("\(filename).mp4")
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let recorder = try FrameRecorder(view: window, size: size, duration: kind.loopDuration, outputURL: outputURL)
        let expectation = expectation(description: "recorded \(filename)")
        recorder.start { expectation.fulfill() }
        wait(for: [expectation], timeout: kind.loopDuration + 15)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path),
                      "expected a recorded clip at \(outputURL.path)", file: file, line: line)
        window.isHidden = true
    }
}

/// Drives a `CADisplayLink` while the current run loop is pumped (e.g. by
/// `XCTestCase.wait(for:timeout:)`), rendering `view`'s current on-screen
/// presentation into an `AVAssetWriter` H.264 mp4 at ~30fps for `duration` seconds.
///
/// Renders via `layer.presentation()?.render(in:)` rather than
/// `drawHierarchy(afterScreenUpdates:)` — `SnapshotTesting.swift` in this same test
/// target already established that `drawHierarchy` produces blank captures for
/// off-screen test windows on this runtime, whereas `render(in:)` rasterizes the
/// layer tree directly. `presentation()` (rather than the plain model layer) is
/// what makes this capture the CAKeyframeAnimation-driven illustration mid-flight,
/// not just its animation's static end state.
private final class FrameRecorder: NSObject {
    private let view: UIView
    private let size: CGSize
    private let duration: TimeInterval
    private let fps: Int32 = 30

    private let assetWriter: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor

    private var displayLink: CADisplayLink?
    private var startTimestamp: CFTimeInterval?
    private var framesWritten: Int64 = 0
    private var completion: (() -> Void)?

    init(view: UIView, size: CGSize, duration: TimeInterval, outputURL: URL) throws {
        self.view = view
        self.size = size
        self.duration = duration

        try? FileManager.default.removeItem(at: outputURL)
        assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: 800_000,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel,
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: compression,
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true

        let bufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ]
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: bufferAttributes)

        guard assetWriter.canAdd(input) else {
            throw NSError(domain: "GuideVideoRecorderTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "asset writer rejected the video input"])
        }
        assetWriter.add(input)
        super.init()
    }

    func start(completion: @escaping () -> Void) {
        self.completion = completion
        assetWriter.startWriting()
        assetWriter.startSession(atSourceTime: .zero)
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        if startTimestamp == nil { startTimestamp = link.timestamp }
        let elapsed = link.timestamp - (startTimestamp ?? link.timestamp)
        guard elapsed < duration else {
            finish()
            return
        }
        // Paces the display-refresh-rate callbacks down to `fps` — only append a
        // new frame once enough wall-clock time has passed for it.
        let expectedFrameCount = Int64(elapsed * Double(fps))
        guard expectedFrameCount > framesWritten, input.isReadyForMoreMediaData else { return }
        guard let pixelBuffer = renderPixelBuffer() else { return }
        let presentationTime = CMTime(value: framesWritten, timescale: fps)
        adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
        framesWritten += 1
    }

    private func renderPixelBuffer() -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var pixelBufferOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
        guard let pixelBuffer = pixelBufferOut else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        else { return nil }

        // `CALayer.render(in:)` draws into Core Graphics' native bottom-up
        // coordinate space, which is flipped relative to the top-down UIKit space
        // the layer tree is laid out in — without correcting for that, the capture
        // comes out upside down. Flip the context first so it lands right-side up.
        let target = view.layer.presentation() ?? view.layer
        context.saveGState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        target.render(in: context)
        context.restoreGState()
        return pixelBuffer
    }

    private func finish() {
        displayLink?.invalidate()
        displayLink = nil
        input.markAsFinished()
        assetWriter.finishWriting { [weak self] in
            DispatchQueue.main.async {
                self?.completion?()
            }
        }
    }
}

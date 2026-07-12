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
//    TEST_RUNNER_RECORD_GUIDE_VIDEOS=1 \
//    TEST_RUNNER_GUIDE_VIDEO_OUTPUT_DIR=/path/to/Luna/Resources \
//    xcodebuild test -scheme Luna -only-testing:LunaTests/GuideVideoRecorderTests ...
//

import AVFoundation
import CoreVideo
import LunaSocialUI
import UIKit
import XCTest

final class GuideVideoRecorderTests: XCTestCase {

    func testRecordSafariExtensionGuideReader() throws {
        try recordGuideVideo(kind: .safariExtension, appIcon: .reader,
                             style: .light, filename: guideFilename(base: "SafariExtensionGuide", appIcon: .reader, style: .light))
    }

    func testRecordSafariExtensionGuideDownloader() throws {
        try recordGuideVideo(kind: .safariExtension, appIcon: .downloader,
                             style: .light, filename: guideFilename(base: "SafariExtensionGuide", appIcon: .downloader, style: .light))
    }

    func testRecordSafariExtensionGuidePriceTracker() throws {
        try recordGuideVideo(kind: .safariExtension, appIcon: .priceTracker,
                             style: .light, filename: guideFilename(base: "SafariExtensionGuide", appIcon: .priceTracker, style: .light))
    }

    func testRecordActionButtonGuideReader() throws {
        try recordGuideVideo(kind: .actionButtonSettings, appIcon: .reader,
                             style: .light, filename: guideFilename(base: "ActionButtonGuide", appIcon: .reader, style: .light))
    }

    func testRecordActionButtonGuideDownloader() throws {
        try recordGuideVideo(kind: .actionButtonSettings, appIcon: .downloader,
                             style: .light, filename: guideFilename(base: "ActionButtonGuide", appIcon: .downloader, style: .light))
    }

    func testRecordActionButtonGuidePriceTracker() throws {
        try recordGuideVideo(kind: .actionButtonSettings, appIcon: .priceTracker,
                             style: .light, filename: guideFilename(base: "ActionButtonGuide", appIcon: .priceTracker, style: .light))
    }

    func testRecordSafariExtensionGuideReaderDark() throws {
        try recordGuideVideo(kind: .safariExtension, appIcon: .reader,
                             style: .dark, filename: guideFilename(base: "SafariExtensionGuide", appIcon: .reader, style: .dark))
    }

    func testRecordSafariExtensionGuideDownloaderDark() throws {
        try recordGuideVideo(kind: .safariExtension, appIcon: .downloader,
                             style: .dark, filename: guideFilename(base: "SafariExtensionGuide", appIcon: .downloader, style: .dark))
    }

    func testRecordSafariExtensionGuidePriceTrackerDark() throws {
        try recordGuideVideo(kind: .safariExtension, appIcon: .priceTracker,
                             style: .dark, filename: guideFilename(base: "SafariExtensionGuide", appIcon: .priceTracker, style: .dark))
    }

    func testRecordActionButtonGuideReaderDark() throws {
        try recordGuideVideo(kind: .actionButtonSettings, appIcon: .reader,
                             style: .dark, filename: guideFilename(base: "ActionButtonGuide", appIcon: .reader, style: .dark))
    }

    func testRecordActionButtonGuideDownloaderDark() throws {
        try recordGuideVideo(kind: .actionButtonSettings, appIcon: .downloader,
                             style: .dark, filename: guideFilename(base: "ActionButtonGuide", appIcon: .downloader, style: .dark))
    }

    func testRecordActionButtonGuidePriceTrackerDark() throws {
        try recordGuideVideo(kind: .actionButtonSettings, appIcon: .priceTracker,
                             style: .dark, filename: guideFilename(base: "ActionButtonGuide", appIcon: .priceTracker, style: .dark))
    }

    // MARK: - Recording

    private func guideFilename(
        base: String, appIcon: OnboardingAnimationView.AppIcon, style: UIUserInterfaceStyle
    ) -> String {
        base + appIcon.guideVideoSuffix + (style == .dark ? "Dark" : "Light")
    }

    /// The illustration's own fixed intrinsic size (`OnboardingAnimationView.init`'s
    /// per-kind `height`/`width`). The recorded clip is this at 2x (context-scaled).
    private func naturalSize(for kind: OnboardingAnimationView.Kind) -> CGSize {
        switch kind {
        case .safariExtension: return CGSize(width: 220, height: 360)
        case .actionButtonSettings: return CGSize(width: 220, height: 360)
        default: return CGSize(width: 260, height: 150)
        }
    }

    private func recordGuideVideo(
        kind: OnboardingAnimationView.Kind, appIcon: OnboardingAnimationView.AppIcon,
        style: UIUserInterfaceStyle,
        filename: String,
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
        // The recording window MUST belong to a UIWindowScene: a scene-less UIWindow
        // is never committed to the render server, its CAAnimations never advance, and
        // `presentation()` just mirrors the static model tree — the recorded "video"
        // comes out as one frozen frame repeated for the whole duration.
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else {
            XCTFail("No UIWindowScene available to host the recording window", file: file, line: line)
            return
        }

        let natural = naturalSize(for: kind)

        let animation = OnboardingAnimationView(kind: kind, appIcon: appIcon)
        animation.backgroundColor = .systemBackground

        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: natural)
        window.overrideUserInterfaceStyle = style
        window.backgroundColor = .systemBackground
        window.addSubview(animation)
        // The illustration carries its own fixed width/height constraints (== natural),
        // so centering it makes it exactly fill the window.
        NSLayoutConstraint.activate([
            animation.centerXAnchor.constraint(equalTo: window.centerXAnchor),
            animation.centerYAnchor.constraint(equalTo: window.centerYAnchor),
        ])
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        animation.start()

        // Wait out the animation's own one-time start-up delay so the recorded
        // clip begins right at the loop's clean seam.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        let outputURL = URL(fileURLWithPath: outputDir).appendingPathComponent("\(filename).mp4")
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // 2x of the illustration's even-dimension natural size — crisp at PiP size,
        // no letterboxing (H.264 needs even dimensions).
        let recorder = try FrameRecorder(
            view: window, naturalSize: natural, contentScale: 2,
            duration: kind.loopDuration, outputURL: outputURL)
        let expectation = expectation(description: "recorded \(filename)")
        recorder.start { expectation.fulfill() }
        wait(for: [expectation], timeout: kind.loopDuration + 15)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path),
                      "expected a recorded clip at \(outputURL.path)", file: file, line: line)
        XCTAssertGreaterThan(recorder.distinctFrameCount, 10,
                             "recorded clip looks static — the illustration's animations were not running",
                             file: file, line: line)
        window.isHidden = true
        window.windowScene = nil
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
/// not just its animation's static end state — provided the hosting window is
/// scene-attached (see the caller) so those animations actually run.
private final class FrameRecorder: NSObject {
    private let view: UIView
    private let pixelSize: CGSize
    private let contentScale: CGFloat
    private let duration: TimeInterval
    private let fps: Int32 = 30

    private let assetWriter: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor

    private var displayLink: CADisplayLink?
    private var startTimestamp: CFTimeInterval?
    private var framesWritten: Int64 = 0
    private var completion: (() -> Void)?

    /// Rough animation sanity signal: how many appended frames differed from the
    /// frame before them (byte-compared). A healthy clip has most frames distinct;
    /// a broken scene-less capture has ~0.
    private(set) var distinctFrameCount = 0
    private var previousFrameDigest: Int = 0

    init(view: UIView, naturalSize: CGSize, contentScale: CGFloat,
         duration: TimeInterval, outputURL: URL) throws {
        self.view = view
        self.pixelSize = CGSize(width: naturalSize.width * contentScale,
                                height: naturalSize.height * contentScale)
        self.contentScale = contentScale
        self.duration = duration

        try? FileManager.default.removeItem(at: outputURL)
        assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: 800_000,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel,
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(pixelSize.width),
            AVVideoHeightKey: Int(pixelSize.height),
            AVVideoCompressionPropertiesKey: compression,
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true

        let bufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: Int(pixelSize.width),
            kCVPixelBufferHeightKey as String: Int(pixelSize.height),
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
            width: Int(pixelSize.width), height: Int(pixelSize.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        else { return nil }

        // `CALayer.render(in:)` draws into Core Graphics' native bottom-up
        // coordinate space, which is flipped relative to the top-down UIKit space
        // the layer tree is laid out in — without correcting for that, the capture
        // comes out upside down. Flip the context (in output pixels) and scale the
        // natural-size layer tree up to the output size in the same step.
        let target = view.layer.presentation() ?? view.layer
        context.saveGState()
        context.translateBy(x: 0, y: pixelSize.height)
        context.scaleBy(x: contentScale, y: -contentScale)
        target.render(in: context)
        context.restoreGState()

        trackDistinctFrame(pixelBuffer)
        return pixelBuffer
    }

    private func trackDistinctFrame(_ pixelBuffer: CVPixelBuffer) {
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let length = CVPixelBufferGetDataSize(pixelBuffer)
        var hasher = Hasher()
        hasher.combine(bytes: UnsafeRawBufferPointer(start: base, count: length))
        let digest = hasher.finalize()
        if digest != previousFrameDigest, framesWritten > 0 { distinctFrameCount += 1 }
        previousFrameDigest = digest
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

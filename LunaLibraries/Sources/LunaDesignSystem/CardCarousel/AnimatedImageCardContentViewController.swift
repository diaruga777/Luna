//
//  AnimatedImageCardContentViewController.swift
//  LunaDesignSystem
//
//  Time-based card content for animated GIFs. Frames are decoded once through
//  ImageIO (downsampled to a display-appropriate size) and driven by a
//  CADisplayLink, which — unlike UIImage.animatedImage — lets the carousel
//  scrub to an arbitrary timestamp and pause on a specific frame.
//

import ImageIO
import UIKit

public final class AnimatedImageCardContentViewController: CardContentViewController {

    /// Longest edge, in pixels, frames are downsampled to. GIFs are small; this
    /// bounds pathological ones without visibly softening the common case.
    private static let maximumFramePixelSize: CGFloat = 1400
    /// ImageIO reports 0 for missing delays; browsers clamp tiny ones up.
    private static let minimumFrameDelay: TimeInterval = 0.02

    private struct Frame {
        let image: UIImage
        let startTime: TimeInterval
        let duration: TimeInterval
    }

    private let fileURL: URL
    private let imageView = UIImageView()
    private var frames: [Frame] = []
    private var totalDuration: TimeInterval = 0
    private var elapsed: TimeInterval = 0
    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var wantsPlaying = false

    public init(fileURL: URL) {
        self.fileURL = fileURL
        super.init()
    }

    deinit {
        displayLink?.invalidate()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        imageView.frame = view.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(imageView)

        let url = fileURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let loaded = Self.loadFrames(from: url)
            DispatchQueue.main.async {
                guard let self else { return }
                self.frames = loaded
                self.totalDuration = loaded.last.map { $0.startTime + $0.duration } ?? 0
                self.imageView.image = loaded.first?.image
                if self.wantsPlaying { self.startDisplayLink() }
            }
        }
    }

    private static func loadFrames(from url: URL) -> [Frame] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return [] }
        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumFramePixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        var frames: [Frame] = []
        var start: TimeInterval = 0
        for index in 0..<count {
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source, index, downsampleOptions as CFDictionary)
            else { continue }
            let delay = frameDelay(source: source, index: index)
            frames.append(Frame(
                image: UIImage(cgImage: cgImage),
                startTime: start,
                duration: delay))
            start += delay
        }
        return frames
    }

    private static func frameDelay(source: CGImageSource, index: Int) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                as? [String: Any],
              let gif = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any]
        else { return 0.1 }
        let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? TimeInterval
        let clamped = gif[kCGImagePropertyGIFDelayTime as String] as? TimeInterval
        let delay = (unclamped ?? clamped) ?? 0.1
        return max(delay > 0 ? delay : (clamped ?? 0.1), Self.minimumFrameDelay)
    }

    // MARK: - Playback clock

    private func startDisplayLink() {
        guard displayLink == nil, !frames.isEmpty else { return }
        lastTick = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard totalDuration > 0 else { return }
        let now = CACurrentMediaTime()
        elapsed += now - lastTick
        lastTick = now
        elapsed = elapsed.truncatingRemainder(dividingBy: totalDuration)
        showFrame(at: elapsed)
    }

    private func showFrame(at time: TimeInterval) {
        // Frames are in start-time order; a short linear scan beats bookkeeping
        // for the frame counts real GIFs have.
        guard let frame = frames.last(where: { $0.startTime <= time }) ?? frames.first
        else { return }
        if imageView.image !== frame.image {
            imageView.image = frame.image
        }
    }

    // MARK: - CardContentViewController

    public override var isPlayable: Bool { true }

    public override var isPlaying: Bool { wantsPlaying }

    public override var playbackFraction: Double {
        guard totalDuration > 0 else { return 0 }
        return min(max(elapsed / totalDuration, 0), 1)
    }

    public override func setPlaying(_ playing: Bool) {
        wantsPlaying = playing
        if playing { startDisplayLink() } else { stopDisplayLink() }
    }

    public override func seek(toFraction fraction: Double) {
        guard totalDuration > 0 else { return }
        let clamped = min(max(fraction, 0), 1)
        elapsed = clamped * totalDuration
        lastTick = CACurrentMediaTime()
        showFrame(at: elapsed)
    }
}

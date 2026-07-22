//
//  AnimatedArticleImageView.swift
//  LunaReaderUI
//

import ImageIO
import UIKit

/// A lightweight offline GIF/APNG presenter. ImageIO advances one frame at a time,
/// avoiding the large decoded-frame array created by `UIImage.animatedImage` for
/// long article animations. The scroll reader only enables playback while this view
/// intersects the visible viewport.
final class AnimatedArticleImageView: UIImageView {
    let fileURL: URL
    let attachmentRange: NSRange

    private var playbackEnabled = false
    private var isImageIOAnimating = false
    private var playbackGeneration = 0

    init(fileURL: URL, attachmentRange: NSRange) {
        self.fileURL = fileURL
        self.attachmentRange = attachmentRange
        super.init(frame: .zero)
        contentMode = .scaleAspectFit
        clipsToBounds = true
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func canAnimate(_ fileURL: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    func setPlaybackEnabled(_ enabled: Bool) {
        guard playbackEnabled != enabled else { return }
        playbackEnabled = enabled
        if enabled {
            startIfPossible()
        } else {
            stopAtNextFrame()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopAtNextFrame()
        } else if playbackEnabled {
            startIfPossible()
        }
    }

    private func startIfPossible() {
        guard playbackEnabled, window != nil, !isImageIOAnimating else { return }
        playbackGeneration += 1
        let generation = playbackGeneration
        isImageIOAnimating = true
        let status = CGAnimateImageAtURLWithBlock(fileURL as CFURL, nil) {
            [weak self] _, frame, stop in
            guard let self,
                  self.playbackEnabled,
                  self.window != nil,
                  self.playbackGeneration == generation
            else {
                stop.pointee = true
                if self?.playbackGeneration == generation {
                    self?.isImageIOAnimating = false
                }
                return
            }
            self.image = UIImage(cgImage: frame)
        }
        if status != noErr { isImageIOAnimating = false }
    }

    private func stopAtNextFrame() {
        guard isImageIOAnimating else { return }
        playbackGeneration += 1
        isImageIOAnimating = false
    }
}

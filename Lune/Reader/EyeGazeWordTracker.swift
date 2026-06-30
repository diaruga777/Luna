//
//  EyeGazeWordTracker.swift
//  Lune
//

import LuneReaderUI
import LuneReaderEngine
import ARKit
import UIKit

/// Best-effort gaze tracking while reading: estimates which word the user is
/// looking at via the TrueDepth camera (ARKit face tracking) so audio/RSVP can
/// start where the eyes left off.
///
/// The estimate moves with a strong forward bias — small forward steps when
/// the gaze tracks ahead, and a large jump (forward or back) only when the
/// gaze lingers steadily in a new region. Unsupported devices (and the
/// simulator) get a nil tracker.
final class EyeGazeWordTracker: NSObject {

    static var isSupported: Bool { ARFaceTrackingConfiguration.isSupported }

    /// Current best estimate of the last word read, in the shared word-index
    /// space. Notifies `onWordIndexChange` (on main) whenever it changes.
    private(set) var estimatedWordIndex: Int? {
        didSet {
            guard let index = estimatedWordIndex, index != oldValue else { return }
            onWordIndexChange?(index)
        }
    }

    /// Live callback for the "highlight the looked-at word" affordance.
    var onWordIndexChange: ((Int) -> Void)?

    private let session = ARSession()
    private weak var textView: UITextView?
    private let wordMap: WordMap

    /// Vertical screen points per meter of lookAtPoint deflection (rough,
    /// uncalibrated; vertical reading position is all we need).
    private let gazeScale: CGFloat = 1800

    /// Candidate region for the linger-jump rule.
    private var lingerCandidate: Int?
    private var lingerSamples = 0
    private let lingerSamplesNeeded = 12

    init?(textView: UITextView, wordMap: WordMap, seedWordIndex: Int? = nil) {
        guard Self.isSupported else { return nil }
        self.textView = textView
        self.wordMap = wordMap
        self.estimatedWordIndex = seedWordIndex
        super.init()
        session.delegate = self
        let configuration = ARFaceTrackingConfiguration()
        configuration.isWorldTrackingEnabled = false
        session.run(configuration)
    }

    func stop() {
        session.pause()
    }
}

extension EyeGazeWordTracker: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let face = anchors.compactMap({ $0 as? ARFaceAnchor }).first,
              face.isTracked else { return }
        let lookAt = face.lookAtPoint

        DispatchQueue.main.async { [weak self] in
            self?.ingestGaze(lookAtY: CGFloat(lookAt.y))
        }
    }

    private func ingestGaze(lookAtY: CGFloat) {
        guard let textView, let window = textView.window else { return }
        let screenHeight = window.bounds.height
        // lookAtPoint.y is positive looking up; map to a screen y around center.
        let gazeScreenY = min(max(screenHeight / 2 - lookAtY * gazeScale, 0), screenHeight)

        let pointInText = CGPoint(
            x: textView.bounds.width / 2,
            y: gazeScreenY + textView.contentOffset.y)
        let characterIndex = textView.layoutManager.characterIndex(
            for: pointInText, in: textView.textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil)
        guard let candidate = wordMap.wordIndex(nearCharacterIndex: characterIndex) else { return }

        guard let current = estimatedWordIndex else {
            estimatedWordIndex = candidate
            return
        }

        if candidate >= current - 5, candidate <= current + 15 {
            // Smooth forward drift: never regress, never leap on a glance.
            estimatedWordIndex = max(current, min(candidate, current + 3))
            lingerCandidate = nil
            lingerSamples = 0
        } else {
            // A far-away gaze only wins if it lingers steadily in one region.
            if let linger = lingerCandidate, abs(candidate - linger) <= 10 {
                lingerSamples += 1
                if lingerSamples >= lingerSamplesNeeded {
                    estimatedWordIndex = candidate
                    lingerCandidate = nil
                    lingerSamples = 0
                }
            } else {
                lingerCandidate = candidate
                lingerSamples = 1
            }
        }
    }
}

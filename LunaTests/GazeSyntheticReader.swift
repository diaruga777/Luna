//
//  GazeSyntheticReader.swift
//  LunaTests
//
//  A synthetic user in front of a device, ported from gazeread's `sim.mjs`.
//
//  The point of the simulation is that the pipeline is fed a signal it does NOT
//  know how to produce: a metric gaze ray from a real eye position, distorted by
//  a per-user angular offset and gain that the estimator has no model of, plus
//  landmark noise. Calibration sees that user with a still head; the checks then
//  move the head and ask whether the prediction is still inside a sentence band.
//

import CoreGraphics
import Foundation
import simd
@testable import LunaGaze
import LunaWriterModels

/// Where the head is, in camera space (metres, user at negative z).
struct SimHeadPose {
    var eye: SIMD3<Double>
    var yaw: Double
    var pitch: Double

    func moved(x: Double = 0, y: Double = 0, z: Double = 0) -> SimHeadPose {
        var copy = self
        copy.eye += SIMD3(x, y, z)
        return copy
    }

    func turned(yaw yawDelta: Double = 0, pitch pitchDelta: Double = 0) -> SimHeadPose {
        var copy = self
        copy.yaw += yawDelta
        copy.pitch += pitchDelta
        return copy
    }
}

/// The distortion the estimator does not know about: the optical axis is not
/// the visual axis (kappa), and the reported angle is scaled slightly wrong.
struct SimEyeModel {
    /// Angular offset between the optical and visual axes, in radians.
    var kappaAzimuth: Double = 0.045
    var kappaElevation: Double = -0.030
    /// Scale error on the reported angle.
    var gainAzimuth: Double = 1.08
    var gainElevation: Double = 0.90
    /// Frame-to-frame noise on the reported angle, in radians.
    var angleNoise: Double = 0.006
    /// Frame-to-frame noise on the landmark signal the saccade filter reads.
    var unitsNoise: Double = 0.001
}

/// One frame the synthetic user produces.
struct SimFrame {
    /// The uncalibrated screen estimate, in points.
    let raw: CGPoint
    /// Eye-in-head direction in iris units, for saccade detection.
    let eyeUnits: CGPoint
}

/// A user looking at a device.
final class SimUser {

    let screenSize: CGSize
    let pointsPerMetre: Double
    let cameraHeightAboveScreen: Double
    var pose: SimHeadPose
    var model: SimEyeModel
    var random: SimRandom

    init(
        screenSize: CGSize,
        pointsPerMetre: Double,
        cameraHeightAboveScreen: Double = 0.006,
        pose: SimHeadPose,
        model: SimEyeModel = SimEyeModel(),
        random: SimRandom = SimRandom()
    ) {
        self.screenSize = screenSize
        self.pointsPerMetre = pointsPerMetre
        self.cameraHeightAboveScreen = cameraHeightAboveScreen
        self.pose = pose
        self.model = model
        self.random = random
    }

    /// Camera-space position of a point on the display.
    func cameraPoint(of screen: CGPoint) -> SIMD3<Double> {
        SIMD3(
            (Double(screenSize.width) / 2 - Double(screen.x)) / pointsPerMetre,
            -(Double(screen.y) / pointsPerMetre) - cameraHeightAboveScreen,
            0)
    }

    /// Where the display's plane is hit by a ray from the eye.
    func screenPoint(eye: SIMD3<Double>, direction: SIMD3<Double>) -> CGPoint? {
        guard direction.z > 1e-9 else { return nil }
        let along = -eye.z / direction.z
        guard along > 0, along.isFinite else { return nil }
        let hit = eye + direction * along
        return CGPoint(
            x: Double(screenSize.width) / 2 - hit.x * pointsPerMetre,
            y: (-hit.y - cameraHeightAboveScreen) * pointsPerMetre)
    }

    /// The estimate produced while the user looks at `target`.
    func frame(lookingAt target: CGPoint, noise: Bool = true, pose: SimHeadPose? = nil) -> SimFrame? {
        let head = pose ?? self.pose
        let hit = cameraPoint(of: target)
        var gaze = hit - head.eye
        let length = (gaze * gaze).sum().squareRoot()
        guard length > 1e-9 else { return nil }
        gaze /= length

        let rotation = Self.rotation(yaw: head.yaw, pitch: head.pitch)
        let inHead = Self.applyTranspose(rotation, gaze)
        var azimuth = atan2(inHead.x, inHead.z)
        var elevation = atan2(inHead.y, inHead.z)

        azimuth = model.gainAzimuth * azimuth + model.kappaAzimuth
        elevation = model.gainElevation * elevation + model.kappaElevation
        if noise {
            azimuth += random.gaussian(model.angleNoise)
            elevation += random.gaussian(model.angleNoise)
        }

        var reported = SIMD3(tan(azimuth), tan(elevation), 1)
        reported /= (reported * reported).sum().squareRoot()
        let inCamera = Self.apply(rotation, reported)
        guard let point = screenPoint(eye: head.eye, direction: inCamera) else { return nil }
        var units = CGPoint(x: -0.40 * tan(azimuth), y: -0.34 * tan(elevation))
        if noise {
            units.x += random.gaussian(model.unitsNoise)
            units.y += random.gaussian(model.unitsNoise)
        }
        return SimFrame(raw: point, eyeUnits: units)
    }

    /// `Ry(yaw) · Rx(pitch)`, by rows. Head forward is `R · (0, 0, 1)`.
    static func rotation(yaw: Double, pitch: Double) -> [SIMD3<Double>] {
        let cy = cos(yaw), sy = sin(yaw), cp = cos(pitch), sp = sin(pitch)
        return [
            SIMD3(cy, sy * sp, sy * cp),
            SIMD3(0, cp, -sp),
            SIMD3(-sy, cy * sp, cy * cp),
        ]
    }

    static func apply(_ rows: [SIMD3<Double>], _ vector: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(
            (rows[0] * vector).sum(),
            (rows[1] * vector).sum(),
            (rows[2] * vector).sum())
    }

    static func applyTranspose(_ rows: [SIMD3<Double>], _ vector: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(
            rows[0].x * vector.x + rows[1].x * vector.y + rows[2].x * vector.z,
            rows[0].y * vector.x + rows[1].y * vector.y + rows[2].y * vector.z,
            rows[0].z * vector.x + rows[1].z * vector.y + rows[2].z * vector.z)
    }
}

/// Runs a calibration sweep against a synthetic user and fits the model.
enum SimCalibration {

    /// Camera latency plus the eye's pursuit lag. The fit has to find this
    /// without being told.
    static let trueLag: TimeInterval = 0.14

    static func run(
        user: SimUser,
        pointsPerDegree: CGFloat,
        frameRate: Double = 60,
        path: PursuitCalibrationPath? = nil
    ) -> (calibration: GazeAffineCalibration?, collector: CalibrationSampleCollector) {
        let bounds = CGRect(origin: .zero, size: user.screenSize)
        let sweep = path ?? PursuitCalibrationPath.full(in: bounds)
        let collector = CalibrationSampleCollector(path: sweep, startTime: 0)
        let step = 1 / frameRate
        var time: TimeInterval = 0
        while time <= sweep.duration + 0.2 {
            // The eye is where the dot WAS: the frame is late by the lag.
            let dot = sweep.sample(at: time - trueLag)
            if let frame = user.frame(lookingAt: dot.point) {
                collector.ingest(
                    CalibrationFrame(
                        time: time, raw: frame.raw, eyeUnits: frame.eyeUnits,
                        blink: 0, isFaceTracked: true))
            }
            time += step
        }
        var options = GazeAffineCalibration.FitOptions()
        options.pointsPerDegree = pointsPerDegree
        return (collector.fit(viewSize: user.screenSize, options: options), collector)
    }

    /// Mean, mean-vertical and worst error of a calibration over a grid, with
    /// the head in `pose`. Each point averages a second of frames, as the
    /// one-euro and fixation filters do while reading.
    static func evaluate(
        _ calibration: GazeAffineCalibration,
        user: SimUser,
        pose: SimHeadPose,
        framesPerPoint: Int = 30
    ) -> (mean: CGFloat, meanY: CGFloat, worst: CGFloat) {
        let fractions: [(CGFloat, CGFloat)] = [
            (0.15, 0.2), (0.5, 0.2), (0.85, 0.2),
            (0.15, 0.5), (0.5, 0.5), (0.85, 0.5),
            (0.15, 0.8), (0.5, 0.8), (0.85, 0.8),
        ]
        var total: CGFloat = 0
        var totalY: CGFloat = 0
        var worst: CGFloat = 0
        for (fx, fy) in fractions {
            let target = CGPoint(x: fx * user.screenSize.width, y: fy * user.screenSize.height)
            var sum = CGPoint.zero
            var count = 0
            for _ in 0..<framesPerPoint {
                guard let frame = user.frame(lookingAt: target, pose: pose) else { continue }
                let corrected = calibration.point(from: frame.raw)
                sum.x += corrected.x
                sum.y += corrected.y
                count += 1
            }
            guard count > 0 else { continue }
            let mean = CGPoint(x: sum.x / CGFloat(count), y: sum.y / CGFloat(count))
            let dx = mean.x - target.x
            let dy = mean.y - target.y
            let error = (dx * dx + dy * dy).squareRoot()
            total += error
            totalY += abs(dy)
            worst = max(worst, error)
        }
        let count = CGFloat(fractions.count)
        return (total / count, totalY / count, worst)
    }
}

/// A page of sentences laid out on a grid, in text-container coordinates.
enum SimPage {

    static func make(
        wordCounts: [Int],
        origin: CGPoint = CGPoint(x: 20, y: 40),
        columnWidth: CGFloat = 353,
        lineHeight: CGFloat = 26,
        wordWidth: CGFloat = 46,
        spacing: CGFloat = 6
    ) -> [SentenceLayout] {
        var sentences: [SentenceLayout] = []
        var pen = origin
        var location = 0
        for (index, count) in wordCounts.enumerated() {
            var words: [WordLayout] = []
            var lines: [CGRect] = []
            var lineStartX = pen.x
            let sentenceStart = location
            for _ in 0..<count {
                if pen.x + wordWidth > origin.x + columnWidth {
                    lines.append(CGRect(
                        x: lineStartX, y: pen.y, width: pen.x - spacing - lineStartX,
                        height: lineHeight))
                    pen = CGPoint(x: origin.x, y: pen.y + lineHeight)
                    lineStartX = pen.x
                }
                let rect = CGRect(x: pen.x, y: pen.y, width: wordWidth, height: lineHeight)
                words.append(WordLayout(textRange: NSRange(location: location, length: 5), rect: rect))
                location += 6
                pen.x += wordWidth + spacing
            }
            lines.append(CGRect(
                x: lineStartX, y: pen.y, width: max(pen.x - spacing - lineStartX, wordWidth),
                height: lineHeight))
            sentences.append(SentenceLayout(
                index: index,
                textRange: NSRange(location: sentenceStart, length: location - sentenceStart),
                lineRects: lines,
                words: words))
            pen.x += spacing * 2
            if pen.x + wordWidth > origin.x + columnWidth {
                pen = CGPoint(x: origin.x, y: pen.y + lineHeight)
            }
        }
        return sentences
    }

    /// The word the reader is on at `time`, reading at `wordsPerMinute`.
    static func position(
        in sentences: [SentenceLayout], at time: TimeInterval, wordsPerMinute: Double
    ) -> (sentence: Int, word: Int)? {
        let elapsed = time * wordsPerMinute / 60
        var remaining = elapsed
        for sentence in sentences {
            let count = Double(sentence.wordCount)
            if remaining < count {
                return (sentence.index, min(Int(remaining), sentence.wordCount - 1))
            }
            remaining -= count
        }
        return nil
    }
}

extension SimPage {

    /// Sentences on their own line, spaced far enough apart that the gaze
    /// alone can pick one out. Prose does not look like this; a test of the
    /// switch machinery needs it, because in real prose consecutive sentences
    /// share a line and only the transition prior separates them.
    static func spaced(
        count: Int = 3, words: Int = 12, spacing: CGFloat = 240, lineHeight: CGFloat = 34
    ) -> [SentenceLayout] {
        (0..<count).map { index in
            let y = 100 + CGFloat(index) * spacing
            let laid = (0..<words).map { word in
                WordLayout(
                    textRange: NSRange(location: index * 200 + word * 6, length: 5),
                    rect: CGRect(x: 20 + CGFloat(word) * 30, y: y, width: 26, height: lineHeight))
            }
            return SentenceLayout(
                index: index,
                textRange: NSRange(location: index * 200, length: words * 6),
                lineRects: [CGRect(x: 20, y: y, width: CGFloat(words) * 30, height: lineHeight)],
                words: laid)
        }
    }
}

/// How well the tracker followed a reader through a whole page.
struct SimReadingResult {
    /// Frames scored, after the warm-up and outside the grace window that
    /// follows a true sentence change.
    var scored = 0
    /// Frames where the tracked sentence was the sentence being read.
    var exact = 0
    /// Frames where the tracked sentence was within one of it.
    var withinOne = 0
    /// Smallest and largest signed distance from the truth.
    var minimumLead = 0
    var maximumLead = 0
    /// Mean vertical distance from the calibrated gaze to the word being read.
    var meanBandError: CGFloat = 0
    var finalMode: ReadingState.Mode = .auto

    var exactFraction: Double { Double(exact) / Double(max(scored, 1)) }
    var withinOneFraction: Double { Double(withinOne) / Double(max(scored, 1)) }
}

/// Reads a whole page through the real pipeline: synthetic eye → calibration →
/// one-euro → fixation filter → gate → tracker.
enum SimReadingRun {

    static func run(
        page: [SentenceLayout],
        user: SimUser,
        pose: SimHeadPose,
        calibration: GazeAffineCalibration,
        pointsPerDegree: CGFloat,
        wordsPerMinute: Double = 240,
        frameRate: Double = 60,
        warmUp: TimeInterval = 1.0,
        grace: TimeInterval = 0.7
    ) -> SimReadingResult {
        let tracker = ReadingTracker(pointsPerDegree: pointsPerDegree)
        tracker.setLayout(page)
        var euro = OneEuroFilter()
        let fixations = FixationDetector(pointsPerDegree: pointsPerDegree)
        var gate = GazeGate(screenSize: user.screenSize, pointsPerDegree: pointsPerDegree)

        var result = SimReadingResult()
        var bandErrorTotal: CGFloat = 0
        var bandErrorCount = 0
        var previousTruth = 0
        var lastTruthChange: TimeInterval = 0
        var time: TimeInterval = 0
        let step = 1 / frameRate

        while let truth = SimPage.position(in: page, at: time, wordsPerMinute: wordsPerMinute) {
            if truth.sentence != previousTruth {
                lastTruthChange = time
                previousTruth = truth.sentence
            }
            let word = page[truth.sentence].words[truth.word].rect
            let target = CGPoint(x: word.midX, y: word.midY)
            var gaze: CGPoint?
            if let frame = user.frame(lookingAt: target, pose: pose) {
                let corrected = calibration.point(from: frame.raw)
                let smoothed = euro.filter(corrected, at: time)
                fixations.ingest(smoothed, at: time)
                gate.update(
                    faceTracked: true, blinkLeft: 0, blinkRight: 0, point: smoothed, at: time)
                gaze = gate.isOpen ? fixations.fixation?.point : nil
                bandErrorTotal += abs(smoothed.y - target.y)
                bandErrorCount += 1
            }
            tracker.ingest(gaze: gaze, gate: gate.reason, at: time)
            let state = tracker.tick(at: time)

            if time > warmUp, time - lastTruthChange > grace, let active = state.activeSentence {
                result.scored += 1
                let lead = active - truth.sentence
                if lead == 0 { result.exact += 1 }
                if abs(lead) <= 1 { result.withinOne += 1 }
                result.minimumLead = min(result.minimumLead, lead)
                result.maximumLead = max(result.maximumLead, lead)
            }
            time += step
        }
        result.meanBandError = bandErrorTotal / CGFloat(max(bandErrorCount, 1))
        result.finalMode = tracker.state.mode
        return result
    }
}

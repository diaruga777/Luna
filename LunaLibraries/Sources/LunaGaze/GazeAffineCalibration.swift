//
//  GazeAffineCalibration.swift
//  LunaGaze
//

import CoreGraphics
import Foundation

/// One corner of the display. Calibration is scored per quadrant because the
/// estimator's error is not uniform: a fit can be excellent in the middle and
/// poor at one corner, and only the corner is worth a touch-up.
public enum GazeScreenQuadrant: String, Codable, CaseIterable, Equatable {
    case topLeft, topRight, bottomLeft, bottomRight

    /// The quadrant a point in `size` falls in.
    public static func containing(_ point: CGPoint, in size: CGSize) -> GazeScreenQuadrant {
        let left = point.x < size.width / 2
        let top = point.y < size.height / 2
        switch (left, top) {
        case (true, true): return .topLeft
        case (false, true): return .topRight
        case (true, false): return .bottomLeft
        case (false, false): return .bottomRight
        }
    }

    /// Centre of the quadrant, as a fraction of the display.
    public var unitCentre: CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: 0.22, y: 0.24)
        case .topRight: return CGPoint(x: 0.78, y: 0.24)
        case .bottomLeft: return CGPoint(x: 0.22, y: 0.76)
        case .bottomRight: return CGPoint(x: 0.78, y: 0.76)
        }
    }
}

/// One (raw estimate, known target) pair gathered during calibration.
public struct CalibrationSample: Equatable {
    /// The uncalibrated estimate, in screen points.
    public let raw: CGPoint
    /// Where the reader was in fact looking, in screen points.
    public let target: CGPoint
    /// When the estimate was made, in seconds.
    public let time: TimeInterval

    public init(raw: CGPoint, target: CGPoint, time: TimeInterval = 0) {
        self.raw = raw
        self.target = target
        self.time = time
    }
}

/// How good a calibration turned out to be.
public struct CalibrationVerdict: Codable, Equatable {

    public enum Grade: String, Codable, Equatable {
        /// Under 1.2°: good enough to follow words.
        case good
        /// Under 2.2°: good enough to follow sentences.
        case usable
        /// Worse: sentence tracking will be shaky.
        case rough
    }

    /// The quadrant that fitted worst, and by how much.
    public struct QuadrantError: Codable, Equatable {
        public let quadrant: GazeScreenQuadrant
        public let error: CGFloat

        public init(quadrant: GazeScreenQuadrant, error: CGFloat) {
            self.quadrant = quadrant
            self.error = error
        }
    }

    /// Mean error across the validated quadrants, in points.
    public let meanError: CGFloat
    /// The weakest quadrant.
    public let worstQuadrant: QuadrantError
    /// `meanError` expressed as visual angle.
    public let degrees: CGFloat
    /// The band `degrees` falls in.
    public let grade: Grade

    public init(meanError: CGFloat, worstQuadrant: QuadrantError, degrees: CGFloat, grade: Grade) {
        self.meanError = meanError
        self.worstQuadrant = worstQuadrant
        self.degrees = degrees
        self.grade = grade
    }

    public static func grade(forDegrees degrees: CGFloat) -> Grade {
        degrees < 1.2 ? .good : (degrees < 2.2 ? .usable : .rough)
    }
}

/// Maps ARKit's raw screen estimate onto where the reader is really looking.
///
/// ARKit's `lookAtPoint` is metric, so what remains after projection is a
/// slowly varying, per-user, per-posture distortion: a gain on each axis, a
/// small shear, and a bias. A 2×2 matrix with a bias covers exactly that, and
/// nothing more — a richer model fitted to one sweep would learn the sweep's
/// noise instead.
///
/// The fit is a ridge regression toward the IDENTITY rather than toward zero.
/// An axis the sweep barely exercised keeps its physical, uncalibrated
/// behaviour instead of collapsing to a constant, which is what shrinking a
/// low-variance feature toward zero would do.
public struct GazeAffineCalibration: Codable, Equatable {

    /// Lags, in seconds, the fit searches over: camera latency plus the eye's
    /// own pursuit lag. The one that fits best is the one that was true.
    public static let lagCandidates: [TimeInterval] = [0.06, 0.10, 0.14, 0.18, 0.22, 0.26]

    /// Largest online bias nudge allowed on either axis, in points. Beyond
    /// this the fit itself is wrong and a nudge only hides it.
    public static let maximumOffset: CGFloat = 220

    public struct FitOptions: Equatable {
        /// Ridge penalty on the matrix, pulling it toward the identity.
        public var lambdaMatrix: Double
        /// Ridge penalty on the bias. Zero: the bias is what the sweep is for.
        public var lambdaBias: Double
        /// Residual cut, in multiples of the scaled median absolute deviation.
        public var outlierMultiple: CGFloat
        /// Floor under the deviation, in points, so a near-perfect first pass
        /// does not discard honest samples.
        public var deviationFloor: CGFloat
        /// Fewest samples a fit will accept.
        public var minimumSamples: Int
        /// Points per degree, for grading a validation.
        public var pointsPerDegree: CGFloat

        public init(
            lambdaMatrix: Double = 0.5,
            lambdaBias: Double = 0,
            outlierMultiple: CGFloat = 2.5,
            deviationFloor: CGFloat = 4,
            minimumSamples: Int = 40,
            pointsPerDegree: CGFloat = 44
        ) {
            self.lambdaMatrix = lambdaMatrix
            self.lambdaBias = lambdaBias
            self.outlierMultiple = outlierMultiple
            self.deviationFloor = deviationFloor
            self.minimumSamples = minimumSamples
            self.pointsPerDegree = pointsPerDegree
        }
    }

    private var m00: CGFloat
    private var m01: CGFloat
    private var m10: CGFloat
    private var m11: CGFloat
    private var bx: CGFloat
    private var by: CGFloat
    private var offsetX: CGFloat
    private var offsetY: CGFloat

    /// Root-mean-square residual of the fit on its own samples, in points.
    public private(set) var fitRMS: CGFloat
    /// Samples the fit saw before the outlier pass.
    public private(set) var sampleCount: Int
    /// Samples the second pass kept.
    public private(set) var keptSampleCount: Int
    /// The lag the fit chose.
    public private(set) var lag: TimeInterval
    /// The view the fit was made against. A view this size again is a view the
    /// calibration still applies to.
    public private(set) var referenceViewSize: CGSize
    /// Points per degree at the fit's assumed reading distance.
    public private(set) var pointsPerDegree: CGFloat
    /// The last validation, once one has been recorded.
    public private(set) var verdict: CalibrationVerdict?

    /// `screen = A · raw + b`.
    public var transform: CGAffineTransform {
        CGAffineTransform(a: m00, b: m10, c: m01, d: m11, tx: bx, ty: by)
    }

    /// The online bias nudge, added after the transform.
    public var offset: CGVector {
        CGVector(dx: offsetX, dy: offsetY)
    }

    /// The identity: a calibration that changes nothing.
    public static func identity(
        viewSize: CGSize, pointsPerDegree: CGFloat = 44
    ) -> GazeAffineCalibration {
        GazeAffineCalibration(
            m00: 1, m01: 0, m10: 0, m11: 1, bx: 0, by: 0,
            fitRMS: 0, sampleCount: 0, keptSampleCount: 0, lag: 0,
            referenceViewSize: viewSize, pointsPerDegree: pointsPerDegree)
    }

    private init(
        m00: CGFloat, m01: CGFloat, m10: CGFloat, m11: CGFloat, bx: CGFloat, by: CGFloat,
        fitRMS: CGFloat, sampleCount: Int, keptSampleCount: Int, lag: TimeInterval,
        referenceViewSize: CGSize, pointsPerDegree: CGFloat
    ) {
        self.m00 = m00
        self.m01 = m01
        self.m10 = m10
        self.m11 = m11
        self.bx = bx
        self.by = by
        self.offsetX = 0
        self.offsetY = 0
        self.fitRMS = fitRMS
        self.sampleCount = sampleCount
        self.keptSampleCount = keptSampleCount
        self.lag = lag
        self.referenceViewSize = referenceViewSize
        self.pointsPerDegree = pointsPerDegree
    }

    // MARK: - Applying

    /// Corrects one raw estimate. A non-finite `raw` (a projection gone wrong
    /// upstream) passes through unchanged rather than turning the whole
    /// affine map into NaN.
    public func point(from raw: CGPoint) -> CGPoint {
        guard raw.x.isFinite, raw.y.isFinite else { return raw }
        let mapped = raw.applying(transform)
        return CGPoint(x: mapped.x + offsetX, y: mapped.y + offsetY)
    }

    /// Which axes a nudge may move.
    public enum NudgeAxes: Equatable { case both, verticalOnly }

    /// Moves the bias a fraction of the way along `error`, the vector from the
    /// current estimate to where the reader was in fact looking.
    ///
    /// Bias only, and clamped: an online signal is good enough to say "you are
    /// a line low", never good enough to re-derive the gains.
    public mutating func nudge(toward error: CGVector, gain: CGFloat, axes: NudgeAxes = .both) {
        let limit = Self.maximumOffset
        if axes != .verticalOnly {
            offsetX = min(max(offsetX + gain * error.dx, -limit), limit)
        }
        offsetY = min(max(offsetY + gain * error.dy, -limit), limit)
    }

    /// Drops the online nudge, keeping the fit.
    public mutating func resetOffset() {
        offsetX = 0
        offsetY = 0
    }

    // MARK: - Fitting

    /// Fits one lag's worth of pairs.
    public static func fit(
        samples rawSamples: [CalibrationSample],
        viewSize: CGSize,
        lag: TimeInterval = 0,
        options: FitOptions = FitOptions()
    ) -> GazeAffineCalibration? {
        // A blink or a saccade the collector's own filters missed can still
        // leave a non-finite raw estimate in the buffer (an upstream
        // projection that found no ray/plane intersection, say). One such
        // sample would otherwise carry a NaN into the whole normal-equations
        // solve, failing every axis rather than just the bad row.
        let samples = rawSamples.filter {
            $0.raw.x.isFinite && $0.raw.y.isFinite && $0.target.x.isFinite && $0.target.y.isFinite
        }
        guard samples.count >= options.minimumSamples,
              viewSize.width > 0, viewSize.height > 0
        else { return nil }

        // The design is in points, as the targets are: the ridge penalty is
        // then negligible against a sweep that covered the display, and bites
        // only on an axis the sweep barely moved along — which is the one case
        // the identity prior exists for.
        let rows = samples.map { [Double($0.raw.x), Double($0.raw.y), 1] }
        let targets = samples.map { (x: Double($0.target.x), y: Double($0.target.y)) }
        let penalties = [options.lambdaMatrix, options.lambdaMatrix, options.lambdaBias]
        let priorX: [Double] = [1, 0, 0]
        let priorY: [Double] = [0, 1, 0]

        guard var weights = ridge(
            rows: rows, targets: targets, penalties: penalties,
            priorX: priorX, priorY: priorY)
        else { return nil }

        // Second pass: a sweep always contains blinks the collector missed and
        // moments the eye lost the dot. Cut what the first pass cannot explain
        // and fit again on what is left.
        var kept = samples.count
        let residuals = rows.indices.map { index -> CGFloat in
            let predicted = apply(weights, rows[index])
            let dx = predicted.x - targets[index].x
            let dy = predicted.y - targets[index].y
            return CGFloat((dx * dx + dy * dy).squareRoot())
        }
        let middle = median(residuals)
        let deviation = median(residuals.map { abs($0 - middle) }) * 1.4826
        let cut = middle + options.outlierMultiple * max(deviation, options.deviationFloor)
        let survivors = residuals.indices.filter { residuals[$0] <= cut }
        if survivors.count >= max(20, samples.count / 2), survivors.count < samples.count {
            if let refit = ridge(
                rows: survivors.map { rows[$0] },
                targets: survivors.map { targets[$0] },
                penalties: penalties, priorX: priorX, priorY: priorY)
            {
                weights = refit
                kept = survivors.count
            }
        }

        var fitted = GazeAffineCalibration(
            m00: CGFloat(weights.x[0]),
            m01: CGFloat(weights.x[1]),
            m10: CGFloat(weights.y[0]),
            m11: CGFloat(weights.y[1]),
            bx: CGFloat(weights.x[2]),
            by: CGFloat(weights.y[2]),
            fitRMS: 0,
            sampleCount: samples.count,
            keptSampleCount: kept,
            lag: lag,
            referenceViewSize: viewSize,
            pointsPerDegree: options.pointsPerDegree)
        fitted.fitRMS = fitted.rootMeanSquareError(over: samples)
        return fitted
    }

    /// Fits every candidate lag and keeps the one that explains the sweep best.
    public static func fit(
        byLag buffers: [(lag: TimeInterval, samples: [CalibrationSample])],
        viewSize: CGSize,
        options: FitOptions = FitOptions()
    ) -> GazeAffineCalibration? {
        var best: GazeAffineCalibration?
        for buffer in buffers {
            guard let candidate = fit(
                samples: buffer.samples, viewSize: viewSize, lag: buffer.lag, options: options)
            else { continue }
            if best == nil || candidate.fitRMS < best!.fitRMS { best = candidate }
        }
        return best
    }

    /// Root-mean-square error of this calibration over a sample set, in points.
    public func rootMeanSquareError(over samples: [CalibrationSample]) -> CGFloat {
        guard !samples.isEmpty else { return 0 }
        var total: Double = 0
        for sample in samples {
            let predicted = point(from: sample.raw)
            let dx = Double(predicted.x - sample.target.x)
            let dy = Double(predicted.y - sample.target.y)
            total += dx * dx + dy * dy
        }
        return CGFloat((total / Double(samples.count)).squareRoot())
    }

    // MARK: - Validation

    /// Scores held-out samples, one number per quadrant they fall in.
    ///
    /// The predictions in a quadrant are reduced by MEDIAN before the error is
    /// taken, so the verdict measures the bias that will still be there while
    /// reading rather than the frame-to-frame noise the filters remove.
    /// Returns nil when nothing was captured.
    public func validate(samples: [CalibrationSample]) -> CalibrationVerdict? {
        var byQuadrant: [GazeScreenQuadrant: [CalibrationSample]] = [:]
        for sample in samples {
            let quadrant = GazeScreenQuadrant.containing(sample.target, in: referenceViewSize)
            byQuadrant[quadrant, default: []].append(sample)
        }
        var errors: [(GazeScreenQuadrant, CGFloat)] = []
        for quadrant in GazeScreenQuadrant.allCases {
            guard let group = byQuadrant[quadrant], !group.isEmpty else { continue }
            let predicted = group.map { point(from: $0.raw) }
            let centre = CGPoint(
                x: Self.median(predicted.map(\.x)), y: Self.median(predicted.map(\.y)))
            let target = CGPoint(
                x: Self.median(group.map(\.target.x)), y: Self.median(group.map(\.target.y)))
            let error = ((centre.x - target.x) * (centre.x - target.x)
                + (centre.y - target.y) * (centre.y - target.y)).squareRoot()
            errors.append((quadrant, error))
        }
        guard !errors.isEmpty else { return nil }
        let mean = errors.reduce(CGFloat(0)) { $0 + $1.1 } / CGFloat(errors.count)
        let worst = errors.max { $0.1 < $1.1 }!
        let degrees = mean / max(pointsPerDegree, 1e-6)
        return CalibrationVerdict(
            meanError: mean,
            worstQuadrant: CalibrationVerdict.QuadrantError(quadrant: worst.0, error: worst.1),
            degrees: degrees,
            grade: CalibrationVerdict.grade(forDegrees: degrees))
    }

    /// Validates and keeps the verdict.
    @discardableResult
    public mutating func recordValidation(samples: [CalibrationSample]) -> CalibrationVerdict? {
        let scored = validate(samples: samples)
        if let scored { verdict = scored }
        return scored
    }

    /// Whether a view this size is different enough to invalidate the fit.
    public func viewSizeDrift(from size: CGSize) -> CGFloat {
        guard referenceViewSize.width > 0, referenceViewSize.height > 0 else { return 0 }
        return abs(size.width - referenceViewSize.width) / referenceViewSize.width
            + abs(size.height - referenceViewSize.height) / referenceViewSize.height
    }

    // MARK: - Linear algebra

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    private static func apply(
        _ weights: (x: [Double], y: [Double]), _ row: [Double]
    ) -> (x: Double, y: Double) {
        var x: Double = 0
        var y: Double = 0
        for index in row.indices {
            x += weights.x[index] * row[index]
            y += weights.y[index] * row[index]
        }
        return (x, y)
    }

    /// Solves `(ZᵀZ/n + Λ) w = ZᵀY/n + Λ w₀` for both output axes.
    private static func ridge(
        rows: [[Double]],
        targets: [(x: Double, y: Double)],
        penalties: [Double],
        priorX: [Double],
        priorY: [Double]
    ) -> (x: [Double], y: [Double])? {
        let count = rows.count
        guard count > 0 else { return nil }
        let width = rows[0].count
        var normal = [[Double]](repeating: [Double](repeating: 0, count: width), count: width)
        var rhsX = [Double](repeating: 0, count: width)
        var rhsY = [Double](repeating: 0, count: width)
        for index in 0..<count {
            let row = rows[index]
            for a in 0..<width {
                let za = row[a]
                if za == 0 { continue }
                for b in 0..<width { normal[a][b] += za * row[b] }
                rhsX[a] += za * targets[index].x
                rhsY[a] += za * targets[index].y
            }
        }
        let n = Double(count)
        for a in 0..<width {
            for b in 0..<width { normal[a][b] /= n }
            normal[a][a] += penalties[a]
            rhsX[a] = rhsX[a] / n + penalties[a] * priorX[a]
            rhsY[a] = rhsY[a] / n + penalties[a] * priorY[a]
        }
        guard let inverse = invert(normal) else { return nil }
        var weightsX = [Double](repeating: 0, count: width)
        var weightsY = [Double](repeating: 0, count: width)
        for a in 0..<width {
            var sx: Double = 0
            var sy: Double = 0
            for b in 0..<width {
                sx += inverse[a][b] * rhsX[b]
                sy += inverse[a][b] * rhsY[b]
            }
            weightsX[a] = sx
            weightsY[a] = sy
        }
        return (weightsX, weightsY)
    }

    /// Gauss-Jordan inverse with partial pivoting. The matrix is 3×3.
    private static func invert(_ matrix: [[Double]]) -> [[Double]]? {
        let n = matrix.count
        var work = [[Double]](repeating: [Double](repeating: 0, count: 2 * n), count: n)
        for i in 0..<n {
            for j in 0..<n { work[i][j] = matrix[i][j] }
            work[i][n + i] = 1
        }
        for column in 0..<n {
            var pivot = column
            for row in (column + 1)..<n where abs(work[row][column]) > abs(work[pivot][column]) {
                pivot = row
            }
            guard abs(work[pivot][column]) > 1e-14 else { return nil }
            if pivot != column { work.swapAt(pivot, column) }
            let divisor = work[column][column]
            for j in column..<(2 * n) { work[column][j] /= divisor }
            for row in 0..<n where row != column {
                let factor = work[row][column]
                if factor == 0 { continue }
                for j in column..<(2 * n) { work[row][j] -= factor * work[column][j] }
            }
        }
        var out = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in 0..<n { out[i][j] = work[i][n + j] }
        }
        return out
    }
}

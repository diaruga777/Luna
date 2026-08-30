import Foundation

/// A deterministic, non-gating measurement of the v1 exact-vector cost. It is
/// intentionally separate from correctness tests: device generation and thermal
/// state are recorded by XCTest, but never turned into a flaky wall-clock limit.
public enum VaultSearchPerformanceProbe {
    public struct Measurement: Equatable, Sendable {
        public let objectCount: Int
        public let dimension: Int
        public let elapsed: TimeInterval
        public let bestIndex: Int
        public init(objectCount: Int, dimension: Int, elapsed: TimeInterval, bestIndex: Int) {
            self.objectCount=objectCount; self.dimension=dimension; self.elapsed=elapsed; self.bestIndex=bestIndex
        }
    }

    public static func measureExactVectorBaseline(objectCount: Int = 100_000,
                                                  dimension: Int = 32) -> Measurement {
        precondition(objectCount > 0 && dimension > 0)
        let query = (0..<dimension).map { Double(($0 % 11) + 1) / 11.0 }
        var best = -Double.infinity, bestIndex = 0
        let start = ProcessInfo.processInfo.systemUptime
        for object in 0..<objectCount {
            var dot=0.0, lhs=0.0, rhs=0.0
            for component in 0..<dimension {
                let value = Double(((object &* 31 &+ component &* 17) % 101) + 1) / 101.0
                dot += value * query[component]; lhs += value * value
                rhs += query[component] * query[component]
            }
            let score = dot / (sqrt(lhs) * sqrt(rhs))
            if score > best { best=score; bestIndex=object }
        }
        return Measurement(objectCount: objectCount, dimension: dimension,
            elapsed: ProcessInfo.processInfo.systemUptime - start, bestIndex: bestIndex)
    }
}

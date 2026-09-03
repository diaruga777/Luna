//
//  GazeSimRandom.swift
//  LunaTests
//

import Foundation

/// Deterministic pseudo-random source. The same seed gives the same run, so a
/// failure is reproducible rather than a coin toss.
struct SimRandom {
    private var seed: Int64

    init(seed: Int64 = 12345) { self.seed = seed }

    mutating func unit() -> Double {
        seed = (seed &* 1_103_515_245 &+ 12345) & 0x7fff_ffff
        return Double(seed) / Double(0x7fff_ffff)
    }

    mutating func gaussian(_ sigma: Double) -> Double {
        let u = unit() + 1e-12
        return sigma * (-2 * log(u)).squareRoot() * cos(2 * Double.pi * unit())
    }
}

//
//  WaveKernelSourceTests.swift
//  LunaTests
//

import XCTest

@testable import Luna

final class WaveKernelSourceTests: XCTestCase {

    /// The save wave's kernels must load from the compiled Metal library
    /// (`LunaWaveKernels.ci.metal` → default.metallib, CI-flagged in
    /// `Config/Luna.xcconfig`). The in-source CIKL strings are only a logged
    /// fallback: CIKL is deprecated, and an OS that refuses to compile it
    /// makes the wave silently invisible rather than failing. If this test
    /// fails, the metallib was dropped or compiled without `-fcikernel`.
    @MainActor
    func testWaveKernelsLoadFromTheCompiledMetalLibrary() {
        XCTAssertTrue(LiquidScreenWaveAnimator.kernelsLoadFromMetalLibrary)
    }
}

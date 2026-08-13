//
//  PollingSupport.swift
//  LunaTests
//

import XCTest

/// Polls `condition` on the main run loop until it becomes true or `timeout`
/// elapses, then asserts it holds. Many of the states these tests check land
/// after a `Task` hop, an animation completion, or a debounced sweep — a
/// fixed-duration pump is never a wait for those; this spins the run loop in
/// short slices so the condition is re-checked as soon as it might have
/// changed.
func waitUntil(
    _ condition: @autoclosure () -> Bool,
    timeout: TimeInterval = 3,
    message: @autoclosure () -> String = "condition not met in time",
    file: StaticString = #filePath, line: UInt = #line
) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertTrue(condition(), message(), file: file, line: line)
}

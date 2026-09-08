import XCTest

/// Cold-launch measurement for whichever app hosts this bundle.
///
/// One file, compiled into two UI-test targets: `LunaLaunchTests` (host `Luna`)
/// and `LunaReaderLaunchTests` (host `LunaReader`). `XCUIApplication()` with no
/// bundle identifier resolves to the target's `TEST_TARGET_NAME` host, so the
/// same code measures both apps.
///
/// Run it through the `LaunchPerf` test plan — see
/// `claudedocs/launch-measurement.md` and `scripts/measure_launch.sh`. Build in
/// Release: Debug links the debug-dylib arrangement at `-Onone`, which distorts
/// the dyld work this measurement exists to watch.
final class LaunchPerformanceTests: XCTestCase {
    /// Iterations per metric. XCTest launches once more as a warm-up and drops
    /// that value, so the report holds 10 usable ones.
    private static let iterationCount = 10

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Process start to the first frame.
    func testLaunchPerformance() throws {
        let options = XCTMeasureOptions()
        options.iterationCount = Self.iterationCount
        measure(metric: XCTApplicationLaunchMetric(), options: options) {
            XCUIApplication().launch()
        }
    }

    /// Process start to the app answering the accessibility server. This is the
    /// number a user feels, and it covers first-screen work that the first-frame
    /// metric can hide.
    func testLaunchToResponsivePerformance() throws {
        let options = XCTMeasureOptions()
        options.iterationCount = Self.iterationCount
        measure(metric: XCTApplicationLaunchMetric(waitUntilResponsive: true), options: options) {
            XCUIApplication().launch()
        }
    }
}

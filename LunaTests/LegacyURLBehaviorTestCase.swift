import LunaModels
import XCTest

/// Exercises the native URL pipeline independently of Reader's plugin-owned
/// pipeline. Restore the host policy after every test, including failures.
@MainActor
class LegacyURLBehaviorTestCase: XCTestCase {
    private var previousURLPolicy = false

    override func setUp() {
        super.setUp()
        previousURLPolicy = URLBehaviorPolicy.pluginsOnly
        URLBehaviorPolicy.pluginsOnly = false
    }

    override func tearDown() {
        URLBehaviorPolicy.pluginsOnly = previousURLPolicy
        super.tearDown()
    }
}

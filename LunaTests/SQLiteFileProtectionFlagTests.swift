@testable import LunaPluginKit
@testable import LunaStorage
import XCTest

final class SQLiteFileProtectionFlagTests: XCTestCase {
    func testDatabasesUseCompleteUntilFirstAuthentication() {
        // sqlite3.h in the iOS 26 SDK: NONE is 0x0040_0000; the intended
        // COMPLETEUNTILFIRSTUSERAUTHENTICATION policy is 0x0030_0000.
        XCTAssertEqual(
            SavesDatabase.openFileProtectionCompleteUntilFirstUserAuthentication,
            0x0030_0000)
        XCTAssertEqual(
            PluginDatabase.openFileProtectionCompleteUntilFirstUserAuthentication,
            0x0030_0000)
    }
}

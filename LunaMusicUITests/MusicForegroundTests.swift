import XCTest

final class MusicForegroundTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.hsanabria.luna.music")
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.firstMatch.waitForExistence(timeout: 2) {
            let alert = springboard.alerts.firstMatch
            if alert.buttons["Allow"].exists { alert.buttons["Allow"].tap() }
            else if alert.buttons["OK"].exists { alert.buttons["OK"].tap() }
        }
    }

    func testLaunchFocusesLibrarySearch() {
        let search = app.searchFields["music.library.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Playlists"].exists)
    }

    func testForegroundClearsSearchAndFocusesKeyboard() {
        let search = app.searchFields["music.library.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("NoSuchSongLuna")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Playlists"].waitForExistence(timeout: 5))
        XCTAssertNotEqual(search.value as? String, "NoSuchSongLuna")
    }

    func testQueueLinkOverridesSearchOnWarmAndColdLaunch() {
        let url = URL(string: "lunamusic://queue")!
        app.open(url)
        XCTAssertTrue(app.otherElements["music.playback.queue"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.terminate()
        app.open(url)
        XCTAssertTrue(app.otherElements["music.playback.queue"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }
}

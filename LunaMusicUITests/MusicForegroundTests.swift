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
    func testPlayerQueueKeepsControlsVisibleAndShowsPlaybackModes() {
        app.open(URL(string: "lunamusic://queue")!)
        XCTAssertTrue(app.otherElements["music.playback.queue"].waitForExistence(timeout: 5))
        let queueButton = app.buttons["music.playback.queueButton"]
        let play = app.buttons["Play"]
        let volume = app.otherElements["music.playback.volume"]
        XCTAssertTrue(queueButton.isHittable)
        XCTAssertTrue(play.isHittable)
        let playbackFrame = play.frame
        let shuffle = app.buttons["Shuffle"]
        let wasSelected = shuffle.isSelected
        shuffle.tap()
        XCTAssertEqual(shuffle.isSelected, !wasSelected)
        shuffle.tap()
        XCTAssertEqual(shuffle.isSelected, wasSelected)
        let repeatButton = app.buttons["Repeat"]
        for _ in 0..<3 {
            repeatButton.tap()
            XCTAssertEqual(repeatButton.isSelected, (repeatButton.value as? String) != "Off")
        }
        queueButton.tap()
        XCTAssertTrue(app.otherElements["music.playback.nowPlaying"].waitForExistence(timeout: 5))
        XCTAssertFalse(queueButton.isSelected)
        XCTAssertTrue(queueButton.isHittable)
        XCTAssertEqual(play.frame.minY, playbackFrame.minY, accuracy: 1)
        if volume.exists { XCTAssertLessThan(volume.frame.maxY, app.frame.maxY) }
        let player = app.otherElements["music.playback.nowPlaying"]
        player.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: player.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        XCTAssertTrue(app.otherElements["music.playback.queue"].waitForExistence(timeout: 5))
        XCTAssertTrue(queueButton.isSelected)
        XCTAssertTrue(play.isHittable)
        XCTAssertEqual(play.frame.minY, playbackFrame.minY, accuracy: 1)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Queue with fixed playback controls"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Close Now Playing"].tap()
        XCTAssertTrue(app.buttons["Open Now Playing"].waitForExistence(timeout: 5))
    }

}

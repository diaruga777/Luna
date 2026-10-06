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

    func testVaultCacheSettingsAndPlaylistSourceChoice() {
        if app.navigationBars.buttons["Close"].exists { app.navigationBars.buttons["Close"].tap() }
        else if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5)); settings.tap()
        XCTAssertTrue(app.staticTexts["Luna Mac"].waitForExistence(timeout: 5))
        let stepper = app.steppers["Automatically cached playlists"]
        XCTAssertTrue(stepper.exists)
        for _ in 0..<10 { if stepper.buttons["Increment"].isEnabled { stepper.buttons["Increment"].tap() } }
        XCTAssertTrue(app.staticTexts["Top 10 playlists"].exists)
        for _ in 0..<10 { if stepper.buttons["Decrement"].isEnabled { stepper.buttons["Decrement"].tap() } }
        XCTAssertTrue(app.staticTexts["Top 0 playlists"].exists)
        for _ in 0..<3 { stepper.buttons["Increment"].tap() }
        XCTAssertTrue(app.staticTexts["Top 3 playlists"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Vault music cache settings"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.staticTexts["Playlists"].tap()
        app.navigationBars.buttons["Add"].tap()
        XCTAssertTrue(app.alerts["New Playlist"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.alerts.buttons["Apple Music"].exists)
        app.alerts.buttons["Luna Vault"].tap()
        let name = app.alerts.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 3)); name.typeText("Vault UI Test")
        app.alerts.buttons["Create"].tap()
        XCTAssertTrue(app.buttons["music.playlist.addMusic"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Download All Vault Songs"].exists)
        app.buttons["Playlist Options"].tap()
        app.buttons["Delete Playlist"].tap()
        XCTAssertFalse(app.staticTexts["Vault UI Test"].exists)
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

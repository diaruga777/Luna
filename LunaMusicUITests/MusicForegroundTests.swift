import XCTest

final class MusicForegroundTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.hsanabria.luna.music")
        app.launchArguments = ["-LunaMusic.browsingPodcasts", "NO", "-LunaMusic.activeMedia", "music"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.firstMatch.waitForExistence(timeout: 2) {
            let alert = springboard.alerts.firstMatch
            if alert.buttons["Allow"].exists { alert.buttons["Allow"].tap() }
            else if alert.buttons["OK"].exists { alert.buttons["OK"].tap() }
        }
    }

    func testPodcastsNavigationAndPlaybackSettings() {
        if app.navigationBars.buttons["Close"].exists { app.navigationBars.buttons["Close"].tap() }
        else if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        let podcasts = app.staticTexts["Podcasts"]
        XCTAssertTrue(podcasts.waitForExistence(timeout: 5)); podcasts.tap()
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        let sections = app.segmentedControls["podcasts.sections"]
        XCTAssertTrue(sections.waitForExistence(timeout: 5)); sections.buttons["Library"].tap()
        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Downloaded"].exists)
        sections.buttons["Search"].tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        sections.buttons["Home"].tap()
        let more = app.navigationBars.buttons["Podcast Options"]
        XCTAssertTrue(more.waitForExistence(timeout: 5)); more.tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Skip Back"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["15 seconds"].exists)
        XCTAssertTrue(app.staticTexts["30 seconds"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Podcast playback settings"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    func testPodcastFeedShowsProgressWhileLoading() throws {
        guard let base = ProcessInfo.processInfo.environment["LUNA_PODCAST_FIXTURE_URL"] else { throw XCTSkip("Run with the local podcast fixture server.") }
        if app.navigationBars.buttons["Close"].exists { app.navigationBars.buttons["Close"].tap() }
        else if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        app.staticTexts["Podcasts"].tap()
        app.navigationBars.buttons["Podcast Options"].tap()
        app.buttons["Follow a Show by URL"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3)); field.tap()
        field.typeText(base + "?loading-test=" + UUID().uuidString)
        app.alerts.buttons["Follow"].tap()
        let spinner = app.activityIndicators["podcasts.actionLoading"]
        XCTAssertTrue(spinner.waitForExistence(timeout: 1))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Podcast feed loading"; screenshot.lifetime = .keepAlways; add(screenshot)
        XCTAssertTrue(app.staticTexts["Fixture Episode Two"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars.buttons["Following"].waitForExistence(timeout: 5))
        XCTAssertFalse(spinner.exists)
        app.navigationBars.buttons["Following"].tap()
    }

    func testPodcastFeedFollowAutoDownloadAndEpisodeActions() throws {
        guard let feedURL = ProcessInfo.processInfo.environment["LUNA_PODCAST_FIXTURE_URL"] else { throw XCTSkip("Run with the local podcast fixture server.") }
        if app.navigationBars.buttons["Close"].exists { app.navigationBars.buttons["Close"].tap() }
        else if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        app.staticTexts["Podcasts"].tap()
        app.navigationBars.buttons["Podcast Options"].tap()
        app.buttons["Follow a Show by URL"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3)); field.tap(); field.typeText(feedURL)
        app.alerts.buttons["Follow"].tap()
        XCTAssertTrue(app.staticTexts["Fixture Episode Two"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.navigationBars.buttons["Following"].exists)
        let downloaded = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Downloaded' AND label CONTAINS '0:30'")).firstMatch
        XCTAssertTrue(downloaded.waitForExistence(timeout: 20))
        let episode = app.cells.containing(.staticText, identifier: "Fixture Episode One").firstMatch
        episode.buttons["Episode Actions"].tap(); app.buttons["Save Episode"].tap()
        episode.buttons["Episode Actions"].tap(); XCTAssertTrue(app.buttons["Unsave Episode"].waitForExistence(timeout: 3)); app.buttons["Unsave Episode"].tap()
        episode.buttons["Episode Actions"].tap()
        if app.buttons["Mark as Unplayed"].exists {
            app.buttons["Mark as Unplayed"].tap()
            episode.buttons["Episode Actions"].tap()
        }
        app.buttons["Mark as Played"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Played'")).firstMatch.waitForExistence(timeout: 3))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Podcast followed feed and offline episode"; screenshot.lifetime = .keepAlways; add(screenshot)
        episode.tap()
        app.buttons["Open Now Playing"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 10))
        app.buttons["Pause"].tap()
        let position = app.sliders["Episode Position"]
        XCTAssertTrue(position.isHittable)
        position.adjust(toNormalizedSliderPosition: 0.5)
        let elapsed = app.staticTexts["podcasts.playback.elapsed"]
        let sought = NSPredicate(format: "label MATCHES '0:1[456]' ")
        expectation(for: sought, evaluatedWith: elapsed)
        waitForExpectations(timeout: 5)
        let pausedPosition = elapsed.label
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
        XCTAssertEqual(elapsed.label, pausedPosition)
        app.buttons["Skip Back 15 Seconds"].tap()
        expectation(for: NSPredicate(format: "label MATCHES '0:0[01]'"), evaluatedWith: elapsed)
        waitForExpectations(timeout: 5)
        position.adjust(toNormalizedSliderPosition: 0.5)
        app.buttons["Playback Speed"].tap(); app.buttons["1.5×"].tap()
        XCTAssertEqual(app.buttons["Playback Speed"].value as? String, "1.5 times")
        app.buttons["Sleep Timer"].tap(); app.buttons["When Current Episode Ends"].tap()
        XCTAssertEqual(app.buttons["Sleep Timer"].value as? String, "When Current Episode Ends")
        app.buttons["Sleep Timer"].tap(); app.buttons["Off"].tap()
        app.buttons["Episode Actions"].tap()
        XCTAssertTrue(app.buttons["Switch to Music"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.3)).tap()
        // UIKit can leave XCTest's hit point unset after a menu dismisses.
        app.buttons["Playing Next"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["Your Queue Is Empty"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Continue Playing"].exists)
        app.buttons["Episode Actions"].tap()
        XCTAssertTrue(app.buttons["Switch to Music"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.3)).tap()
        let queueScreenshot = XCTAttachment(screenshot: app.screenshot())
        queueScreenshot.name = "Podcast explicit queue and Music switch"; queueScreenshot.lifetime = .keepAlways; add(queueScreenshot)
        // UIKit can leave XCTest's hit point unset after a menu dismisses.
        app.buttons["Playing Next"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["Close Now Playing"].tap()
        let next = app.cells.containing(.staticText, identifier: "Fixture Episode Two").firstMatch
        next.buttons["Episode Actions"].tap()
        app.buttons["Add to Queue"].tap()
        app.buttons["Open Now Playing"].tap()
        app.buttons["Playing Next"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let queued = app.cells.containing(.staticText, identifier: "Fixture Episode Two").firstMatch
        XCTAssertTrue(queued.waitForExistence(timeout: 5))
        queued.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Remove from Queue"].waitForExistence(timeout: 3))
        app.buttons["Remove from Queue"].tap()
        XCTAssertTrue(app.staticTexts["Your Queue Is Empty"].waitForExistence(timeout: 5))
        app.buttons["Close Now Playing"].tap()
        app.navigationBars.buttons["Following"].tap()
        app.navigationBars.buttons["BackButton"].tap()
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(app.staticTexts["Podcasts"].waitForExistence(timeout: 5))
    }

    func testRootOptionsAndDownloadedFilters() {
        if app.navigationBars.buttons["Close"].exists { app.navigationBars.buttons["Close"].tap() }
        else if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        XCTAssertTrue(app.staticTexts["Podcasts"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Downloaded"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        app.navigationBars.buttons["Music Filters"].tap()
        app.buttons["Downloaded"].tap()
        for category in ["Playlists", "Artists", "Albums", "Songs"] {
            app.staticTexts[category].tap()
            XCTAssertTrue(app.staticTexts["No Downloaded Music"].waitForExistence(timeout: 5))
            app.navigationBars.buttons["Music Filters and Sort"].tap()
            app.buttons["Downloaded"].tap()
            XCTAssertFalse(app.staticTexts["No Downloaded Music"].exists)
            app.navigationBars.buttons["Library"].tap()
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Library root with Podcasts and Downloaded filter"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testPodcastBrowsingSurvivesForegroundAndSearchLinkReturnsToMusic() {
        if app.navigationBars.buttons["Close"].exists { app.navigationBars.buttons["Close"].tap() }
        else if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        app.staticTexts["Podcasts"].tap()
        let sections = app.segmentedControls["podcasts.sections"]
        XCTAssertTrue(sections.waitForExistence(timeout: 5))
        sections.buttons["Library"].tap()
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(sections.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Saved"].exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.open(URL(string: "lunamusic://search")!)
        XCTAssertTrue(app.searchFields["music.library.search"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(sections.exists)
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
        XCTAssertTrue(app.buttons["Switch to Podcasts"].exists)
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

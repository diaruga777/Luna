import XCTest

final class CodeEditorUITests: XCTestCase {
    func testRotationEditingExplicitSaveAndDraftRecovery() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-preview"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let editor = app.scrollViews.children(matching: .textView).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.tap()
        app.typeText("// phone edit\n")
        let save = app.buttons["Save to Mac"]
        XCTAssertTrue(save.isEnabled)
        attach("Portrait · software keyboard", app)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        expectation(for: NSPredicate { _, _ in editor.frame.width > editor.frame.height }, evaluatedWith: editor)
        waitForExpectations(timeout: 5)
        // UIKit and the simulator screenshot surface finish rotating separately.
        Thread.sleep(forTimeInterval: 1)
        app.typeText("// landscape edit\n")
        attach("Landscape · software keyboard", app)
        save.tap()
        let saved = NSPredicate(format: "enabled == false")
        expectation(for: saved, evaluatedWith: save)
        waitForExpectations(timeout: 5)
        app.typeText("// unsaved recovery\n")
        XCUIDevice.shared.press(.home)
        app.terminate()
        app.launchArguments = ["--editor-preview"]
        app.launch()
        let restored = app.scrollViews.children(matching: .textView).firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        XCTAssertTrue((restored.value as? String ?? "").contains("unsaved recovery"), "Restored value: \(String(describing: restored.value))")
        XCUIDevice.shared.orientation = .portrait
    }
    func testHardwareSaveShortcutOnIPad() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("XCTest modifier-key injection requires iPadOS.") }
        let app = XCUIApplication(); app.launchArguments = ["--editor-preview", "--reset-preview"]; app.launch()
        let editor = app.scrollViews.children(matching: .textView).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15)); editor.tap(); app.typeText("// hardware edit\n")
        app.typeKey("s", modifierFlags: .command)
        expectation(for: NSPredicate(format: "enabled == false"), evaluatedWith: app.buttons["Save to Mac"])
        waitForExpectations(timeout: 5)
    }
    func testProjectSelectionBrowsingAndRestoration() {
        continueAfterFailure = false
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--editor-preview", "--workspace-preview", "--reset-preview"]
        app.launch()
        let project = app.cells["CodeFile:/Preview/Sample.xcodeproj"]
        XCTAssertTrue(project.waitForExistence(timeout: 15)); project.tap()
        let folder = app.cells["CodeFile:/Preview/Sources"]
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Project Settings"].exists)
        attach("Project files", app)
        app.terminate()
        app.launchArguments = ["--editor-preview", "--workspace-preview"]
        app.launch()
        XCTAssertTrue(folder.waitForExistence(timeout: 10)); folder.tap()
        app.cells["CodeFile:/Preview/Sources/Detail.swift"].tap()
        let editor = app.scrollViews.children(matching: .textView).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap(); app.typeText("// project draft\n")
        XCUIDevice.shared.press(.home); app.terminate(); app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue((editor.value as? String ?? "").contains("project draft"))
        app.buttons["Editor Actions"].tap(); app.buttons["Close File"].tap()
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        XCTAssertFalse(editor.exists, "Closing the last file must leave the project browser on relaunch")
    }

    func testSwitchProjectsAndChooseSchemeWithoutLosingBrowser() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--workspace-preview", "--reset-preview"]
        app.launch()
        let project = app.cells["CodeFile:/Preview/Sample.xcodeproj"]
        XCTAssertTrue(project.waitForExistence(timeout: 15)); project.tap()
        app.buttons["Browser Actions"].tap(); app.buttons["Project Settings"].tap()
        XCTAssertTrue(app.navigationBars["Project Settings"].waitForExistence(timeout: 5))
        app.navigationBars["Project Settings"].buttons["Save"].tap()
        XCTAssertTrue(app.cells.staticTexts["Sample"].waitForExistence(timeout: 10))
        app.cells.staticTexts["Sample"].tap()
        XCTAssertTrue(app.cells["CodeFile:/Preview/Welcome.swift"].waitForExistence(timeout: 5))
        app.buttons["Browser Actions"].tap(); app.buttons["Choose Build Scheme…"].tap()
        XCTAssertTrue(app.cells.staticTexts["SampleTests"].waitForExistence(timeout: 5))
        app.cells.staticTexts["SampleTests"].tap()
        app.cells["CodeFile:/Preview/Sample.xcodeproj"].tap()
        app.buttons["Browser Actions"].tap(); app.buttons["Project Settings"].tap()
        XCTAssertEqual(app.textFields["CodeSettings:Scheme"].value as? String, "SampleTests", "Reopening the current project must preserve its scheme")
        app.navigationBars["Project Settings"].buttons["Cancel"].tap()
        app.cells["CodeFile:/Preview/Welcome.swift"].tap()
        XCTAssertTrue(app.scrollViews.children(matching: .textView).firstMatch.waitForExistence(timeout: 5))
        app.buttons["Project Files"].tap()
        app.buttons["Browser Actions"].tap(); app.buttons["Browse Mac Files"].tap()
        app.cells["CodeFile:/Other/Other.xcworkspace"].tap()
        XCTAssertTrue(app.cells["CodeFile:/Other/Other.swift"].waitForExistence(timeout: 5))
        app.terminate(); app.launchArguments = ["--editor-preview", "--workspace-preview"]; app.launch()
        XCTAssertTrue(app.cells["CodeFile:/Other/Other.swift"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.scrollViews.children(matching: .textView).firstMatch.exists)
    }

    func testBrowserFailureShowsRecoveryAndRetainsProject() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--workspace-preview", "--reset-preview"]
        app.launch()
        let project = app.cells["CodeFile:/Preview/Sample.xcodeproj"]
        XCTAssertTrue(project.waitForExistence(timeout: 15)); project.tap()
        XCTAssertTrue(app.cells["CodeFile:/Preview/Sources"].waitForExistence(timeout: 5))
        app.terminate(); app.launchArguments = ["--editor-preview", "--workspace-preview", "--browser-failure"]; app.launch()
        XCTAssertTrue(app.staticTexts["Couldn’t Load Files"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Retry"].exists)
        app.terminate(); app.launchArguments = ["--editor-preview", "--workspace-preview"]; app.launch()
        XCTAssertTrue(app.cells["CodeFile:/Preview/Sources"].waitForExistence(timeout: 10))
    }

    func testSaveConflictKeepsDraftUntilExplicitResolution() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--reset-preview", "--save-conflict"]
        app.launch()
        let editor = app.scrollViews.children(matching: .textView).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.tap(); app.typeText("// keep my draft\n")
        app.buttons["Save to Mac"].tap()
        let conflict = app.alerts["This file changed on your Mac"]
        XCTAssertTrue(conflict.waitForExistence(timeout: 5))
        conflict.buttons["Keep Editing"].tap()
        XCTAssertTrue((editor.value as? String ?? "").contains("keep my draft"))
        app.buttons["Save to Mac"].tap()
        XCTAssertTrue(conflict.waitForExistence(timeout: 5))
        conflict.buttons["Use iPhone Version"].tap()
        expectation(for: NSPredicate(format: "enabled == false"), evaluatedWith: app.buttons["Save to Mac"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue((editor.value as? String ?? "").contains("keep my draft"))
    }

    func testBuildsCacheOneTapMainBuildAndLastTabRestoration() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--workspace-preview", "--reset-preview"]
        app.launch()
        let project = app.cells["CodeFile:/Preview/Sample.xcodeproj"]
        XCTAssertTrue(project.waitForExistence(timeout: 15)); project.tap()
        app.tabBars.buttons["Builds"].tap()
        let row = app.cells["CodeBuildApp:Sample"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertTrue(app.cells["CodeBuildApp:SampleCompanion"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.cells["CodeBuildApp:SampleAlias"].exists)
        XCTAssertFalse(app.cells["CodeBuildApp:SampleTests"].exists)
        attach("Cached app builds", app)
        app.buttons["CodeBuildOptions:Sample"].tap()
        XCTAssertTrue(app.buttons["Branch: main"].waitForExistence(timeout: 5))
        app.buttons["Branch: main"].tap()
        XCTAssertTrue(app.cells.staticTexts["feature/preview"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.buttons["CodeRun:Sample"].tap()
        XCTAssertTrue(app.staticTexts["CodeBuildStatus"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["CodeBuildStatus"].label.contains("You can leave Luna Code"))
        XCTAssertFalse(app.textViews["CodeBuildConsole"].exists)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 7)
        app.activate()
        XCTAssertTrue(app.staticTexts["Build Completed"].waitForExistence(timeout: 10))
        app.buttons["Show Console"].tap()
        XCTAssertTrue(app.textViews.containing(NSPredicate(format: "value CONTAINS %@", "Preview build from main on Preview iPhone")).firstMatch.waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        app.terminate(); app.launchArguments = ["--editor-preview", "--workspace-preview", "--build-offline"]; app.launch()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Builds"].isSelected)
        app.tabBars.buttons["Project"].tap()
        XCTAssertTrue(app.cells["CodeFile:/Preview/Sources"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(app.cells["CodeFile:/Preview/Sources"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Project"].isSelected)
    }

    func testBuildOptionsStayOpenWhileDiscoveryContinuesPastFailedAndLibrarySchemes() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--editor-preview", "--workspace-preview", "--reset-preview", "--build-discovery-delay"]
        app.launch()
        let project = app.cells["CodeFile:/Preview/Sample.xcodeproj"]
        XCTAssertTrue(project.waitForExistence(timeout: 15)); project.tap()
        app.tabBars.buttons["Builds"].tap()
        let options = app.buttons["CodeBuildOptions:Sample"]
        XCTAssertTrue(options.waitForExistence(timeout: 15)); options.tap()
        let branch = app.buttons["Branch: main"]
        XCTAssertTrue(branch.waitForExistence(timeout: 5))
        // Discovery returns an empty scheme, an error and two new app rows,
        // while several foreground job-poll ticks also pass.
        Thread.sleep(forTimeInterval: 12)
        XCTAssertTrue(branch.exists, "Discovery and polling must preserve an open row menu")
        branch.tap()
        XCTAssertTrue(app.cells.staticTexts["feature/preview"].waitForExistence(timeout: 5))
        app.cells.staticTexts["feature/preview"].tap()
        XCTAssertTrue(app.cells["CodeBuildApp:SampleCompanion"].waitForExistence(timeout: 10), "A failed scheme must not hide later apps")
        XCTAssertFalse(app.cells["CodeBuildApp:SampleLibrary"].exists)
        options.tap()
        XCTAssertTrue(app.buttons["Branch: feature/preview"].waitForExistence(timeout: 5), "Preserved buttons must read the latest row settings")
    }

    private func attach(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

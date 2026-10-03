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
        XCTAssertGreaterThan(editor.frame.width, editor.frame.height)
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
    private func attach(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

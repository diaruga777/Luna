import XCTest

/// Exploratory driver: walks a flow and writes a PNG per step to
/// `WRITER_UI_SHOTS` (a host path; simulator processes share the host
/// filesystem), so a reviewer can look at every screen without a Mac display.
final class WriterFlowUITests: XCTestCase {
    private var app: XCUIApplication!
    private var shotsDir: URL!
    private var step = 0

    override func setUpWithError() throws {
        continueAfterFailure = true
        let dir = ProcessInfo.processInfo.environment["WRITER_UI_SHOTS"] ?? "/tmp/writer-ui-shots"
        shotsDir = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: shotsDir, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launch()
    }

    private func shot(_ name: String) {
        step += 1
        let data = XCUIScreen.main.screenshot().pngRepresentation
        let file = shotsDir.appendingPathComponent(String(format: "%02d-%@.png", step, name))
        try? data.write(to: file)
    }

    private func dump(_ name: String) {
        let file = shotsDir.appendingPathComponent("\(name).txt")
        try? app.debugDescription.write(to: file, atomically: true, encoding: .utf8)
    }

    func testScriptedFlow() throws {
        let script = ProcessInfo.processInfo.environment["WRITER_UI_SCRIPT"] ?? "shot:launch"
        for raw in script.split(separator: ";") {
            let command = raw.trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { continue }
            let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
            let verb = parts[0]
            let arg = parts.count > 1 ? parts[1] : ""
            switch verb {
            case "shot": shot(arg)
            case "dump": dump(arg)
            case "sleep": Thread.sleep(forTimeInterval: Double(arg) ?? 1)
            case "tap":
                // tap:<label>  — first matching element of any type
                let el = app.descendants(matching: .any)[arg].firstMatch
                XCTAssertTrue(el.waitForExistence(timeout: 5), "missing \(arg)")
                el.tap()
            case "tapType":
                // tapType:<type>|<label>
                let p = arg.split(separator: "|", maxSplits: 1).map(String.init)
                let type = Self.type(named: p[0])
                let el = app.descendants(matching: type)[p[1]].firstMatch
                XCTAssertTrue(el.waitForExistence(timeout: 5), "missing \(arg)")
                el.tap()
            case "tapIndex":
                // tapIndex:<type>|<index>
                let p = arg.split(separator: "|").map(String.init)
                let el = app.descendants(matching: Self.type(named: p[0])).element(boundBy: Int(p[1]) ?? 0)
                XCTAssertTrue(el.waitForExistence(timeout: 5), "missing \(arg)")
                el.tap()
            case "tapAt":
                let p = arg.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
                let c = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: p[0], dy: p[1]))
                c.tap()
            case "pressAt":
                let p = arg.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
                let c = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: p[0], dy: p[1]))
                c.press(forDuration: 1.0)
            case "press":
                let el = app.descendants(matching: .any)[arg].firstMatch
                XCTAssertTrue(el.waitForExistence(timeout: 5), "missing \(arg)")
                el.press(forDuration: 1.0)
            case "type":
                app.typeText(arg.replacingOccurrences(of: "\\n", with: "\n"))
            case "typeInto":
                let p = arg.split(separator: "|", maxSplits: 1).map(String.init)
                let el = app.textViews[p[0]].exists ? app.textViews[p[0]] : app.textFields[p[0]]
                el.tap()
                el.typeText(p[1].replacingOccurrences(of: "\\n", with: "\n"))
            case "tapAlert":
                let button = app.alerts.buttons[arg].firstMatch
                XCTAssertTrue(button.waitForExistence(timeout: 5), "missing alert button \(arg)")
                button.tap()
            case "typeFirstField":
                // An alert's text field carries no label.
                let field = app.textFields.firstMatch
                XCTAssertTrue(field.waitForExistence(timeout: 5), "no text field")
                field.tap()
                field.typeText(arg)
            case "swipeUp": app.swipeUp()
            case "swipeDown": app.swipeDown()
            case "swipeLeft": app.swipeLeft()
            case "back":
                // The editor draws its own header, so its back control is a
                // plain button; a pushed list has a real navigation bar.
                let custom = app.buttons["Back"].firstMatch
                if custom.exists { custom.tap() } else { app.navigationBars.buttons.element(boundBy: 0).tap() }
            case "exists":
                XCTAssertTrue(app.descendants(matching: .any)[arg].firstMatch.waitForExistence(timeout: 5), "expected \(arg)")
            case "rotate":
                XCUIDevice.shared.orientation = arg == "landscape" ? .landscapeLeft : .portrait
            case "background":
                XCUIDevice.shared.press(.home)
                Thread.sleep(forTimeInterval: 1)
                app.activate()
            case "relaunch":
                // A force quit from the switcher: home, then the process is
                // killed, then a cold launch.
                XCUIDevice.shared.press(.home)
                Thread.sleep(forTimeInterval: 1)
                app.terminate()
                app.launch()
            default:
                XCTFail("unknown command \(command)")
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    private static func type(named name: String) -> XCUIElement.ElementType {
        switch name {
        case "button": return .button
        case "cell": return .cell
        case "textView": return .textView
        case "textField": return .textField
        case "staticText": return .staticText
        case "menuItem": return .menuItem
        case "navBar": return .navigationBar
        case "switch": return .switch
        case "table": return .table
        case "collection": return .collectionView
        default: return .any
        }
    }
}

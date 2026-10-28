import XCTest
import UIKit
import LunaAudioPlayback
import LunaModels
@testable import Luna

@MainActor
final class GeminiAudioSettingsTests: XCTestCase {
    func testSettingsExplainsCloudPrivacyAndOffersKeyAndCacheControls() throws {
        let wasEnabled = AudioSettings.usesGeminiVoice
        AudioSettings.usesGeminiVoice = false
        defer { AudioSettings.usesGeminiVoice = wasEnabled }
        let screen = AudioSettingsScreen()
        screen.loadViewIfNeeded()
        let table = screen.tableView!
        XCTAssertEqual(screen.numberOfSections(in: table), 4)
        XCTAssertEqual(screen.tableView(table, numberOfRowsInSection: 2), 5)
        let footer = try XCTUnwrap(screen.tableView(table, titleForFooterInSection: 2))
        XCTAssertTrue(footer.contains("Google"))
        XCTAssertTrue(footer.contains("paid"))
        let toggle = screen.tableView(table, cellForRowAt: IndexPath(row: 0, section: 2))
        XCTAssertNotNil(toggle.accessoryView as? UISwitch)
        let keyCell = screen.tableView(table, cellForRowAt: IndexPath(row: 1, section: 2))
        let configuration = try XCTUnwrap(keyCell.contentConfiguration as? UIListContentConfiguration)
        XCTAssertEqual(configuration.text, L10n.string("Gemini_key"))
        XCTAssertTrue([L10n.string("Gemini_savedKey"), L10n.string("Gemini_noKey")].contains(configuration.secondaryText ?? ""))

        screen.view.frame = CGRect(x: 0, y: 0, width: 402, height: 1100)
        screen.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: screen.view.bounds.size).image { _ in
            screen.view.drawHierarchy(in: screen.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Gemini Audio settings"
        attachment.lifetime = .keepAlways
        add(attachment)
        AudioSettings.usesGeminiVoice = true
        XCTAssertEqual(screen.tableView(table, titleForHeaderInSection: 3), L10n.string("Gemini_deviceVoiceHeader"))
        XCTAssertEqual(screen.tableView(table, titleForFooterInSection: 3), L10n.string("Gemini_deviceVoiceFooter"))
    }
}

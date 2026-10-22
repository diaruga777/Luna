import AVFoundation
import LunaModels
import UIKit
import XCTest
@testable import LunaMediaDownload
@testable import LunaShareSurface

@MainActor
final class SavedNonTextualPhotosLayoutTests: XCTestCase {
    func testSavingAndCompletionKeepThePreviewAndControlsInPlace() throws {
        for showsSystemShare in [true, false] {
            for height: CGFloat in [540, 760] {
                let (controller, saveButton, playerView) = try makeScreen(
                    height: height, showsSystemShare: showsSystemShare)
                XCTAssertEqual(
                    saveButton.bounds.width,
                    controller.view.layoutMarginsGuide.layoutFrame.width - 32, accuracy: 0.5,
                    "a short sheet must keep its column width when the preview yields height")
                let trackedViews = [playerView] + views(in: controller.view)
                    .filter { $0 is UIButton }
                let frames = trackedViews.map { $0.convert($0.bounds, to: controller.view) }

                controller.showSavingStatus()
                controller.view.layoutIfNeeded()
                XCTAssertFalse(saveButton.isEnabled)
                XCTAssertEqual(saveButton.configuration?.showsActivityIndicator, true)
                XCTAssertEqual(
                    trackedViews.map { $0.convert($0.bounds, to: controller.view) }, frames,
                    "saving must not squeeze the preview to fit a temporary status row")

                controller.finishSave(success: true)
                controller.view.layoutIfNeeded()
                XCTAssertEqual(
                    trackedViews.map { $0.convert($0.bounds, to: controller.view) }, frames)
                XCTAssertFalse(saveButton.isEnabled)
                XCTAssertEqual(saveButton.configuration?.showsActivityIndicator, false)
                XCTAssertEqual(saveButton.accessibilityLabel,
                               L10n.string("Downloader_media_preview_savedAccessibilityLabel"))
            }
        }
    }

    func testFailureAllowsRetryAndSuccessClearsTheError() throws {
        let (controller, saveButton, _) = try makeScreen(height: 540)
        controller.showSavingStatus()
        controller.finishSave(message: "Couldn’t save the video.", success: false)
        controller.view.layoutIfNeeded()

        XCTAssertTrue(saveButton.isEnabled)
        XCTAssertEqual(saveButton.configuration?.showsActivityIndicator, false)
        XCTAssertTrue(views(in: controller.view).contains {
            ($0 as? UILabel)?.text == "Couldn’t save the video." && !$0.isHidden
        })

        controller.showSavingStatus()
        controller.view.layoutIfNeeded()
        XCTAssertFalse(views(in: controller.view).contains {
            ($0 as? UILabel)?.text == "Couldn’t save the video." && !$0.isHidden
        })
        controller.finishSave(success: true)
        controller.view.layoutIfNeeded()
        XCTAssertFalse(views(in: controller.view).contains {
            ($0 as? UILabel)?.text == "Couldn’t save the video." && !$0.isHidden
        })
        XCTAssertFalse(saveButton.isEnabled)
    }

    private func makeScreen(
        height: CGFloat, showsSystemShare: Bool = true
    ) throws -> (SavedNonTextualViewController, UIButton, UIView) {
        HostedShareSession.current = nil
        let controller = SavedNonTextualViewController(
            articleURLString: ShareSetupPractice.instaTokURLString,
            showsSystemShare: showsSystemShare,
            practiceVideoURL: try XCTUnwrap(ShareSetupPractice.bundledVideoURL),
            delegate: nil)
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: height)
        let saveButton = try XCTUnwrap(views(in: controller.view)
            .compactMap { $0 as? UIButton }
            .first { $0.accessibilityLabel == L10n.string(
                "Downloader_media_preview_saveAccessibilityLabel") })
        let playerView = try XCTUnwrap(views(in: controller.view).first {
            $0.layer is AVPlayerLayer
        })
        waitUntil((playerView.layer as? AVPlayerLayer)?.player != nil, timeout: 5,
                  message: "the bundled preview never loaded")
        controller.view.layoutIfNeeded()
        XCTAssertFalse(saveButton.isHidden)
        XCTAssertGreaterThan(playerView.bounds.height, 100)
        return (controller, saveButton, playerView)
    }

    private func views(in root: UIView) -> [UIView] {
        [root] + root.subviews.flatMap { views(in: $0) }
    }
}

import LunaVaultStore
import XCTest

final class VaultFileFilterTests: XCTestCase {
    func testExtensionIgnoresCaseWhitespaceAndOptionalDot() {
        for ext in [".mp4", "MP4", " .Mp4 "] {
            XCTAssertTrue(VaultFileFilter.matches(path: "Trips/Clip.MP4", isFolder: false, extension: ext, category: nil))
        }
        XCTAssertFalse(VaultFileFilter.matches(path: "mp4/clip.mov", isFolder: false, extension: ".mp4", category: nil))
        XCTAssertFalse(VaultFileFilter.matches(path: "clip.mp4.txt", isFolder: false, extension: ".mp4", category: nil))
    }
    func testVideoFamilyIncludesMultipleContainers() {
        for ext in ["mp4", "mov", "m4v", "mkv", "webm", "avi", "mts"] {
            XCTAssertTrue(VaultFileFilter.matches(path: "clip." + ext, isFolder: false, extension: nil, category: "video"), ext)
        }
        XCTAssertFalse(VaultFileFilter.matches(path: "song.mp3", isFolder: false, extension: nil, category: "video"))
    }
    func testBothFiltersMustMatchAndFoldersNeverMatchFileFilters() {
        XCTAssertTrue(VaultFileFilter.matches(path: "clip.mp4", isFolder: false, extension: "mp4", category: "video"))
        XCTAssertFalse(VaultFileFilter.matches(path: "clip.mp4", isFolder: false, extension: "mp4", category: "audio"))
        XCTAssertFalse(VaultFileFilter.matches(path: "folder.mp4", isFolder: true, extension: "mp4", category: nil))
        XCTAssertFalse(VaultFileFilter.matches(path: "folder", isFolder: true, extension: nil, category: "video"))
        XCTAssertTrue(VaultFileFilter.matches(path: "folder", isFolder: true, extension: " ", category: nil))
    }
    func testOtherFamiliesAndUnknownExtensions() {
        for (ext, category) in [("flac", "audio"), ("png", "image"), ("pdf", "pdf"), ("md", "text"), ("zip", "archive")] {
            XCTAssertTrue(VaultFileFilter.matches(path: "file." + ext, isFolder: false, extension: nil, category: category))
        }
        XCTAssertFalse(VaultFileFilter.matches(path: "file.unknownxyz", isFolder: false, extension: nil, category: "video"))
        XCTAssertTrue(VaultFileFilter.matches(path: "file.custom", isFolder: false, extension: ".custom", category: nil))
    }
}

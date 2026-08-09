import LunaDesignSystem
import XCTest

final class LunaSurfacePaletteTests: XCTestCase {
    func testSurfaceResolutionIncludesHostAppExtensions() {
        XCTAssertEqual(
            LunaSurfacePalette.surface(for: "com.hsanabria.luna.reader.share"), .reader)
        XCTAssertEqual(
            LunaSurfacePalette.surface(for: "com.hsanabria.luna.downloader.action2"), .downloader)
        XCTAssertEqual(
            LunaSurfacePalette.surface(for: "com.hsanabria.luna.pricetracker.safari"), .priceTracker)
    }

}

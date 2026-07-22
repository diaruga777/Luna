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

    func testSuppliedBaseColorsArePreservedExactly() {
        assertRGB(LunaSurfacePalette.baseColor(for: .reader), 173, 181, 246)
        assertRGB(LunaSurfacePalette.baseColor(for: .downloader), 204, 118, 9)
        assertRGB(LunaSurfacePalette.baseColor(for: .priceTracker), 7, 255, 157)
    }

    private func assertRGB(
        _ color: UIColor, _ red: CGFloat, _ green: CGFloat, _ blue: CGFloat,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        var actualRed: CGFloat = 0
        var actualGreen: CGFloat = 0
        var actualBlue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(
            color.getRed(&actualRed, green: &actualGreen, blue: &actualBlue, alpha: &alpha),
            file: file, line: line)
        XCTAssertEqual(actualRed * 255, red, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualGreen * 255, green, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualBlue * 255, blue, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(alpha, 1, accuracy: 0.001, file: file, line: line)
    }
}

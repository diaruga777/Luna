//
//  SnapshotTesting.swift
//  LuneTests
//
//  A small, self-contained snapshot-testing utility (no external dependency).
//  Renders a view controller (or view) to a deterministic PNG and compares it
//  against a committed reference image under `LuneTests/ReferenceImages/`, with a
//  per-pixel tolerance for anti-aliasing differences.
//
//  Reference images are located via `#filePath` (the source tree is present on the
//  host running the simulator tests). On first run — or when `RECORD_SNAPSHOTS=1` is
//  set in the environment — the reference is (re)written and the assertion passes,
//  so a new snapshot test records its baseline, which you then commit.
//

import UIKit
import XCTest

/// Deterministic device-independent rendering + reference-image comparison.
enum SnapshotTesting {
    /// Whether to (re)record reference images instead of comparing. Set
    /// `RECORD_SNAPSHOTS=1` in the test scheme's environment to regenerate all.
    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "1"
    }

    /// A fixed render size (points) for a phone-portrait screen, so snapshots don't
    /// depend on the simulator's actual device size.
    static let phoneSize = CGSize(width: 393, height: 852)

    /// The directory holding committed reference PNGs, resolved from this file's path.
    static func referenceDirectory(file: StaticString = #filePath) -> URL {
        let thisFile = URL(fileURLWithPath: "\(file)")
        return thisFile.deletingLastPathComponent().appendingPathComponent("ReferenceImages")
    }

    /// Renders `viewController` hosted at `size` and asserts it matches its committed
    /// reference image (named `\(name).png`). Records the reference on first run /
    /// when recording. `precision` is the fraction of pixels allowed to differ
    /// beyond `pixelTolerance` (AA slack). Hosting in a window + laying out forces a
    /// real layout pass so frames are correct.
    static func assertSnapshot(
        of viewController: UIViewController,
        named name: String,
        size: CGSize = phoneSize,
        precision: Double = 0.02,
        pixelTolerance: Int = 24,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let image = render(viewController, size: size)
        compare(image, named: name, precision: precision, pixelTolerance: pixelTolerance,
                file: file, line: line)
    }

    /// Renders a standalone view (sized to `size`) and asserts against its reference.
    static func assertSnapshot(
        of view: UIView,
        named name: String,
        size: CGSize,
        precision: Double = 0.02,
        pixelTolerance: Int = 24,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutIfNeeded()
        let image = render(view, size: size)
        compare(image, named: name, precision: precision, pixelTolerance: pixelTolerance,
                file: file, line: line)
    }

    // MARK: - Rendering

    /// Hosts `viewController` in a key window at a fixed size, runs a layout pass,
    /// and rasterizes it. Uses a 1x scale + light interface style for determinism.
    static func render(_ viewController: UIViewController, size: CGSize) -> UIImage {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        viewController.view.frame = window.bounds
        viewController.view.setNeedsLayout()
        viewController.view.layoutIfNeeded()
        // Let any async-on-main layout settle (e.g. table reloads dispatched to main).
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        viewController.view.layoutIfNeeded()
        let image = rasterize(window, size: size)
        window.isHidden = true
        window.rootViewController = nil
        return image
    }

    static func render(_ view: UIView, size: CGSize) -> UIImage {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = .light
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        let image = rasterize(window, size: size)
        window.isHidden = true
        view.removeFromSuperview()
        return image
    }

    private static func rasterize(_ view: UIView, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        // `layer.render(in:)` rasterizes the layer tree synchronously without the
        // render server — `drawHierarchy(afterScreenUpdates:)` produces blank
        // captures for off-screen test windows on this runtime.
        return renderer.image { context in
            view.layer.render(in: context.cgContext)
        }
    }

    // MARK: - Comparison

    private static func compare(
        _ image: UIImage, named name: String,
        precision: Double, pixelTolerance: Int,
        file: StaticString, line: UInt
    ) {
        let dir = referenceDirectory(file: file)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let referenceURL = dir.appendingPathComponent("\(name).png")

        guard let pngData = image.pngData() else {
            XCTFail("Failed to encode snapshot '\(name)' to PNG", file: file, line: line)
            return
        }

        if isRecording || !FileManager.default.fileExists(atPath: referenceURL.path) {
            do {
                try pngData.write(to: referenceURL)
                if !isRecording {
                    // First-run recording: pass, but note that a baseline was written.
                    XCTContext.runActivity(named: "Recorded new snapshot '\(name)'") { _ in }
                } else {
                    XCTContext.runActivity(named: "Re-recorded snapshot '\(name)'") { _ in }
                }
            } catch {
                XCTFail("Failed to write reference '\(name)': \(error)", file: file, line: line)
            }
            return
        }

        guard let referenceData = try? Data(contentsOf: referenceURL),
              let referenceImage = UIImage(data: referenceData) else {
            XCTFail("Could not load reference image '\(name)'", file: file, line: line)
            return
        }

        if let failure = diff(image, referenceImage, precision: precision,
                              pixelTolerance: pixelTolerance) {
            // Save the actual render next to the reference for inspection.
            let actualURL = dir.appendingPathComponent("\(name).actual.png")
            try? pngData.write(to: actualURL)
            XCTFail("Snapshot '\(name)' did not match reference: \(failure). "
                    + "Actual saved to \(actualURL.lastPathComponent). "
                    + "Re-record with RECORD_SNAPSHOTS=1 if intended.",
                    file: file, line: line)
        }
    }

    /// Returns a failure description if the images differ beyond tolerance, else nil.
    private static func diff(
        _ a: UIImage, _ b: UIImage, precision: Double, pixelTolerance: Int
    ) -> String? {
        guard let ca = a.cgImage, let cb = b.cgImage else { return "missing CGImage" }
        if ca.width != cb.width || ca.height != cb.height {
            return "size \(ca.width)x\(ca.height) vs reference \(cb.width)x\(cb.height)"
        }
        let width = ca.width, height = ca.height
        guard let pa = pixelBytes(ca), let pb = pixelBytes(cb) else { return "could not read pixels" }
        let totalPixels = width * height
        var differing = 0
        var i = 0
        let count = pa.count
        while i + 3 < count {
            let dr = abs(Int(pa[i]) - Int(pb[i]))
            let dg = abs(Int(pa[i + 1]) - Int(pb[i + 1]))
            let db = abs(Int(pa[i + 2]) - Int(pb[i + 2]))
            if dr > pixelTolerance || dg > pixelTolerance || db > pixelTolerance {
                differing += 1
            }
            i += 4
        }
        let fraction = Double(differing) / Double(totalPixels)
        if fraction > precision {
            return String(format: "%.3f%% of pixels differ (tolerance %.3f%%)",
                          fraction * 100, precision * 100)
        }
        return nil
    }

    private static func pixelBytes(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &data, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }
}

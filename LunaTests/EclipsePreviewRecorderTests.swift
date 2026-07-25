//
//  EclipsePreviewRecorderTests.swift
//  LunaTests
//
//  Scratch previews for tuning the night-sky and eclipse rendering. Skipped
//  unless RECORD_ECLIPSE_PREVIEWS=1, and writes to ECLIPSE_PREVIEW_DIR.
//

import LunaDesignSystem
import UIKit
import XCTest

final class EclipsePreviewRecorderTests: XCTestCase {

    private var outputDirectory: URL {
        get throws {
            guard ProcessInfo.processInfo.environment["RECORD_ECLIPSE_PREVIEWS"] == "1",
                  let path = ProcessInfo.processInfo.environment["ECLIPSE_PREVIEW_DIR"]
            else { throw XCTSkip("Set RECORD_ECLIPSE_PREVIEWS=1 and ECLIPSE_PREVIEW_DIR.") }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true)
            return url
        }
    }

    private func write(_ image: UIImage, named name: String, to directory: URL) throws {
        let data = try XCTUnwrap(image.pngData())
        try data.write(to: directory.appendingPathComponent(name))
    }

    /// Renders `view` over black at 2x. `layer.render(in:)` rather than
    /// `drawHierarchy`, which produces nothing for an unattached window.
    private func render(_ view: UIView, style: UIUserInterfaceStyle = .dark) -> UIImage {
        view.overrideUserInterfaceStyle = style
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 2
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
            UITraitCollection(userInterfaceStyle: style).performAsCurrent {
                UIColor.black.setFill()
                context.fill(view.bounds)
                view.layer.render(in: context.cgContext)
            }
        }
    }

    func testRecordCorona() throws {
        let directory = try outputDirectory
        let body = CGSize(width: 300, height: 460)
        let canvas = UIView(frame: CGRect(x: 0, y: 0, width: 620, height: 780))
        canvas.backgroundColor = .black

        let corona = CardEclipseTransition.makeCorona(
            frame: CGRect(
                x: (canvas.bounds.width - body.width) / 2,
                y: (canvas.bounds.height - body.height) / 2,
                width: body.width, height: body.height))
        canvas.addSubview(corona)

        // The opaque moon that covers the sun at totality.
        let moon = UIView(frame: corona.frame)
        moon.backgroundColor = .black
        moon.layer.cornerRadius = 22
        moon.layer.cornerCurve = .continuous
        canvas.addSubview(moon)

        try write(render(canvas), named: "corona.png", to: directory)
    }

    func testRecordFlare() throws {
        let directory = try outputDirectory
        let flare = EclipseFlareView(frame: CGRect(x: 25, y: 25, width: 130, height: 130))
        let canvas = UIView(frame: CGRect(x: 0, y: 0, width: 180, height: 180))
        canvas.backgroundColor = .black
        canvas.addSubview(flare)
        try write(render(canvas), named: "flare.png", to: directory)
    }

    func testRecordInteriorCorona() throws {
        let directory = try outputDirectory
        let size = CGSize(width: 393, height: 600)
        let canvas = UIView(frame: CGRect(origin: .zero, size: size))
        canvas.backgroundColor = .black
        let interior = UIImageView(frame: canvas.bounds)
        interior.image = EclipseCorona.interiorImage(
            size: size, cornerRadius: 0, tint: .white)
        canvas.addSubview(interior)
        try write(render(canvas), named: "corona-interior.png", to: directory)
    }

    func testRecordStarfield() throws {
        let directory = try outputDirectory
        for (name, style) in [("dark", UIUserInterfaceStyle.dark), ("light", .light)] {
            let canvas = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 780))
            // Resolve explicitly: a detached view's layer caches whatever the
            // ambient trait collection was when the colour was assigned.
            canvas.backgroundColor = LunaColors.background.resolvedColor(
                with: UITraitCollection(userInterfaceStyle: style))
            let starfield = StarfieldView.install(behindContentsOf: canvas)
            starfield.overrideUserInterfaceStyle = style
            try write(
                render(canvas, style: style),
                named: "starfield-\(name).png", to: directory)
        }
    }
}

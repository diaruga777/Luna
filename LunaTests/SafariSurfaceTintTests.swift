//
//  SafariSurfaceTintTests.swift
//  LunaTests
//

import LunaDesignSystem
import UIKit
import XCTest

/// The colour every in-page Safari surface carries, and the one rule that
/// decides it: **a pill is coloured by the KIND it saves, app chrome by the APP.**
///
/// Those two rules agree everywhere it matters. A single-content app shows
/// exactly one kind of pill, so the Downloader's is always its amber and the
/// Price Tracker's always its green; the central Luna app is the only host that
/// shows all three, and each of its pills says which save it would make. The
/// setup confirmation is the other way round — it belongs to the app rather than
/// to any page — which is the whole reason `surface` rides the button context.
///
/// `content.js` hand-copies the four identity colours by VALUE (the extension
/// target links no package, the established `Shared*.swift` trade), so this
/// suite is what keeps the copy honest against `LunaSurfacePalette`.
@MainActor
final class SafariSurfaceTintTests: XCTestCase {

    private lazy var js = SafariJSTestHarness(self)
    private var didLoad = false

    private func evaluate(_ expression: String) -> String {
        if !didLoad {
            js.load(
                html: SafariJSTestHarness.blankPage,
                urlString: "https://example.com/",
                scripts: [SafariJSTestHarness.contentScript])
            didLoad = true
        }
        return js.string(expression) ?? ""
    }

    // MARK: - The hand-copy

    /// Every surface tint in `content.js` is its app's own identity colour.
    func testTheSurfaceTintsAreTheAppsOwnIdentityColours() {
        let expected: [(String, LunaSurfacePalette.Surface)] = [
            ("luna", .luna), ("reader", .reader),
            ("downloader", .downloader), ("pricetracker", .priceTracker),
        ]
        for (key, surface) in expected {
            let hex = evaluate("window.__lunaSurfaceTints[\(jsString(key))]")
            XCTAssertEqual(
                hex.lowercased(), Self.hexString(LunaSurfacePalette.baseColor(for: surface)),
                "content.js's SURFACE_TINTS.\(key) has drifted from "
                    + "LunaSurfacePalette.baseColor(for: .\(surface)) — the extension links no "
                    + "package, so this copy is the only thing keeping the two the same colour")
        }
    }

    /// And each kind's tint is the identity colour of the app that OWNS that
    /// kind, which is what makes the central app's per-save colouring legible:
    /// an orange pill means the Downloader would take this one.
    func testEachKindIsColouredByTheAppThatOwnsIt() {
        let expected: [(String, LunaSurfacePalette.Surface)] = [
            ("article", .reader), ("media", .downloader), ("product", .priceTracker),
        ]
        for (kind, surface) in expected {
            XCTAssertEqual(
                evaluate("window.__lunaKindTints[\(jsString(kind))]").lowercased(),
                Self.hexString(LunaSurfacePalette.baseColor(for: surface)),
                "content.js's KIND_TINTS.\(kind) is not the \(surface) app's colour")
        }
    }

    /// The text colour is a FUNCTION of the fill, in both languages, because the
    /// four identity colours span nearly the whole brightness range — a fixed
    /// white would be unreadable on the Price Tracker's near-neon green and the
    /// Reader's pale periwinkle.
    func testTheTextColourIsPickedTheSameWayInBothLanguages() {
        let cases: [(String, LunaSurfacePalette.Surface)] = [
            ("luna", .luna), ("reader", .reader),
            ("downloader", .downloader), ("pricetracker", .priceTracker),
        ]
        for (key, surface) in cases {
            let fromJS = evaluate(
                "window.__lunaTintForeground(window.__lunaSurfaceTints[\(jsString(key))])")
            let fromSwift = Self.hexString(
                LunaSurfacePalette.ink(on: LunaSurfacePalette.baseColor(for: surface)))
            XCTAssertEqual(
                fromJS.lowercased(), fromSwift,
                "tintForeground disagrees with LunaSurfacePalette.ink(on:) for \(surface)")
        }
    }

    /// Whichever side wins, it wins by enough to read: 4.5:1 is WCAG AA for body
    /// text, and a pill's label is body text on someone else's web page.
    func testEveryTintCarriesLegibleText() {
        for surface in [LunaSurfacePalette.Surface.luna, .reader, .downloader, .priceTracker] {
            let fill = LunaSurfacePalette.baseColor(for: surface)
            let ink = LunaSurfacePalette.ink(on: fill)
            let lighter = max(
                LunaSurfacePalette.relativeLuminance(of: fill),
                LunaSurfacePalette.relativeLuminance(of: ink))
            let darker = min(
                LunaSurfacePalette.relativeLuminance(of: fill),
                LunaSurfacePalette.relativeLuminance(of: ink))
            XCTAssertGreaterThanOrEqual(
                (lighter + 0.05) / (darker + 0.05), 4.5,
                "\(surface)'s pill text is below AA contrast on its own fill")
        }
    }

    // MARK: - What the pills actually render

    /// The whole point, end to end: the pill a page earns is filled with its
    /// kind's colour. Driven through the real target factories rather than a
    /// hand-built style, so a target that forgets its tint fails here.
    func testEachPillRendersItsKindsTint() {
        for (kind, factory) in [
            ("article", "window.__lunaReadTarget"),
            ("media", "window.__lunaDownloadTarget"),
            ("product", "window.__lunaTrackTarget"),
        ] {
            let rendered = evaluate("""
                (function () {
                    var pill = document.getElementById(window.__lunaPillID);
                    if (pill) { pill.parentNode.removeChild(pill); }
                    window.__lunaInjectLunaButton(\(factory)({
                        scheme: "luna", surface: "luna", supportsArticles: true,
                        supportsMedia: true, supportsProducts: true }));
                    return document.getElementById(window.__lunaPillID)
                        .getAttribute("data-luna-tint");
                })()
                """)
            XCTAssertEqual(
                rendered.lowercased(),
                evaluate("window.__lunaKindTints[\(jsString(kind))]").lowercased(),
                "the \(kind) pill did not render its kind's tint")
        }
    }

    /// A pill whose fill is its kind's colour must not also be white-on-pale:
    /// the rendered text colour is the one the fill asks for.
    func testTheCircularControlUsesAdaptiveMonochromeInk() {
        let ink = evaluate("""
            (function () {
                var pill = document.getElementById(window.__lunaPillID);
                if (pill) { pill.parentNode.removeChild(pill); }
                window.__lunaInjectLunaButton(
                    window.__lunaTrackTarget({ scheme: "lunapricetracker",
                        surface: "pricetracker", supportsProducts: true }));
                return getComputedStyle(document.getElementById(window.__lunaPillID)).color;
            })()
            """)
        let dark = evaluate("String(window.matchMedia('(prefers-color-scheme: dark)').matches)") == "true"
        XCTAssertEqual(ink.contains("255, 255, 255"), dark,
                       "the action icon should adapt to the current light/dark theme")
    }

    func testPriceTrackerPillStaysInTheApp() {
        let target = evaluate("""
            window.__lunaTrackTarget({ scheme: "lunapricetracker",
                surface: "pricetracker", supportsProducts: true }).url()
            """)
        XCTAssertTrue(target.hasPrefix("lunapricetracker://read?url="))
        XCTAssertFalse(target.contains("ret=safari"))
    }

    // MARK: - App chrome takes the surface, not the kind

    /// The setup confirmation is the app saying hello, on a page it was sent to
    /// only to prove it can run there — frequently a page that would earn no
    /// pill at all. So it is coloured by `surface`, and each app's is different.
    func testTheSetupConfirmationIsColouredByTheApp() {
        var washes: Set<String> = []
        for surface in ["luna", "reader", "downloader", "pricetracker"] {
            let wash = evaluate("""
                (function () {
                    var existing = document.getElementById(window.__lunaSetupCelebrationID);
                    if (existing) { existing.parentNode.removeChild(existing); }
                    window.__lunaPresentSetupCelebration(
                        { scheme: "luna", surface: \(jsString(surface)), appName: "Luna" },
                        function () {});
                    return getComputedStyle(
                        document.getElementById(window.__lunaSetupCelebrationID)).backgroundColor;
                })()
                """)
            XCTAssertTrue(
                wash.contains("rgba") || wash.contains("0.85"),
                "the confirmation must stay semi-transparent over the page it proves, got \(wash)")
            washes.insert(wash)
        }
        XCTAssertEqual(
            washes.count, 4,
            "all four apps confirm setup in the same colour — `surface` is not reaching the wash")
    }

    /// `surface` is no use to the page unless the native side sends it and the
    /// background relay passes it through. Three files, three processes.
    func testTheSurfaceIsRelayedEndToEnd() {
        let handler = SafariJSTestHarness.source("LunaSafari/SafariWebExtensionHandler.swift")
        let background = SafariJSTestHarness.source("LunaSafari/Resources/background.js")
        XCTAssertTrue(
            handler.contains(#"payload["surface"] = surface"#),
            "the native handler no longer answers with its surface")
        XCTAssertTrue(
            background.contains("surface: (resp && resp.surface)"),
            "background.js drops `surface` — a content script can't reach the handler itself")
    }

    // MARK: - Harness

    private func jsString(_ value: String) -> String { SafariJSTestHarness.jsString(value) }

    /// `#rrggbb`, lowercased — the form `content.js` writes its table in.
    private static func hexString(_ color: UIColor) -> String {
        let resolved = color.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: .dark))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(
            format: "#%02x%02x%02x",
            Int((red * 255).rounded()), Int((green * 255).rounded()),
            Int((blue * 255).rounded()))
    }
}

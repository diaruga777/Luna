//
//  OnboardingSurfaceConfiguration.swift
//  Luna
//

import LunaModels

enum OnboardingDemoPage: CaseIterable, Equatable {
    case lunaArticle
    case instaTok
    case amayzon

    var resourceName: String? {
        switch self {
        case .lunaArticle: return nil
        case .instaTok: return "InstaTok"
        case .amayzon: return "Amayzon"
        }
    }

    var displayedHost: String {
        switch self {
        case .lunaArticle: return "luna.app"
        case .instaTok: return "instatok.local"
        case .amayzon: return "amayzon.local"
        }
    }

    /// One canonical mock URL is shared by Safari's address field and the
    /// latest incoming Messages bubble during the onboarding loop.
    var sharedURLString: String {
        switch self {
        case .lunaArticle: return "https://luna.app/about"
        case .instaTok: return "https://instatok.local/@moonwatch/lunar-eclipse"
        case .amayzon: return "https://amayzon.local/eyephone-air"
        }
    }
}

/// How an app's headline is staged. Both shapes take exactly two beats of the
/// same lunar sweep, so the journey's timing is identical either way.
enum OnboardingIntroCopy: Equatable {
    /// Two sentences, each swept in whole, the second under the first.
    case twoLines(first: String, second: String)
    /// One sentence that grows. The first beat brings in `stem` with a period
    /// of its own; the second adds `tail` while that period sweeps back out.
    /// `stem` is laid out where it sits in the FINISHED sentence, so the beat
    /// between them moves nothing.
    case growingLine(stem: String, tail: String)
}

/// The animation and setup journey are shared. Only copy, demo content, final
/// save plumbing, and Action Button evidence vary by host app.
struct OnboardingSurfaceConfiguration {
    let app: LunaApp
    let introCopy: OnboardingIntroCopy
    let supportingText: String
    let saveBenefit: String
    let demoPages: [OnboardingDemoPage]
    let seedTitle: String
    let seedSymbol: String

    var isCentralApp: Bool { app == .luna }

    static var current: Self {
        configuration(for: .current)
    }

    static func configuration(for app: LunaApp) -> Self {
        switch app {
        case .reader:
            return Self(
                app: app,
                introCopy: .growingLine(stem: "Read", tail: " more."),
                supportingText:
                    "Save onscreen links with one click.\nUnlock or read offline later.",
                saveBenefit: "Read offline later",
                demoPages: [.lunaArticle],
                seedTitle: "Save anything in Safari",
                seedSymbol: "safari.fill")
        case .downloader:
            return Self(
                app: app,
                introCopy: .twoLines(
                    first: "App signup required? So annoying.",
                    second: "Watch and share instantly instead."),
                supportingText:
                    "Download any video link in one click,\nno signup required.",
                saveBenefit: "Watch or share",
                demoPages: [.instaTok],
                seedTitle: "InstaTok",
                seedSymbol: "play.rectangle.fill")
        case .priceTracker:
            return Self(
                app: app,
                introCopy: .twoLines(
                    first: "Overpaid? Missed a sale?",
                    second: "Never miss out again."),
                supportingText:
                    "Track sales for any link\nin one click.",
                saveBenefit: "Never miss a sale",
                demoPages: [.amayzon],
                seedTitle: "eyePhone",
                seedSymbol: "tag.fill")
        case .luna:
            return Self(
                app: app,
                introCopy: .twoLines(
                    first: "All your Luna saves.",
                    second: "In a single app."),
                supportingText:
                    "Save any link on your screen\nwith one click.",
                saveBenefit: "Read, watch, track, anything",
                demoPages: OnboardingDemoPage.allCases,
                seedTitle: "Anything",
                seedSymbol: "moon.stars.fill")
        }
    }
}

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

/// The animation and setup journey are shared. Only copy, demo content, final
/// save plumbing, and Action Button evidence vary by host app.
struct OnboardingSurfaceConfiguration {
    let app: LunaApp
    let firstLine: String
    let secondLine: String
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
                firstLine: "You want to read more.",
                secondLine: "Let’s make that happen.",
                supportingText:
                    "Save onscreen links with one click.\nUnlock or read offline later.",
                saveBenefit: "Read offline later",
                demoPages: [.lunaArticle],
                seedTitle: "Save anything in Safari",
                seedSymbol: "safari.fill")
        case .downloader:
            return Self(
                app: app,
                firstLine: "App signup required? So annoying.",
                secondLine: "Watch and share instantly instead.",
                supportingText:
                    "Download any video link in one click,\nno signup required.",
                saveBenefit: "Watch or share",
                demoPages: [.instaTok],
                seedTitle: "InstaTok",
                seedSymbol: "play.rectangle.fill")
        case .priceTracker:
            return Self(
                app: app,
                firstLine: "Overpaid? Missed a sale?",
                secondLine: "Never miss out again.",
                supportingText:
                    "Track sales for any link\nin one click.",
                saveBenefit: "Never miss a sale",
                demoPages: [.amayzon],
                seedTitle: "eyePhone",
                seedSymbol: "tag.fill")
        case .luna:
            return Self(
                app: app,
                firstLine: "All your Luna saves.",
                secondLine: "In a single app.",
                supportingText:
                    "Save any link on your screen\nwith one click.",
                saveBenefit: "Read, watch, track, anything",
                demoPages: OnboardingDemoPage.allCases,
                seedTitle: "Anything",
                seedSymbol: "moon.stars.fill")
        }
    }
}

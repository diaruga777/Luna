//
//  OnboardingSurfaceConfiguration.swift
//  Luna
//

import LunaModels

enum OnboardingDemoPage: CaseIterable, Equatable {
    case wikipedia
    case instaTok
    case amayzon

    var resourceName: String {
        switch self {
        case .wikipedia: return "LunaWikipedia"
        case .instaTok: return "InstaTok"
        case .amayzon: return "Amayzon"
        }
    }

    var displayedHost: String {
        switch self {
        case .wikipedia: return "en.wikipedia.org"
        case .instaTok: return "instatok.local"
        case .amayzon: return "amayzon.local"
        }
    }
}

/// The animation and setup journey are shared. Only copy, demo content, final
/// save plumbing, and Action Button evidence vary by host app.
struct OnboardingSurfaceConfiguration {
    let app: LunaApp
    let firstLine: String
    let secondLine: String
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
                saveBenefit: "Read offline later",
                demoPages: [.wikipedia],
                seedTitle: "Luna",
                seedSymbol: "safari.fill")
        case .downloader:
            return Self(
                app: app,
                firstLine: "App signup required? So annoying.",
                secondLine: "Watch and share instantly instead.",
                saveBenefit: "Watch or share",
                demoPages: [.instaTok],
                seedTitle: "InstaTok",
                seedSymbol: "play.rectangle.fill")
        case .priceTracker:
            return Self(
                app: app,
                firstLine: "Overpaid? Missed a sale?",
                secondLine: "Never miss out again.",
                saveBenefit: "Never miss a sale",
                demoPages: [.amayzon],
                seedTitle: "eyePhone",
                seedSymbol: "tag.fill")
        case .luna:
            return Self(
                app: app,
                firstLine: "All your Luna saves.",
                secondLine: "In a single app.",
                saveBenefit: "Read, watch, track, anything",
                demoPages: OnboardingDemoPage.allCases,
                seedTitle: "Anything",
                seedSymbol: "moon.stars.fill")
        }
    }
}

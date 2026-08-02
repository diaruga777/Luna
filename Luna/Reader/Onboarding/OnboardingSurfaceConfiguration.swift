//
//  OnboardingSurfaceConfiguration.swift
//  Luna
//

import LunaModels

enum OnboardingDemoPage: CaseIterable, Equatable {
    case lunaPage
    case instaTok
    case amayzon

    var resourceName: String? {
        switch self {
        case .lunaPage: return nil
        case .instaTok: return OnboardingStrings.Demo.instaTokResourceName.value()
        case .amayzon: return OnboardingStrings.Demo.amayzonResourceName.value()
        }
    }

    var displayedHost: String {
        switch self {
        case .lunaPage: return OnboardingStrings.Demo.lunaHost.value()
        case .instaTok: return OnboardingStrings.Demo.instaTokHost.value()
        case .amayzon: return OnboardingStrings.Demo.amayzonHost.value()
        }
    }

    /// One canonical mock URL is shared by Safari's address field and the
    /// latest incoming Messages bubble during the onboarding loop.
    var sharedURLString: String {
        switch self {
        case .lunaPage: return OnboardingStrings.Demo.lunaURL.value()
        case .instaTok: return OnboardingStrings.Demo.instaTokURL.value()
        case .amayzon: return OnboardingStrings.Demo.amayzonURL.value()
        }
    }
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
                introCopy: OnboardingStrings.introCopy(for: app),
                supportingText: OnboardingStrings.Intro.supportingText.value(for: app),
                saveBenefit: OnboardingStrings.Intro.saveBenefit.value(for: app),
                demoPages: [.lunaPage],
                seedTitle: OnboardingStrings.Demo.readerSeedTitle.value(),
                seedSymbol: "safari.fill")
        case .downloader:
            return Self(
                app: app,
                introCopy: OnboardingStrings.introCopy(for: app),
                supportingText: OnboardingStrings.Intro.supportingText.value(for: app),
                saveBenefit: OnboardingStrings.Intro.saveBenefit.value(for: app),
                demoPages: [.instaTok],
                seedTitle: OnboardingStrings.Demo.instaTokSeedTitle.value(),
                seedSymbol: "play.rectangle.fill")
        case .priceTracker:
            return Self(
                app: app,
                introCopy: OnboardingStrings.introCopy(for: app),
                supportingText: OnboardingStrings.Intro.supportingText.value(for: app),
                saveBenefit: OnboardingStrings.Intro.saveBenefit.value(for: app),
                demoPages: [.amayzon],
                seedTitle: OnboardingStrings.Demo.amayzonSeedTitle.value(),
                seedSymbol: "tag.fill")
        case .luna:
            return Self(
                app: app,
                introCopy: OnboardingStrings.introCopy(for: app),
                supportingText: OnboardingStrings.Intro.supportingText.value(for: app),
                saveBenefit: OnboardingStrings.Intro.saveBenefit.value(for: app),
                demoPages: OnboardingDemoPage.allCases,
                seedTitle: OnboardingStrings.Demo.lunaSeedTitle.value(),
                seedSymbol: "moon.stars.fill")
        }
    }
}

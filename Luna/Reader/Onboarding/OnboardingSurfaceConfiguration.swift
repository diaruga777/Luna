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
    let saveSetupMode: OnboardingSaveSetupMode
    let introCopy: OnboardingIntroCopy
    let saveBenefit: String
    let demoPages: [OnboardingDemoPage]
    /// The link the SAVE lesson rehearses with when there is no live Save of
    /// the Week to use instead (`OnboardingSaveDemoLink`).
    ///
    /// Declared per app rather than read off `demoPages`, which is what it used
    /// to be: every app's Safari lesson now opens on the native explainer page,
    /// so the browser's first page is `.lunaPage` everywhere and deriving the
    /// practice link from it would have handed Luna Downloader an ARTICLE to
    /// rehearse a media save with.
    let practiceURLString: String
    let seedTitle: String
    let seedSymbol: String

    var isCentralApp: Bool { app == .luna }

    static var current: Self {
        configuration(for: .current)
    }

    static func configuration(
        for app: LunaApp,
        saveSetupMode: OnboardingSaveSetupMode = .current
    ) -> Self {
        switch app {
        case .reader:
            return Self(
                app: app,
                saveSetupMode: saveSetupMode,
                introCopy: OnboardingStrings.introCopy(for: app),
                saveBenefit: OnboardingStrings.Intro.saveBenefit.value(for: app),
                demoPages: [.lunaPage],
                practiceURLString: ShareSetupPractice.lunaURLString,
                seedTitle: OnboardingStrings.Demo.readerSeedTitle.value(),
                seedSymbol: "safari.fill")
        case .downloader:
            return Self(
                app: app,
                saveSetupMode: saveSetupMode,
                introCopy: OnboardingStrings.introCopy(for: app),
                saveBenefit: OnboardingStrings.Intro.saveBenefit.value(for: app),
                demoPages: [.lunaPage, .instaTok],
                practiceURLString: ShareSetupPractice.instaTokURLString,
                seedTitle: OnboardingStrings.Demo.instaTokSeedTitle.value(),
                seedSymbol: "play.rectangle.fill")
        case .priceTracker:
            return Self(
                app: app,
                saveSetupMode: saveSetupMode,
                introCopy: OnboardingStrings.introCopy(for: app),
                saveBenefit: OnboardingStrings.Intro.saveBenefit.value(for: app),
                demoPages: [.lunaPage, .amayzon],
                practiceURLString: ShareSetupPractice.amayzonURLString,
                seedTitle: OnboardingStrings.Demo.amayzonSeedTitle.value(),
                seedSymbol: "tag.fill")
        case .luna:
            return Self(
                app: app,
                saveSetupMode: saveSetupMode,
                introCopy: OnboardingStrings.introCopy(for: app),
                saveBenefit: OnboardingStrings.Intro.saveBenefit.value(for: app),
                demoPages: OnboardingDemoPage.allCases,
                practiceURLString: ShareSetupPractice.lunaURLString,
                seedTitle: OnboardingStrings.Demo.lunaSeedTitle.value(),
                seedSymbol: "moon.stars.fill")
        }
    }
}

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

/// What an app's Safari lesson demonstrates before it asks for the setup.
///
/// Both lessons end in the same place — the three enable steps and the Activate
/// Safari / Skip pair — and differ only in what they show first.
enum OnboardingSafariLesson: Equatable {
    /// The native `luna.app` explainer, buried under ads, popups and a
    /// subscription wall until the mock extension flip clears them. Its own
    /// page carries the setup call to action at the foot of its copy.
    case extensionExplainer
    /// The kind of page the extension is FOR, with the extension's own answer
    /// running on it: the alternative-seller pill looks for a better price,
    /// finds one, and the screen closes down to it before the setup card
    /// arrives (`OnboardingPriceComparisonOverlayView`).
    case priceComparison
}

/// The animation and setup journey are shared. Only copy, demo content, final
/// save plumbing, and Action Button evidence vary by host app.
struct OnboardingSurfaceConfiguration {
    let app: LunaApp
    let saveSetupMode: OnboardingSaveSetupMode
    let introCopy: OnboardingIntroCopy
    let saveBenefit: String
    let demoPages: [OnboardingDemoPage]
    /// What this app's Safari lesson plays. A `.priceComparison` app opens the
    /// browser straight on its own product page rather than on the explainer,
    /// so its `demoPages` must lead with that page.
    let safariLesson: OnboardingSafariLesson
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
                safariLesson: .extensionExplainer,
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
                safariLesson: .extensionExplainer,
                practiceURLString: ShareSetupPractice.instaTokURLString,
                seedTitle: OnboardingStrings.Demo.instaTokSeedTitle.value(),
                seedSymbol: "play.rectangle.fill")
        case .priceTracker:
            return Self(
                app: app,
                saveSetupMode: saveSetupMode,
                introCopy: OnboardingStrings.introCopy(for: app),
                saveBenefit: OnboardingStrings.Intro.saveBenefit.value(for: app),
                // No explainer page: the lesson is the product page itself,
                // with the extension's seller pill answering on it.
                demoPages: [.amayzon],
                safariLesson: .priceComparison,
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
                safariLesson: .extensionExplainer,
                practiceURLString: ShareSetupPractice.lunaURLString,
                seedTitle: OnboardingStrings.Demo.lunaSeedTitle.value(),
                seedSymbol: "moon.stars.fill")
        }
    }
}

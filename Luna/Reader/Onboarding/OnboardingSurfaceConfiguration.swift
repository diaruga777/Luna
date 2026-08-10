//
//  OnboardingSurfaceConfiguration.swift
//  Luna
//

import LunaModels
import LunaStorage

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
enum OnboardingSafariLesson: Equatable {
    case extensionExplainer
    case priceComparison
    case videoDownload
}

/// The animation and setup journey are shared. `app` is the host identity;
/// `demonstrationApp` is the feature family whose lesson is currently shown.
struct OnboardingSurfaceConfiguration {
    let app: LunaApp
    let demonstrationApp: LunaApp
    let saveSetupMode: OnboardingSaveSetupMode
    let introCopy: OnboardingIntroCopy
    let saveBenefit: String
    let demoPages: [OnboardingDemoPage]
    let safariLesson: OnboardingSafariLesson
    let practiceURLString: String
    let seedTitle: String
    let seedSymbol: String

    var isCentralApp: Bool { app == .luna }

    /// Central Luna starts with the first missing sibling, then rotates through
    /// the ranking from that sibling onward. Faceted apps have one lesson.
    var safariDemonstrationApps: [LunaApp] {
        guard isCentralApp else { return [demonstrationApp] }
        let ranked = LunaApp.onboardingRankedSiblings
        guard let start = ranked.firstIndex(of: demonstrationApp) else { return ranked }
        return Array(ranked[start...]) + Array(ranked[..<start])
    }

    static var current: Self { configuration(for: .current) }

    static func configuration(
        for app: LunaApp,
        saveSetupMode: OnboardingSaveSetupMode = .current,
        demonstrationApp requestedDemonstrationApp: LunaApp? = nil
    ) -> Self {
        let demonstrationApp = app == .luna
            ? (requestedDemonstrationApp ?? highestRankedUninstalledSibling())
            : app
        let lesson = lessonValues(for: demonstrationApp)
        return Self(
            app: app,
            demonstrationApp: demonstrationApp,
            saveSetupMode: saveSetupMode,
            introCopy: OnboardingStrings.introCopy(for: app),
            saveBenefit: OnboardingStrings.Intro.saveBenefit.value(for: app),
            demoPages: lesson.pages,
            safariLesson: lesson.safariLesson,
            practiceURLString: lesson.practiceURLString,
            seedTitle: lesson.seedTitle,
            seedSymbol: lesson.seedSymbol)
    }

    /// Injectable for tests so ranking does not require mutating App-Group
    /// defaults.
    static func highestRankedUninstalledSibling(
        wasInstalled: (LunaApp) -> Bool = {
            LunaInstallationMarkers.wasInstalled(surfaceIdentifier: $0.storageIdentifier)
        }
    ) -> LunaApp {
        LunaApp.onboardingRankedSiblings.first(where: { !wasInstalled($0) }) ?? .reader
    }

    private static func lessonValues(for app: LunaApp) -> (
        pages: [OnboardingDemoPage],
        safariLesson: OnboardingSafariLesson,
        practiceURLString: String,
        seedTitle: String,
        seedSymbol: String
    ) {
        switch app {
        case .reader:
            return (
                [.lunaPage], .extensionExplainer, ShareSetupPractice.lunaURLString,
                OnboardingStrings.Demo.readerSeedTitle.value(), "safari.fill")
        case .downloader:
            return (
                [.instaTok], .videoDownload, ShareSetupPractice.instaTokURLString,
                OnboardingStrings.Demo.instaTokSeedTitle.value(), "play.rectangle.fill")
        case .priceTracker:
            return (
                [.amayzon], .priceComparison, ShareSetupPractice.amayzonURLString,
                OnboardingStrings.Demo.amayzonSeedTitle.value(), "tag.fill")
        case .luna:
            return (
                OnboardingDemoPage.allCases, .extensionExplainer,
                ShareSetupPractice.lunaURLString,
                OnboardingStrings.Demo.lunaSeedTitle.value(), "moon.stars.fill")
        }
    }
}

//
//  OnboardingSafariExtensionCopy.swift
//  Luna
//

import Foundation

/// The ONE copy behind the mock `luna.app` page the Safari demonstration loads
/// buried and then cleans up. The page is not a fictional article: it is Luna's
/// own page about the Safari extension — what it does for you, and the three
/// steps that switch it on — with the extension's own call to action inlined at
/// the bottom of the content.
///
/// The steps listed here are the same three the mock enable pass performs, in
/// the same order, and each one's visual is drawn from the SAME artwork the
/// surface it points at uses (`SafariBottomBar.pageMenuSymbol`, the Manage
/// Extensions sheet's title, the app's real icon) so the page can never
/// describe chrome the demonstration doesn't show.
///
/// **The word "paywall" appears nowhere in Luna's own prose** — the pages ask
/// you to subscribe, so the copy calls them subscription walls.
enum OnboardingSafariExtensionCopy {
    static let title = "Read the page, not the popups"

    /// What Safari lists the extension as is the RUNNING APP's name — Luna,
    /// Luna Reader, Luna Downloader, Luna Price Tracker — so that is what the
    /// last enable step, the mock Manage Extensions sheet and this byline all
    /// say. The four hosts build the same extension SOURCE, but each target
    /// gives its copy its own bundle name
    /// (`INFOPLIST_KEY_CFBundleDisplayName = "$(DISPLAY_NAME_PREFIX) Reader"`
    /// and friends, in `project.pbxproj`), and Safari shows that. Do not take
    /// the name from `extensionName` in
    /// `LunaSafari/Resources/_locales/en/messages.json` — that string is one
    /// shared resource every target compiles identically, and the bundle name
    /// overrides it.
    static func byline(appName: String) -> String {
        "A Safari extension • by \(appName)"
    }

    /// Every claim, deliberately short. The page's one-screen budget leaves
    /// this paragraph about four rendered lines on the shortest phone Luna
    /// ships to, and `OnboardingSafariPageView` truncates it rather than let
    /// the actions slide under the browser chrome — so keep it inside that:
    /// `testSafariPageFitsTheShortestPhoneWithoutTruncatingItsProse` is the
    /// guard.
    static let explainer = "Ads, popups and subscription walls come off on "
        + "their own, privately, on your device. Anything you keep saves to "
        + "Luna in one tap."

    static let stepsHeading = "Turn it on in Safari"

    /// The Manage Extensions sheet's own title. Shared with the mock sheet the
    /// demonstration slides up, so the step and the sheet cannot drift apart.
    static let manageExtensionsTitle = "Manage Extensions"

    /// One enable step: the piece of Safari chrome it points at, and the line
    /// of copy beside it.
    struct Step {
        /// Which chrome the step's visual reproduces. The page draws each one
        /// from the real artwork rather than a stand-in symbol.
        enum Chrome {
            /// Safari's page menu, at the leading edge of the address field.
            case pageMenu
            /// The page menu's "Manage Extensions" row.
            case manageExtensions
            /// The app's own row in that sheet: its icon and its switch.
            case app
        }

        let chrome: Chrome
        let text: String
    }

    static func steps(appName: String) -> [Step] {
        [
            Step(chrome: .pageMenu, text: "Tap the page menu in the address bar"),
            Step(
                chrome: .manageExtensions,
                text: "Choose “\(manageExtensionsTitle)”"),
            Step(chrome: .app, text: "Switch on \(appName)"),
        ]
    }
}

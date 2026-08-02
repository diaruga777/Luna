//
//  OnboardingStrings.swift
//  Luna
//

import Foundation
import LunaModels

/// The single source of truth for every piece of onboarding copy.
///
/// A definition is either shared by all four Luna surfaces or explicitly
/// carries one value for the central Luna app and each standalone app. Keep
/// app-specific wording here even when two values currently happen to match:
/// changing copy should never require hunting through a view or a test.
enum OnboardingStrings {
    static func introCopy(for app: LunaApp) -> OnboardingIntroCopy {
        switch app {
        case .reader:
            return .growingLine(
                stem: Intro.headlineStem.value(for: app),
                tail: Intro.headlineTail.value(for: app))
        case .luna, .downloader, .priceTracker:
            return .twoLines(
                first: Intro.headlineStem.value(for: app),
                second: Intro.headlineTail.value(for: app))
        }
    }

    struct Definition: Equatable {
        private enum Values: Equatable {
            case shared(String)
            case perSurface(
                core: String,
                reader: String,
                downloader: String,
                priceTracker: String)
        }

        private let values: Values

        init(shared value: String) {
            values = .shared(value)
        }

        init(
            core: String,
            reader: String,
            downloader: String,
            priceTracker: String
        ) {
            values = .perSurface(
                core: core,
                reader: reader,
                downloader: downloader,
                priceTracker: priceTracker)
        }

        func value(for app: LunaApp = .current) -> String {
            switch values {
            case .shared(let value): return value
            case .perSurface(let core, let reader, let downloader, let priceTracker):
                switch app {
                case .luna: return core
                case .reader: return reader
                case .downloader: return downloader
                case .priceTracker: return priceTracker
                }
            }
        }
    }

    enum Intro {
        static let safariAction = Definition(shared: "Stop popups and paywalls")
        static let shortcutAction = Definition(shared: "Show me one click save")
        /// The paste row's placeholder, and the paste control's own label.
        static let paste = Definition(shared: "Paste a link")
        /// The seam between the two setup lessons and the paste row.
        static let orSeparator = Definition(shared: "or")
        static let articleURLsOnly = Definition(shared: "article URLs only")
        static let unableToLoadPage = Definition(shared: "unable to load page")
        static let completed = Definition(shared: "Completed")
        static let growingLinePeriod = Definition(shared: ".")

        static let headlineStem = Definition(
            core: "All your Luna saves.",
            reader: "Read",
            downloader: "App signup required? So annoying.",
            priceTracker: "Overpaid? Missed a sale?")
        static let headlineTail = Definition(
            core: "In a single app.",
            reader: " more.",
            downloader: "Watch and share instantly instead.",
            priceTracker: "Never miss out again.")
        static let supportingText = Definition(
            core: "Save any link on your screen\nwith one click.",
            reader: "Save onscreen links with one click.\nUnlock or read offline later.",
            downloader: "Download any video link in one click,\nno signup required.",
            priceTracker: "Track sales for any link\nin one click.")
        static let saveBenefit = Definition(
            core: "Read, watch, track, anything",
            reader: "Read offline later",
            downloader: "Watch or share",
            priceTracker: "Never miss a sale")
    }

    enum Demo {
        static let instaTokResourceName = Definition(shared: "InstaTok")
        static let amayzonResourceName = Definition(shared: "Amayzon")

        static let lunaHost = Definition(shared: "luna.app")
        static let instaTokHost = Definition(shared: "instatok.local")
        static let amayzonHost = Definition(shared: "amayzon.local")

        static let lunaURL = Definition(shared: "https://luna.app/about")
        static let instaTokURL = Definition(
            shared: "https://instatok.local/@moonwatch/lunar-eclipse")
        static let amayzonURL = Definition(
            shared: "https://amayzon.local/eyephone-air")

        static let lunaSeedTitle = Definition(shared: "Anything")
        static let readerSeedTitle = Definition(shared: "Save anything in Safari")
        static let instaTokSeedTitle = Definition(shared: "InstaTok")
        static let amayzonSeedTitle = Definition(shared: "eyePhone")

        // Text rendered by the bundled InstaTok page.
        static let instaTokBrand = Definition(shared: "InstaTok")
        static let instaTokHandle = Definition(shared: "@moonwatch")
        static let instaTokCaption = Definition(
            shared: "Earth’s shadow crossing the Moon 🌘 #eclipse #night")
        static let instaTokLikeCount = Definition(shared: "84K")
        static let instaTokCommentCount = Definition(shared: "912")
        static let instaTokShare = Definition(shared: "Share")
        static let instaTokSignupTitle = Definition(shared: "Sign up to keep watching")
        static let instaTokSignupBody = Definition(
            shared: "Create an account to see the full video, follow creators, and share with friends.")
        static let instaTokCreateAccount = Definition(shared: "Create account")
        static let instaTokLogin = Definition(shared: "Already have an account? Log in")

        // Text rendered by the bundled Amayzon page.
        static let amayzonHTMLTitle = Definition(shared: "eyePhone — amayzon")
        static let amayzonBrandPrefix = Definition(shared: "amay")
        static let amayzonBrandSuffix = Definition(shared: "zon")
        static let amayzonSearch = Definition(shared: "Search amayzon")
        static let amayzonNavigation = Definition(
            shared: "☰ &nbsp; Today’s Deals &nbsp;&nbsp; Best Sellers &nbsp;&nbsp; Devices &nbsp;&nbsp; Help")
        static let amayzonBreadcrumb = Definition(
            shared: "Electronics › Pocket communicators › Unlocked")
        static let amayzonRatingStars = Definition(shared: "★★★★☆")
        static let amayzonRatingCount = Definition(shared: "4,128 ratings")
        static let amayzonProductTitle = Definition(
            shared: "eyePhone Air — 256 GB, Moonmist, unlocked pocket communicator")
        static let amayzonStore = Definition(shared: "Visit the Pearless Devices Store")
        static let amayzonDeal = Definition(shared: "Limited time deal")
        static let amayzonCurrency = Definition(shared: "$")
        static let amayzonPriceMajor = Definition(shared: "799")
        static let amayzonPriceMinor = Definition(shared: "00")
        static let amayzonListPrice = Definition(shared: "List price: $999.00")
        static let amayzonStock = Definition(shared: "In stock")
        static let amayzonAddToBasket = Definition(shared: "Add to basket")

        /// Replaces the copy tokens in a bundled mock page. The HTML keeps its
        /// layout and artwork, while every rendered word comes from this file.
        static func renderedHTML(
            for page: OnboardingDemoPage,
            bundle: Bundle = .main
        ) -> String? {
            guard let resourceName = page.resourceName,
                  let url = bundle.url(forResource: resourceName, withExtension: "html"),
                  var html = try? String(contentsOf: url, encoding: .utf8)
            else { return nil }

            let replacements: [(String, String)]
            switch page {
            case .lunaPage:
                return nil
            case .instaTok:
                replacements = [
                    ("{{INSTADOMAIN_TITLE}}", instaTokBrand.value()),
                    ("{{INSTADOMAIN_BRAND}}", instaTokBrand.value()),
                    ("{{INSTADOMAIN_HANDLE}}", instaTokHandle.value()),
                    ("{{INSTADOMAIN_CAPTION}}", instaTokCaption.value()),
                    ("{{INSTADOMAIN_LIKES}}", instaTokLikeCount.value()),
                    ("{{INSTADOMAIN_COMMENTS}}", instaTokCommentCount.value()),
                    ("{{INSTADOMAIN_SHARE}}", instaTokShare.value()),
                    ("{{INSTADOMAIN_SIGNUP_TITLE}}", instaTokSignupTitle.value()),
                    ("{{INSTADOMAIN_SIGNUP_BODY}}", instaTokSignupBody.value()),
                    ("{{INSTADOMAIN_CREATE_ACCOUNT}}", instaTokCreateAccount.value()),
                    ("{{INSTADOMAIN_LOGIN}}", instaTokLogin.value()),
                ]
            case .amayzon:
                replacements = [
                    ("{{AMAYZON_HTML_TITLE}}", amayzonHTMLTitle.value()),
                    ("{{AMAYZON_BRAND_PREFIX}}", amayzonBrandPrefix.value()),
                    ("{{AMAYZON_BRAND_SUFFIX}}", amayzonBrandSuffix.value()),
                    ("{{AMAYZON_SEARCH}}", amayzonSearch.value()),
                    ("{{AMAYZON_NAVIGATION}}", amayzonNavigation.value()),
                    ("{{AMAYZON_BREADCRUMB}}", amayzonBreadcrumb.value()),
                    ("{{AMAYZON_RATING_STARS}}", amayzonRatingStars.value()),
                    ("{{AMAYZON_RATING_COUNT}}", amayzonRatingCount.value()),
                    ("{{AMAYZON_PRODUCT_TITLE}}", amayzonProductTitle.value()),
                    ("{{AMAYZON_STORE}}", amayzonStore.value()),
                    ("{{AMAYZON_DEAL}}", amayzonDeal.value()),
                    ("{{AMAYZON_CURRENCY}}", amayzonCurrency.value()),
                    ("{{AMAYZON_PRICE_MAJOR}}", amayzonPriceMajor.value()),
                    ("{{AMAYZON_PRICE_MINOR}}", amayzonPriceMinor.value()),
                    ("{{AMAYZON_LIST_PRICE}}", amayzonListPrice.value()),
                    ("{{AMAYZON_STOCK}}", amayzonStock.value()),
                    ("{{AMAYZON_ADD_TO_BASKET}}", amayzonAddToBasket.value()),
                ]
            }

            for (token, value) in replacements {
                html = html.replacingOccurrences(of: token, with: value)
            }
            return html
        }
    }

    enum Safari {
        static let title = Definition(shared: "Read the page, not the popups")
        static let bylineTemplate = Definition(shared: "A Safari extension • by %@")
        static let explainer = Definition(
            shared: "Ads, popups and subscription walls come off on their own, privately, on your device. Anything you keep saves to Luna in one tap.")
        static let stepsHeading = Definition(shared: "Turn it on in Safari")
        static let manageExtensionsTitle = Definition(shared: "Manage Extensions")
        static let pageMenuStep = Definition(shared: "Tap the page menu in the address bar")
        static let manageExtensionsStepTemplate = Definition(
            shared: "Choose “%@”")
        static let appStepTemplate = Definition(shared: "Switch on %@")
        static let activate = Definition(shared: "Activate Safari")
        static let skip = Definition(shared: "Skip")

        static let adSale = Definition(shared: "🔥 80% OFF EVERYTHING — TODAY ONLY 🔥")
        static let adTrick = Definition(shared: "You won't BELIEVE this one weird trick")
        static let adCruise = Definition(shared: "WIN A FREE CRUISE 🚢 TAP NOW")
        static let adDeals = Definition(shared: "HOT DEALS NEAR YOU ▸▸▸")

        static let newsletterTitle = Definition(shared: "Subscribe to our newsletter")
        static let newsletterSubtitle = Definition(shared: "We promise to spam you")
        static let newsletterEmail = Definition(shared: "you@example.com")
        static let newsletterSubmit = Definition(shared: "Subscribe")
        static let subscriptionTitle = Definition(shared: "Subscribe to keep reading")
        static let subscriptionBody = Definition(
            shared: "You've reached your free article limit for this month. Get unlimited access to independent journalism.")
        static let subscriptionSubmit = Definition(shared: "Subscribe for $4.99/month")
        static let subscriptionSignIn = Definition(shared: "Already a subscriber? Sign in")

        static func byline(appName: String) -> String {
            bylineTemplate.value().replacingOccurrences(of: "%@", with: appName)
        }

        static func steps(appName: String) -> [OnboardingSafariExtensionCopy.Step] {
            [
                .init(chrome: .pageMenu, text: pageMenuStep.value()),
                .init(
                    chrome: .manageExtensions,
                    text: manageExtensionsStepTemplate.value()
                        .replacingOccurrences(
                            of: "%@", with: manageExtensionsTitle.value())),
                .init(
                    chrome: .app,
                    text: appStepTemplate.value()
                        .replacingOccurrences(of: "%@", with: appName)),
            ]
        }
    }

    enum Messages {
        static let senderName = Definition(shared: "Johnny Appleseed")
        static let shortcutSetup = Definition(shared: "This saves on-screen links")
        static let greeting = Definition(shared: "Yoooooo")
        static let question = Definition(shared: "You use the Action Button at all?")
        static let answer = Definition(shared: "Nah. Its kinda dead tbh.")
        static let pitch = Definition(shared: "👀 watch this")
        static let settingsSetup = Definition(shared: "Just set your action button to it in")
        static let skipSetup = Definition(shared: "Or")

        static let shortcutPillTitle = Definition(shared: "Install Luna Shortcut")
        static let shortcutPillAccessibilityLabel = Definition(
            shared: "Install the Luna shortcut")
        static let settingsPillTitle = Definition(shared: "Settings")
        static let settingsPillAccessibilityLabel = Definition(shared: "Open Settings")
        static let skipPillTitle = Definition(shared: "skip setup")
        static let skipPillAccessibilityLabel = Definition(shared: "Skip setup")
    }

    enum Instruction {
        static let safariPromptTemplate = Definition(
            shared: "Press the Action Button to save\n%@")
        static let setUpSafari = Definition(shared: "Set up Safari")
        static let installShortcut = Definition(shared: "Install Shortcut")
        static let setActionButton = Definition(shared: "Set action button")
        static let actionButtonPrompt = Definition(
            shared: "Press the action button to finish")
        static let setUpLater = Definition(shared: "Set up later")
        static let externalOpenFailureTemplate = Definition(
            shared: "Couldn’t open %@. Try again.")
        static let saveFailure = Definition(shared: "Couldn’t create the offline example")
        static let tryAgain = Definition(shared: "Try again")
        static let done = Definition(shared: "Done")

        static func safariPrompt(saveBenefit: String) -> String {
            safariPromptTemplate.value().replacingOccurrences(of: "%@", with: saveBenefit)
        }

        static func externalOpenFailure(destination: String) -> String {
            externalOpenFailureTemplate.value()
                .replacingOccurrences(of: "%@", with: destination)
        }
    }

    enum Card {
        static let saved = Definition(shared: "Saved")
        static let savedArticle = Definition(shared: "Saved article")
    }

    enum Article {
        static let title = Definition(shared: "An article you want to read")
        static let byline = Definition(shared: "A safari extension • by Luna")
        static let intro = Definition(shared: "What you get, minus the pitch:")
        static let features = [
            Definition(shared: "Ads, popups and subscription walls: gone."),
            Definition(shared: "Saved offline, ready on any flight."),
            Definition(shared: "Speed-read a word at a time."),
            Definition(shared: "Read aloud with the screen off."),
            Definition(shared: "Open links without losing your place."),
            Definition(shared: "Send to Kindle, or export anywhere."),
            Definition(shared: "EPUB, PDF, Markdown or plain text."),
            Definition(shared: "Long X threads read like articles."),
            Definition(shared: "Newsletters pulled from your inbox."),
            Definition(shared: "Share a save straight to a friend."),
            Definition(shared: "Read-aloud rolls into the next piece."),
            Definition(shared: "Eye tracking pauses when you glance away."),
            Definition(shared: "Walled-off pages, readable again."),
            Definition(shared: "PDFs and documents, same reader."),
            Definition(shared: "A card deck, not another inbox."),
            Definition(shared: "The Action Button saves from anywhere."),
            Definition(shared: "One share-sheet save in every app."),
            Definition(shared: "Track a product's price while you wait."),
            Definition(shared: "Videos and audio, kept for the plane."),
            Definition(shared: "Everything on device, searchable offline."),
            Definition(shared: "No account. No feed. No streaks."),
            Definition(shared: "Night-sky dark, down to the last pixel."),
            Definition(shared: "Built to disappear while you read."),
        ]

        static var featureValues: [String] {
            features.map { $0.value() }
        }

        static var plainText: String {
            ([intro.value()] + featureValues.map { "• " + $0 })
                .joined(separator: "\n")
        }

        static var articleContent: ArticleContent {
            ArticleContent(
                title: title.value(),
                blocks: [block(kind: .paragraph, intro.value())]
                    + featureValues.map { block(kind: .listItem, $0) })
        }

        static var fallbackHTMLBody: String {
            "<h1>\(escaped(title.value()))</h1>\n"
                + "<p>\(escaped(intro.value()))</p>\n<ul>\n"
                + featureValues.map { "<li>\(escaped($0))</li>" }
                    .joined(separator: "\n")
                + "\n</ul>"
        }

        private static func block(
            kind: ArticleContent.Block.Kind,
            _ text: String
        ) -> ArticleContent.Block {
            .init(kind: kind, text: text, links: [])
        }

        private static func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
    }

    enum Accessibility {
        static let introIconCluster = Definition(shared: "onboarding.intro.iconCluster")
        static let introSupportingText = Definition(shared: "onboarding.intro.supportingText")
        static let introPaste = Definition(shared: "onboarding.intro.paste")
        static let introPasteField = Definition(shared: "onboarding.intro.pasteField")
        static let introOr = Definition(shared: "onboarding.intro.or")
        static let messagesReplica = Definition(shared: "onboarding.messages.replica")
        static let messagesDynamicIsland = Definition(shared: "onboarding.messages.dynamicIsland")
        static let messagesMockTap = Definition(shared: "onboarding.messages.mockTap")
        static let messagesExtensionSheet = Definition(shared: "onboarding.messages.extensionSheet")
        static let messagesAppSwitcher = Definition(shared: "onboarding.appSwitcher")
        static let messagesSenderName = Definition(shared: "onboarding.messages.senderName")
        static let messagesConversation = Definition(shared: "onboarding.messages.conversation")
        static let messagesLatestIncoming = Definition(shared: "onboarding.messages.latestIncoming")
        static let messagesLatestURL = Definition(shared: "onboarding.messages.latestURL")
        static let messagesShortcutSetup = Definition(shared: "onboarding.messages.shortcutSetup")
        static let messagesGreeting = Definition(shared: "onboarding.messages.greeting")
        static let messagesQuestion = Definition(shared: "onboarding.messages.question")
        static let messagesAnswer = Definition(shared: "onboarding.messages.answer")
        static let messagesPitch = Definition(shared: "onboarding.messages.pitch")
        static let messagesSettingsSetup = Definition(shared: "onboarding.messages.settingsSetup")
        static let messagesSkipSetup = Definition(shared: "onboarding.messages.skipSetup")
        static let messagesShortcutPill = Definition(shared: "onboarding.messages.shortcutPill")
        static let messagesSettingsPill = Definition(shared: "onboarding.messages.settingsPill")
        static let messagesSkipPill = Definition(shared: "onboarding.messages.skipPill")

        static let safariPage = Definition(shared: "onboarding.safari.lunaPage")
        static let safariAppIcon = Definition(shared: "onboarding.safari.page.appIcon")
        static let safariHeadline = Definition(shared: "onboarding.safari.page.headline")
        static let safariByline = Definition(shared: "onboarding.safari.page.byline")
        static let safariExplainer = Definition(shared: "onboarding.safari.page.explainer")
        static let safariStepsHeading = Definition(shared: "onboarding.safari.page.stepsHeading")
        static let safariActions = Definition(shared: "onboarding.safari.page.actions")
        static let safariActivate = Definition(shared: "onboarding.safari.page.activate")
        static let safariSkip = Definition(shared: "onboarding.safari.page.skip")
        static let safariClutter = Definition(shared: "onboarding.safari.page.clutter")
        static let safariAdPrefix = Definition(shared: "onboarding.safari.page.ad.")
        static let safariNewsletterPopup = Definition(shared: "onboarding.safari.page.newsletterPopup")
        static let safariNewsletterTitle = Definition(shared: "onboarding.safari.page.newsletterTitle")
        static let safariNewsletterSubtitle = Definition(shared: "onboarding.safari.page.newsletterSubtitle")
        static let safariNewsletterEmail = Definition(shared: "onboarding.safari.page.newsletterEmail")
        static let safariNewsletterSubmit = Definition(shared: "onboarding.safari.page.newsletterSubmit")
        static let safariSubscriptionSheet = Definition(shared: "onboarding.safari.page.subscriptionSheet")
        static let safariSubscriptionTitle = Definition(shared: "onboarding.safari.page.subscriptionTitle")
        static let safariSubscriptionBody = Definition(shared: "onboarding.safari.page.subscriptionBody")
        static let safariSubscriptionSubmit = Definition(shared: "onboarding.safari.page.subscriptionSubmit")
        static let safariSubscriptionSignIn = Definition(shared: "onboarding.safari.page.subscriptionSignIn")
        static let safariURLBar = Definition(shared: "onboarding.safari.urlBar")
        static let safariManageExtensionsSheet = Definition(shared: "onboarding.safari.manageExtensionsSheet")
        static let safariManageExtensionsToggle = Definition(shared: "onboarding.safari.manageExtensionsToggle")
        static let safariStepPrefix = Definition(shared: "onboarding.safari.page.step.")

        static func safariStep(_ index: Int) -> String {
            "\(safariStepPrefix.value())\(index)"
        }
    }

    enum AnimationKeys {
        static let messageBubbleFlight = Definition(shared: "onboarding.bubble.flight")
        static let pillPulse = Definition(shared: "onboarding.pill.pulse")
        /// The same breath as `pillPulse`, worn by the Safari page's own call
        /// to action. Its corona takes two curves, so it needs a second key.
        static let attentionPulse = Definition(shared: "onboarding.attention.pulse")
        static let attentionPulseScale = Definition(
            shared: "onboarding.attention.pulse.scale")
        static let ringFill = Definition(shared: "onboarding.ring.fill")
        static let switcherCorner = Definition(shared: "onboarding.switcher.corner")
        static let moonReveal = Definition(shared: "moonReveal")
        static let opaqueGlyphReveal = Definition(shared: "opaqueGlyphReveal")
    }
}

/// How an app's headline is staged. Both shapes take exactly two beats of the
/// same lunar sweep, so the journey's timing is identical either way.
enum OnboardingIntroCopy: Equatable {
    case twoLines(first: String, second: String)
    case growingLine(stem: String, tail: String)
}

/// Compatibility façade for the article surfaces. The values themselves live
/// above; these names keep the rendering code expressive without duplicating
/// any copy.
enum OnboardingLunaArticleCopy {
    static var title: String { OnboardingStrings.Article.title.value() }
    static var byline: String { OnboardingStrings.Article.byline.value() }
    static var intro: String { OnboardingStrings.Article.intro.value() }
    static var features: [String] { OnboardingStrings.Article.featureValues }
    static var plainText: String { OnboardingStrings.Article.plainText }
    static var articleContent: ArticleContent { OnboardingStrings.Article.articleContent }
    static var fallbackHTMLBody: String { OnboardingStrings.Article.fallbackHTMLBody }
}

/// Compatibility façade for the Safari explainer page. Its definitions live
/// in `OnboardingStrings.Safari`.
enum OnboardingSafariExtensionCopy {
    struct Step {
        enum Chrome {
            case pageMenu
            case manageExtensions
            case app
        }

        let chrome: Chrome
        let text: String
    }

    static var title: String { OnboardingStrings.Safari.title.value() }
    static func byline(appName: String) -> String {
        OnboardingStrings.Safari.byline(appName: appName)
    }
    static var explainer: String { OnboardingStrings.Safari.explainer.value() }
    static var stepsHeading: String { OnboardingStrings.Safari.stepsHeading.value() }
    static var manageExtensionsTitle: String {
        OnboardingStrings.Safari.manageExtensionsTitle.value()
    }

    static func steps(appName: String) -> [Step] {
        OnboardingStrings.Safari.steps(appName: appName).map {
            Step(chrome: $0.chrome, text: $0.text)
        }
    }
}

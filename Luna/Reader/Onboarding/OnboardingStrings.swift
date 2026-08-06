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
        OnboardingIntroCopy(
            initialText: Intro.headlineInitial.value(for: app),
            finalText: Intro.headlineFinal.value(for: app))
    }

    struct Definition: Equatable {
        private enum Storage: Equatable {
            case key(String)
            case literal(String)
        }

        private let storage: Storage

        init(key: String) {
            storage = .key(key)
        }

        /// A raw value carried through as-is, with no L10n lookup — for the
        /// `Accessibility`/`AnimationKeys` identifiers, which are UI-test and
        /// CALayer keys rather than user-facing copy and so are never
        /// localized (see those enums below).
        init(shared value: String) {
            storage = .literal(value)
        }

        func value(for app: LunaApp = .current) -> String {
            switch storage {
            case .key(let key): return L10n.string(key, for: app)
            case .literal(let value): return value
            }
        }
    }

    /// A definition whose value is an ORDERED LIST of chunks rather than one
    /// string — copy whose length is decided by the screen it lands on.
    ///
    /// `Definition` cannot carry this directly: one L10n key holds one string,
    /// not a list. Instead each app's chunks live at `"<keyPrefix>1"`,
    /// `"<keyPrefix>2"`, … and reading stops at the first missing index — which
    /// is also how apps with different chunk counts fall out naturally, with no
    /// Swift-side length to keep in sync. The rule the chunks encode is that
    /// every cumulative prefix (chunk 1, chunks 1–2, …) is itself publishable
    /// copy: each chunk ends on a sentence boundary that closes a sub-topic, so
    /// a screen that can only hold the first two never shows half an idea.
    struct ChunkedDefinition: Equatable {
        private let keyPrefix: String

        init(keyPrefix: String) {
            self.keyPrefix = keyPrefix
        }

        func value(for app: LunaApp = .current) -> [String] {
            var chunks: [String] = []
            var index = 1
            while let chunk = L10n.stringIfPresent("\(keyPrefix)\(index)", for: app) {
                chunks.append(chunk)
                index += 1
            }
            return chunks
        }
    }

    enum Intro {
        static let safariAction = Definition(key: "Onboarding_Intro_safariAction")
        static let shortcutAction = Definition(key: "Onboarding_Intro_shortcutAction")
        /// The util card's third, lowest-priority action: connect an account so
        /// the newsletters already in a mailbox arrive here as saves.
        static let emailAction = Definition(key: "Onboarding_Intro_emailAction")
        /// The paste row's placeholder, and the paste control's own label.
        static let paste = Definition(key: "Onboarding_Intro_paste")
        /// The seam between the two setup lessons and the paste row.
        static let orSeparator = Definition(key: "Onboarding_Intro_orSeparator")
        static let articleURLsOnly = Definition(key: "Onboarding_Intro_articleURLsOnly")
        static let unableToLoadPage = Definition(key: "Onboarding_Intro_unableToLoadPage")
        static let completed = Definition(key: "Onboarding_Intro_completed")

        /// The headline's two states. They are ONE sentence in two beats: what
        /// the two share is a single continuous run of characters that never
        /// moves, so write them as a claim being corrected rather than as two
        /// unrelated lines (`OnboardingHeadlineTransition` finds the run, and
        /// copy that shares nothing simply replaces itself outright).
        static let headlineInitial = Definition(key: "Onboarding_Intro_headline1Initial")
        static let headlineFinal = Definition(key: "Onboarding_Intro_headline2Final")
        static let saveBenefit = Definition(key: "Onboarding_Intro_saveBenefit")
    }

    enum Demo {
        static let instaTokResourceName = Definition(key: "Onboarding_Demo_instaTokResourceName")
        static let amayzonResourceName = Definition(key: "Onboarding_Demo_amayzonResourceName")

        static let lunaHost = Definition(key: "Onboarding_Demo_lunaHost")
        static let instaTokHost = Definition(key: "Onboarding_Demo_instaTokHost")
        static let amayzonHost = Definition(key: "Onboarding_Demo_amayzonHost")

        // Same URLs as `ShareSetupPractice.*URLString`, carried through the
        // Definition/L10n mechanism like every other value here even though
        // they are not translated per app.
        static let lunaURL = Definition(key: "Onboarding_Demo_lunaURL")
        static let instaTokURL = Definition(key: "Onboarding_Demo_instaTokURL")
        static let amayzonURL = Definition(key: "Onboarding_Demo_amayzonURL")

        static let lunaSeedTitle = Definition(key: "Onboarding_Demo_lunaSeedTitle")
        static let readerSeedTitle = Definition(key: "Onboarding_Demo_readerSeedTitle")
        static let instaTokSeedTitle = Definition(key: "Onboarding_Demo_instaTokSeedTitle")
        static let amayzonSeedTitle = Definition(key: "Onboarding_Demo_amayzonSeedTitle")

        // Text rendered by the bundled InstaTok page.
        static let instaTokBrand = Definition(key: "Onboarding_Demo_instaTokBrand")
        static let instaTokHandle = Definition(key: "Onboarding_Demo_instaTokHandle")
        static let instaTokCaption = Definition(key: "Onboarding_Demo_instaTokCaption")
        static let instaTokLikeCount = Definition(key: "Onboarding_Demo_instaTokLikeCount")
        static let instaTokCommentCount = Definition(key: "Onboarding_Demo_instaTokCommentCount")
        static let instaTokShare = Definition(key: "Common_share")
        static let instaTokSignupTitle = Definition(key: "Onboarding_Demo_instaTokSignupTitle")
        static let instaTokSignupBody = Definition(key: "Onboarding_Demo_instaTokSignupBody")
        static let instaTokCreateAccount = Definition(key: "Onboarding_Demo_instaTokCreateAccount")
        static let instaTokLogin = Definition(key: "Onboarding_Demo_instaTokLogin")

        // Text rendered by the bundled Amayzon page.
        static let amayzonHTMLTitle = Definition(key: "Onboarding_Demo_amayzonHTMLTitle")
        static let amayzonBrandPrefix = Definition(key: "Onboarding_Demo_amayzonBrandPrefix")
        static let amayzonBrandSuffix = Definition(key: "Onboarding_Demo_amayzonBrandSuffix")
        static let amayzonSearch = Definition(key: "Onboarding_Demo_amayzonSearch")
        static let amayzonNavigation = Definition(key: "Onboarding_Demo_amayzonNavigation")
        static let amayzonBreadcrumb = Definition(key: "Onboarding_Demo_amayzonBreadcrumb")
        static let amayzonRatingStars = Definition(key: "Onboarding_Demo_amayzonRatingStars")
        static let amayzonRatingCount = Definition(key: "Onboarding_Demo_amayzonRatingCount")
        static let amayzonProductTitle = Definition(key: "Onboarding_Demo_amayzonProductTitle")
        static let amayzonStore = Definition(key: "Onboarding_Demo_amayzonStore")
        static let amayzonDeal = Definition(key: "Onboarding_Demo_amayzonDeal")
        static let amayzonCurrency = Definition(key: "Onboarding_Demo_amayzonCurrency")
        static let amayzonPriceMajor = Definition(key: "Onboarding_Demo_amayzonPriceMajor")
        static let amayzonPriceMinor = Definition(key: "Onboarding_Demo_amayzonPriceMinor")
        static let amayzonListPrice = Definition(key: "Onboarding_Demo_amayzonListPrice")
        static let amayzonStock = Definition(key: "Onboarding_Demo_amayzonStock")
        static let amayzonAddToBasket = Definition(key: "Onboarding_Demo_amayzonAddToBasket")

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
        static let title = Definition(key: "Onboarding_Safari_title")
        static let bylineTemplate = Definition(key: "Onboarding_Safari_bylineTemplate")
        /// The page's prose, per app, in the order it reads — and it is only
        /// ever shown as a PREFIX of this list. The page's own header, steps and
        /// actions are fixed furniture, so what is left over between them is the
        /// only room the prose has; the page picks the longest prefix that fits
        /// (`OnboardingSafariPageView.fittedProse`). Chunk one therefore has to
        /// stand alone on the shortest phone Luna ships to, and every later
        /// chunk is depth a taller screen (or an iPad's wider column) can
        /// afford. Each ends on a sentence boundary that finishes its own
        /// sub-topic, so no prefix ever cuts an idea in half.
        static let explainerChunks = ChunkedDefinition(keyPrefix: "Onboarding_Safari_explainerChunk")
        static let stepsHeading = Definition(key: "Onboarding_Safari_stepsHeading")
        static let manageExtensionsTitle = Definition(key: "Onboarding_Safari_manageExtensionsTitle")
        static let pageMenuStep = Definition(key: "Onboarding_Safari_pageMenuStep")
        static let manageExtensionsStepTemplate = Definition(
            key: "Onboarding_Safari_manageExtensionsStepTemplate")
        static let appStepTemplate = Definition(key: "Onboarding_Safari_appStepTemplate")
        static let activate = Definition(key: "Onboarding_Safari_activate")
        static let skip = Definition(key: "Onboarding_Safari_skip")

        static let adSale = Definition(key: "Onboarding_Safari_adSale")
        static let adTrick = Definition(key: "Onboarding_Safari_adTrick")
        static let adCruise = Definition(key: "Onboarding_Safari_adCruise")
        static let adDeals = Definition(key: "Onboarding_Safari_adDeals")

        static let newsletterTitle = Definition(key: "Onboarding_Safari_newsletterTitle")
        static let newsletterSubtitle = Definition(key: "Onboarding_Safari_newsletterSubtitle")
        static let newsletterEmail = Definition(key: "Common_emailPlaceholderExample")
        static let newsletterSubmit = Definition(key: "Onboarding_Safari_newsletterSubmit")
        static let subscriptionTitle = Definition(key: "Onboarding_Safari_subscriptionTitle")
        static let subscriptionBody = Definition(key: "Onboarding_Safari_subscriptionBody")
        static let subscriptionSubmit = Definition(key: "Onboarding_Safari_subscriptionSubmit")
        static let subscriptionSignIn = Definition(key: "Onboarding_Safari_subscriptionSignIn")

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
        static let senderName = Definition(key: "Onboarding_Messages_senderName")
        static let shortcutSetup = Definition(key: "Onboarding_Messages_shortcutSetup")
        static let greeting = Definition(key: "Onboarding_Messages_greeting")
        static let question = Definition(key: "Onboarding_Messages_question")
        static let answer = Definition(key: "Onboarding_Messages_answer")
        static let pitch = Definition(key: "Onboarding_Messages_pitch")
        static let settingsSetup = Definition(key: "Onboarding_Messages_settingsSetup")
        static let skipSetup = Definition(key: "Onboarding_Messages_skipSetup")

        static let previousSetupAnswer = Definition(key: "Onboarding_Messages_previousSetupAnswer")
        static let facetedCoreOfferPrefix = Definition(key: "Onboarding_Messages_facetedCoreOfferPrefix")
        static let facetedCoreOfferSuffix = Definition(key: "Onboarding_Messages_facetedCoreOfferSuffix")
        static let centralCoreOffer = Definition(key: "Onboarding_Messages_centralCoreOffer")
        static let keepCurrentAppQuestion = Definition(key: "Onboarding_Messages_keepCurrentAppQuestion")
        static let chooseCurrentApp = Definition(key: "Onboarding_Messages_chooseCurrentApp")

        static func previousSetupQuestion(appName: String) -> String {
            L10n.string("Onboarding_Messages_previousSetupQuestionTemplate", appName)
        }

        static let shortcutPillTitle = Definition(key: "Onboarding_Messages_shortcutPillTitle")
        static let shortcutPillAccessibilityLabel = Definition(
            key: "Onboarding_Messages_shortcutPillAccessibilityLabel")
        static let coreAppPillAccessibilityLabel = Definition(
            key: "Onboarding_Messages_coreAppPillAccessibilityLabel")
        static let settingsPillTitle = Definition(key: "Common_settings")
        static let settingsPillAccessibilityLabel = Definition(key: "Common_openSettings")
        static let skipPillTitle = Definition(key: "Onboarding_Messages_skipPillTitle")
        static let skipPillAccessibilityLabel = Definition(key: "Onboarding_Messages_skipPillAccessibilityLabel")
    }

    enum Instruction {
        static let safariPromptTemplate = Definition(key: "Onboarding_Instruction_safariPromptTemplate")
        static let setUpSafari = Definition(key: "Onboarding_Instruction_setUpSafari")
        static let installShortcut = Definition(key: "Common_installShortcut")
        static let setActionButton = Definition(key: "Onboarding_Instruction_setActionButton")
        static let actionButtonPrompt = Definition(key: "Onboarding_Instruction_actionButtonPrompt")
        static let setUpLater = Definition(key: "Onboarding_Instruction_setUpLater")
        static let externalOpenFailureTemplate = Definition(
            key: "Onboarding_Instruction_externalOpenFailureTemplate")
        static let saveFailure = Definition(key: "Onboarding_Instruction_saveFailure")
        static let tryAgain = Definition(key: "Onboarding_Instruction_tryAgain")
        static let done = Definition(key: "Common_done")

        static func safariPrompt(saveBenefit: String) -> String {
            safariPromptTemplate.value().replacingOccurrences(of: "%@", with: saveBenefit)
        }

        static func externalOpenFailure(destination: String) -> String {
            externalOpenFailureTemplate.value()
                .replacingOccurrences(of: "%@", with: destination)
        }
    }

    enum Card {
        static let saved = Definition(key: "Common_saved")
        static let savedArticle = Definition(key: "Onboarding_Card_savedArticle")
    }

    enum Article {
        // Reuses ShareSetupPractice's own keys verbatim — this article is the
        // same share-sheet practice copy read back as a saved article, so it
        // carries no wording of its own.
        static let title = Definition(key: "ShareSetupPractice_articleSubjectLine")
        static let byline = Definition(key: "ShareSetupPractice_bylineExample")
        static let intro = Definition(key: "ShareSetupPractice_featuresHeading")
        static let features = [
            "ShareSetupPractice_feature01", "ShareSetupPractice_feature02",
            "ShareSetupPractice_feature03", "ShareSetupPractice_feature04",
            "ShareSetupPractice_feature05", "ShareSetupPractice_feature06",
            "ShareSetupPractice_feature07", "ShareSetupPractice_feature08",
            "ShareSetupPractice_feature09", "ShareSetupPractice_feature10",
            "ShareSetupPractice_feature11", "ShareSetupPractice_feature12",
            "ShareSetupPractice_feature13", "ShareSetupPractice_feature14",
            "ShareSetupPractice_feature15", "ShareSetupPractice_feature16",
            "ShareSetupPractice_feature17", "ShareSetupPractice_feature18",
            "ShareSetupPractice_feature19", "ShareSetupPractice_feature20",
            "ShareSetupPractice_feature21", "ShareSetupPractice_feature22",
            "ShareSetupPractice_feature23",
        ].map(Definition.init(key:))

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

    /// Words that belong to iOS rather than to Luna. The mock link menu and the
    /// mock share sheet replicate system surfaces, so they spell every label
    /// exactly as the OS does — and they are gathered here for the same reason
    /// all the other copy is: so a change is one edit, not a hunt through views.
    enum SystemUI {
        static let openLink = Definition(key: "Common_openLink")
        static let copy = Definition(key: "Onboarding_SystemUI_copy")
        static let share = Definition(key: "Onboarding_SystemUI_share")
        static let editActions = Definition(key: "Onboarding_SystemUI_editActions")
        static let favorites = Definition(key: "Onboarding_SystemUI_favorites")
        static let otherActions = Definition(key: "Onboarding_SystemUI_otherActions")
        static let saveToFiles = Definition(key: "Onboarding_SystemUI_saveToFiles")
        static let addToReadingList = Definition(key: "Onboarding_SystemUI_addToReadingList")
        static let airDrop = Definition(key: "Onboarding_SystemUI_airDrop")
        static let messages = Definition(key: "Onboarding_SystemUI_messages")
        static let reminders = Definition(key: "Onboarding_SystemUI_reminders")
        static let more = Definition(key: "Onboarding_SystemUI_more")
        /// The two share targets the sheet always has: this user's own Mac and
        /// somebody in Contacts.
        static let laptop = Definition(key: "Onboarding_SystemUI_laptop")
        static let contact = Definition(key: "Onboarding_SystemUI_contact")
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
        /// The visible front of the Action Button press wave.
        static let actionButtonPressWave = Definition(
            shared: "onboarding.press.wave")
        /// The lift a context menu's preview and menu cast while they are up.
        static let contextMenuShadow = Definition(
            shared: "onboarding.contextMenu.shadow")
        static let switcherCorner = Definition(shared: "onboarding.switcher.corner")
        static let moonReveal = Definition(shared: "moonReveal")
        static let opaqueGlyphReveal = Definition(shared: "opaqueGlyphReveal")
    }
}

/// An app's headline: what it says first, and what it settles on. Every app's
/// copy takes the same two beats of the same lunar sweep, and the difference
/// between the two states is what the second beat animates — see
/// `OnboardingHeadlineTransition`.
struct OnboardingIntroCopy: Equatable {
    let initialText: String
    let finalText: String
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
    /// What joins two chunks into a valid prefix. One space: the chunks are
    /// sentences of one paragraph, not paragraphs of their own.
    static let chunkSeparator = " "

    /// The page's prose in the order it reads. Only a PREFIX of this ever
    /// appears — see `OnboardingStrings.Safari.explainerChunks`.
    static func explainerChunks(for app: LunaApp = .current) -> [String] {
        OnboardingStrings.Safari.explainerChunks.value(for: app)
    }

    /// The cumulative join of the first `count` chunks — the only shape the
    /// page is ever allowed to display.
    static func explainerPrefix(_ count: Int, for app: LunaApp = .current) -> String {
        explainerChunks(for: app).prefix(max(count, 1))
            .joined(separator: chunkSeparator)
    }

    /// Every chunk joined: the longest prefix, and so the whole of the page's
    /// copy. Used where the text as a body of prose matters (copy audits, an
    /// iPad's column) rather than what fits a given screen.
    static func explainer(for app: LunaApp = .current) -> String {
        explainerPrefix(explainerChunks(for: app).count, for: app)
    }

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

//
//  ShareEntry+Luna.swift
//
//  The share extension's principal class. Info.plist names it `LunaShareEntry`.
//  Each host target compiles exactly one variant, chosen by a membership
//  exception on this shared folder.
//
//  It installs the kind packs this app handles, one call each. A kind's own
//  module defines what it registers — pipeline processors and extension
//  presenters together — once, and every surface (app, share extension, action
//  extension) installs the same pack. See `ArticleKindComposition`
//  and claudedocs/surface-support.md.
//
//  Never write `IngestKindProcessors` or `ShareKindPresenters` here directly.
//  Hand-listing them per surface let a kind register on some surfaces and not
//  others; `KindCompositionRootTests` fails the build if this file does that.
//

import LunaBundledPlugins
import LunaMediaDownload
import LunaModels
import LunaPluginIngest
import LunaPluginKit
import LunaPluginUI
import LunaPriceUI
import LunaReaderUI
import LunaDesignSystem
import LunaShareSurface
import LunaStorage
import UIKit

@objc(LunaShareEntry)
final class ShareEntry: ShareViewController {
    override init(nibName: String?, bundle: Bundle?) {
        ArticleKindComposition.install()
        MediaKindComposition.install()
        ProductKindComposition.install()
        PluginPlatformComposition.install(
            processKind: .share,
            bundledPluginsBundle: LunaBundledPluginsBundle.bundle,
            additionalBridges: { PluginUIComposition.bridges(processKind: .share, scheduler: $0) })
        // The Luna file intake seam. Every root installs a witness, so a
        // `.luna` file reaching a surface is always accounted for; the
        // recovery and plugin surfaces each install their own half. The plugin
        // half needs this controller, so it is installed once `super.init` has run.
        LunaFileIntake.recoveryHandler = ExtensionRecoveryFileIntake()
        super.init(nibName: nibName, bundle: bundle)
        LunaFileIntake.pluginHandler = PluginDraftFileIntake(
            presenter: DraftReviewRoute(host: self), launcher: HostLLMLauncher(host: self))
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// An arriving plugin draft is reviewed inside the extension's own hierarchy,
/// which is the only place it can show anything. Saving there writes the
/// App-Group plugin store, and the app reloads its runtime on next foreground.
private final class DraftReviewRoute: PluginDraftReviewPresenting {
    private weak var host: ShareViewController?

    init(host: ShareViewController) { self.host = host }

    @MainActor
    func presentPluginDraftReview(_ screen: PluginDraftReviewViewController) {
        host?.presentModally(screen)
    }

    @MainActor
    func dismissPluginDraftReview(_ screen: PluginDraftReviewViewController) {
        host?.completeSilently()
    }
}

/// An extension may only ask its host to open a URL, and the host may refuse.
/// The reply still comes back as a Luna file, so a refusal costs the user a
/// tap rather than the flow.
private final class HostLLMLauncher: LLMLaunching {
    private weak var host: ShareViewController?

    init(host: ShareViewController) { self.host = host }

    @MainActor
    func openLLM(_ url: URL, fallback: URL?) {
        host?.openURL(url)
    }
}

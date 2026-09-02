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
//  extension, App Clip) installs the same pack. See `ArticleKindComposition`
//  and claudedocs/surface-support.md.
//
//  Never write `IngestKindProcessors` or `ShareKindPresenters` here directly.
//  Hand-listing them per surface let a kind register on some surfaces and not
//  others; `KindCompositionRootTests` fails the build if this file does that.
//

import LunaMediaDownload
import LunaPluginIngest
import LunaPluginKit
import LunaPriceUI
import LunaReaderUI
import LunaShareSurface
import UIKit

@objc(LunaShareEntry)
final class ShareEntry: ShareViewController {
    override init(nibName: String?, bundle: Bundle?) {
        ArticleKindComposition.install()
        MediaKindComposition.install()
        ProductKindComposition.install()
        PluginPlatformComposition.install(
            processKind: .share, swiftMediaResolver: SocialMediaResolver())
        super.init(nibName: nibName, bundle: bundle)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}

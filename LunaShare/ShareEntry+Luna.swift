//
//  ShareEntry+Luna.swift
//
//  The extension's principal class (Info.plist names the stable @objc name
//  `LunaShareEntry`). EXACTLY ONE variant is compiled into each host's extension
//  target (per-target membership exceptions on the shared folder).
//
//  It installs the KIND PACKS this host's app handles — one call each. What a
//  kind registers (pipeline processors AND extension presenters) is defined once,
//  in that kind's own module, and shared by every surface: app shell, share
//  extension, action extension, App Clip. See `ArticleKindComposition` and
//  claudedocs/surface-support.md.
//
//  Do NOT write `IngestKindProcessors` / `ShareKindPresenters` directly here —
//  hand-listing them per surface is what let a kind be registered on some
//  surfaces and not others (`KindCompositionRootTests` fails the build for it).
//

import LunaMediaDownload
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
        super.init(nibName: nibName, bundle: bundle)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}

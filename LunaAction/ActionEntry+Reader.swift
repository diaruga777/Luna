//
//  ActionEntry+Reader.swift
//
//  The action extension's principal class. Info.plist names it
//  `LunaActionEntry`. Each host target compiles exactly one variant, chosen
//  by a membership exception on this shared folder.
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

import LunaModels
import LunaReaderUI
import LunaShareSurface
import UIKit

@objc(LunaActionEntry)
final class ActionEntry: ShareViewController {
    override init(nibName: String?, bundle: Bundle?) {
        ArticleKindComposition.install()
        // The Luna file intake seam. Every root installs a witness, so a
        // `.luna` file reaching a surface is always accounted for; the
        // recovery and plugin surfaces replace it with their own.
        LunaFileIntake.recoveryHandler = UnsupportedLunaFileIntake()
        LunaFileIntake.pluginHandler = UnsupportedLunaFileIntake()
        super.init(nibName: nibName, bundle: bundle)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}

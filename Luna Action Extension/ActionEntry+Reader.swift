//
//  ActionEntry+Reader.swift
//
//  The extension's principal class (Info.plist names the stable @objc name
//  `LunaActionEntry`). EXACTLY ONE variant is compiled into each host's
//  extension target (per-target membership exceptions on the shared folder),
//  registering the per-kind pipeline processors that host's app handles —
//  the registry mirrors the link set.
//

import LunaShareSurface
import UIKit
import LunaArticleIngest
import LunaIngest

@objc(LunaActionEntry)
final class ActionEntry: ShareViewController {
    override init(nibName: String?, bundle: Bundle?) {
        IngestKindProcessors.article = ArticleIngestProcessor()
        super.init(nibName: nibName, bundle: bundle)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}

//
//  ShareEntry+Downloader.swift
//
//  The extension's principal class (Info.plist names the stable @objc name
//  `LunaShareEntry`). EXACTLY ONE variant is compiled into each host's
//  extension target (per-target membership exceptions on the shared folder),
//  registering the per-kind pipeline processors that host's app handles —
//  the registry mirrors the link set.
//

import LunaShareSurface
import UIKit

@objc(LunaShareEntry)
final class ShareEntry: ShareViewController {
    // Media needs no web-processing pipeline stage; nothing to register.
}

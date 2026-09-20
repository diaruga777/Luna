//
//  LLMLauncher.swift
//  LunaDesignSystem
//

import LunaModels
import UIKit

/// Opens a provider link. The app opens it itself; an extension may only ask
/// its host, and the host may refuse — which is why this is a seam rather than
/// a call to `UIApplication` wherever a hand-off starts.
@MainActor
public protocol LLMLaunching: AnyObject {
    /// Opens `url`, or `fallback` when this process cannot open `url`.
    func openLLM(_ url: URL, fallback: URL?)
}

/// The app's launcher: it asks the system whether the provider's own app can
/// take the link, and opens the web form when it cannot.
@MainActor
public final class LLMLauncher: LLMLaunching {
    public static let shared = LLMLauncher()

    public init() {}

    public func openLLM(_ url: URL, fallback: URL?) {
        let application = UIApplication.shared
        if application.canOpenURL(url) {
            application.open(url)
            return
        }
        if let fallback { application.open(fallback) }
    }
}

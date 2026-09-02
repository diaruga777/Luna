//
//  SafariPluginMessages+None.swift
//  LunaSafari
//
//  Compiled into the three single-kind Safari appexes (LunaReaderSafari,
//  LunaDownloaderSafari, LunaPriceTrackerSafari) via a membership exception
//  that excludes `SafariPluginMessages+Luna.swift` from their target
//  instead — the same per-target-variant mechanism `KindWiring+Luna.swift`/
//  `KindWiring+Reader.swift` use (see the comment above `SafariPluginMessaging`
//  in SafariWebExtensionHandler.swift for why a compiler module-visibility
//  guard is not used here instead).
//

enum SafariPluginMessages {
    static let handler: SafariPluginMessaging? = nil
}

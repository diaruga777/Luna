//
//  ShareKindPresenterTestSupport.swift
//  LunaTests
//

import LunaMediaDownload
import LunaPriceUI
import LunaReaderUI
import LunaShareSurface

/// Registers the SAME per-kind extension presenters the central Luna
/// extension's entry class (`ShareEntry+Luna`) registers, so driver tests can
/// exercise every `Outcome` branch. Registered explicitly in each test class's
/// `setUp` — like the pipeline processors in `SurfaceParityTests` — because
/// the test bundle may hold its own copies of the frameworks, so no app-launch
/// registration is guaranteed to be visible through the registry here.
@MainActor
enum ShareKindPresenterTestSupport {
    static func registerAll() {
        ShareKindPresenters.article = ExtensionArticlePresenter()
        ShareKindPresenters.media = ExtensionMediaPresenter()
        ShareKindPresenters.product = ExtensionProductPresenter()
    }
}

import UIKit
import LunaDesignSystem
import LunaWriterEditor
import LunaWriterLibraryUI
import LunaWriterModels
import LunaWriterReadAlong
import LunaWriterStorage
import LunaWriterText
import LunaWriterVoice

/// The composition root for Luna Writer. It builds the storage stack and
/// installs every protocol witness; view controllers receive built services
/// and never locate them. Filled in by work package H
/// (`claudedocs/plans/writer-app.md` §10, §12).
@MainActor enum WriterWiring {
    static func install() {}

    static func applicationDidEnterBackground() {}

    static func makeRootViewController() -> UIViewController {
        let placeholder = UIViewController()
        placeholder.view.backgroundColor = LunaColors.background
        return placeholder
    }

    static func open(_ url: URL) {}
}

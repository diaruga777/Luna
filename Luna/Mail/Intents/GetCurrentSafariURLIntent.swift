import AppIntents
import Foundation
import LunaStorage

struct GetCurrentSafariURLIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Current Safari URL"
    static var description = IntentDescription("Get the last webpage URL reported by the Luna Safari extension, using the same page tracking as Luna Reader. Requires the extension to be enabled for that website.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<URL> {
        .result(value: try SafariURLStore.currentPageURL())
    }
}

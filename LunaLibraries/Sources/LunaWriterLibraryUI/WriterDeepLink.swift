import Foundation
import LunaWriterModels

/// `lunawriter://document/<uuid>` and `lunawriter://new` — the app's own URL
/// scheme, parsed here (rather than inline in `WriterWiring`, which lives in
/// the untested app target) so the parsing has a suite that can reach it.
public enum WriterDeepLink: Equatable {
    case document(DocumentID)
    case newSheet

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "lunawriter" else { return nil }
        switch url.host?.lowercased() {
        case "new": self = .newSheet
        case "document":
            let component = url.pathComponents.dropFirst().first ?? ""
            guard let uuid = UUID(uuidString: component) else { return nil }
            self = .document(DocumentID(uuid))
        default: return nil
        }
    }
}

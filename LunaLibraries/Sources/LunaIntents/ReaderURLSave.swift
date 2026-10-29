import Foundation
import LunaModels
import LunaSaves
import LunaStorage

/// The composable URL action uses the same post-ingest verification as capture.
/// A failed extraction must throw before Shortcuts runs its next action.
public enum ReaderURLSave {
    public enum Failure: LocalizedError, Equatable {
        case invalidURL, missing, contentUnavailable
        public var errorDescription: String? {
            switch self {
            case .invalidURL: return "Enter an http or https URL."
            case .missing: return "The saved item is no longer available."
            case .contentUnavailable: return "This page couldn’t be saved. Open Luna Reader to try again."
            }
        }
    }

    public static func save(_ url: URL, store: SavesStore = .shared,
                            ingest: (SavedItem) async -> Void = {
                                _ = await SavesIngestor.shared.ingest($0, allowsInteractivePrompt: false)
                            }) async throws -> SavedItem {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else {
            throw Failure.invalidURL
        }
        let item = store.add(urlString: url.absoluteString, source: .appIntent)
        await ingest(item)
        let saved = store.item(withID: item.id)
        switch IntentSaveVerification.failure(forState: saved?.state) {
        case .nothingSaved: throw Failure.missing
        case .contentUnavailable: throw Failure.contentUnavailable
        case nil: break
        }
        guard let saved else { throw Failure.missing }
        return saved
    }
}

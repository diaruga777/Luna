//
//  MessageEnvelope.swift
//  Clip
//

import ClipModels
import Foundation

/// What a message says, decoded from its (decrypted) JSON envelope.
/// The envelope carries a raw `type` string so future clients can introduce
/// new types: anything unrecognized decodes as `.unknown` and is ignored.
public enum MessageBody: Equatable {
    /// "Add me back": the sender's identity card (bi-directional friend add).
    case friendAdd(IdentityCard)
    /// A shared reading-list link.
    case readingListItem(urlString: String, title: String?)
    /// A shared URL-less music/podcast item (artist+track or show+episode).
    case mediaItem(kind: ContentPlatform, creator: String, title: String)
    /// A shared price tracker: the product name, every watched store URL, the
    /// best fetched price at share time (so the recipient sees the same baseline),
    /// and the alert threshold. Recreated as a tracker on receipt.
    case priceTracker(PriceTrackerShare)
    /// A type this client doesn't know — ignore, never an error.
    case unknown(type: String)

    private enum TypeName {
        static let friendAdd = "friendAdd"
        static let readingListItem = "readingListItem"
        static let mediaItem = "mediaItem"
        static let priceTracker = "priceTracker"
    }

    /// Wire shape: {"type": "...", plus type-specific fields}.
    private struct Wire: Codable {
        var type: String
        var card: IdentityCard?
        var urlString: String?
        var title: String?
        var kind: String?
        var creator: String?
        var mediaTitle: String?
        var priceTracker: PriceTrackerShare?
    }

    public func encoded() throws -> Data {
        let wire: Wire
        switch self {
        case .friendAdd(let card):
            wire = Wire(type: TypeName.friendAdd, card: card)
        case .readingListItem(let urlString, let title):
            wire = Wire(type: TypeName.readingListItem, urlString: urlString, title: title)
        case .mediaItem(let kind, let creator, let title):
            wire = Wire(type: TypeName.mediaItem,
                        kind: kind.rawValue, creator: creator, mediaTitle: title)
        case .priceTracker(let share):
            wire = Wire(type: TypeName.priceTracker, priceTracker: share)
        case .unknown(let type):
            wire = Wire(type: type)
        }
        return try JSONEncoder().encode(wire)
    }

    public static func decoded(from data: Data) throws -> MessageBody {
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        switch wire.type {
        case TypeName.friendAdd:
            guard let card = wire.card else { return .unknown(type: wire.type) }
            return .friendAdd(card)
        case TypeName.readingListItem:
            guard let urlString = wire.urlString else { return .unknown(type: wire.type) }
            return .readingListItem(urlString: urlString, title: wire.title)
        case TypeName.mediaItem:
            guard let kindRaw = wire.kind, let kind = ContentPlatform(rawValue: kindRaw),
                  let creator = wire.creator, let title = wire.mediaTitle
            else { return .unknown(type: wire.type) }
            return .mediaItem(kind: kind, creator: creator, title: title)
        case TypeName.priceTracker:
            guard let share = wire.priceTracker, !share.storeURLStrings.isEmpty else {
                return .unknown(type: wire.type)
            }
            return .priceTracker(share)
        default:
            return .unknown(type: wire.type)
        }
    }
}

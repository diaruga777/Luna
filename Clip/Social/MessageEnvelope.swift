//
//  MessageEnvelope.swift
//  Clip
//

import Foundation

/// What a message says, decoded from its (decrypted) JSON envelope.
/// The envelope carries a raw `type` string so future clients can introduce
/// new types: anything unrecognized decodes as `.unknown` and is ignored.
enum MessageBody: Equatable {
    /// "Add me back": the sender's identity card (bi-directional friend add).
    case friendAdd(IdentityCard)
    /// A shared reading-list link.
    case readingListItem(urlString: String, title: String?)
    /// A type this client doesn't know — ignore, never an error.
    case unknown(type: String)

    private enum TypeName {
        static let friendAdd = "friendAdd"
        static let readingListItem = "readingListItem"
    }

    /// Wire shape: {"type": "...", plus type-specific fields}.
    private struct Wire: Codable {
        var type: String
        var card: IdentityCard?
        var urlString: String?
        var title: String?
    }

    func encoded() throws -> Data {
        let wire: Wire
        switch self {
        case .friendAdd(let card):
            wire = Wire(type: TypeName.friendAdd, card: card)
        case .readingListItem(let urlString, let title):
            wire = Wire(type: TypeName.readingListItem, urlString: urlString, title: title)
        case .unknown(let type):
            wire = Wire(type: type)
        }
        return try JSONEncoder().encode(wire)
    }

    static func decoded(from data: Data) throws -> MessageBody {
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        switch wire.type {
        case TypeName.friendAdd:
            guard let card = wire.card else { return .unknown(type: wire.type) }
            return .friendAdd(card)
        case TypeName.readingListItem:
            guard let urlString = wire.urlString else { return .unknown(type: wire.type) }
            return .readingListItem(urlString: urlString, title: wire.title)
        default:
            return .unknown(type: wire.type)
        }
    }
}

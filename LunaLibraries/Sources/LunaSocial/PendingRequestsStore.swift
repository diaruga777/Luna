//
//  PendingRequestsStore.swift
//  LunaSocial
//

import LunaStorage
import Foundation

/// An incoming Luna share from someone who isn't yet an accepted friend. Held
/// in a moderation queue (not imported) until the user accepts it — guarding
/// against adversarial URLs from strangers.
public struct PendingRequest: Codable, Equatable, Identifiable {
    public var id: UUID
    public var senderEmail: String
    public var senderName: String?
    public var urlString: String
    public var title: String?
    /// The Luna `ContentKind` description (advisory).
    public var kind: String
    /// Provider-native message handle, so the mail can be marked read on accept.
    public var messageID: String?
    public var date: Date

    public init(id: UUID = UUID(), senderEmail: String, senderName: String?,
                urlString: String, title: String?, kind: String,
                messageID: String?, date: Date = Date()) {
        self.id = id
        self.senderEmail = Friend.normalize(senderEmail)
        self.senderName = senderName
        self.urlString = urlString
        self.title = title
        self.kind = kind
        self.messageID = messageID
        self.date = date
    }

    public var displaySender: String {
        if let senderName, !senderName.trimmingCharacters(in: .whitespaces).isEmpty {
            return senderName
        }
        return Friend.localPart(senderEmail)
    }
}

/// Persists pending share requests as JSON in the App Group container.
public final class PendingRequestsStore {

    public static let shared = PendingRequestsStore()

    private let store: AppGroupJSONStore<PendingRequest>

    public init(containerURL: URL? = nil) {
        store = AppGroupJSONStore(
            filename: "pendingRequests.json", changeNotification: .pendingRequestsChanged,
            containerURL: containerURL)
    }

    /// All pending requests, newest first.
    public func items() -> [PendingRequest] {
        store.load().sorted { $0.date > $1.date }
    }

    public var count: Int { items().count }

    /// True when a request from this sender for this URL already exists (dedupe).
    public func contains(urlString: String, senderEmail: String) -> Bool {
        let sender = Friend.normalize(senderEmail)
        return items().contains { $0.urlString == urlString && $0.senderEmail == sender }
    }

    public func add(_ request: PendingRequest) {
        store.mutationLock.lock()
        defer { store.mutationLock.unlock() }
        var all = items()
        guard !all.contains(where: {
            $0.urlString == request.urlString && $0.senderEmail == request.senderEmail
        }) else { return }
        all.insert(request, at: 0)
        store.save(all)
    }

    public func remove(id: UUID) {
        store.mutationLock.lock()
        defer { store.mutationLock.unlock() }
        var all = items()
        all.removeAll { $0.id == id }
        store.save(all)
    }
}

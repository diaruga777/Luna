//
//  EmailShareCenter.swift
//  LunaReadingList
//

import LunaModels
import LunaStorage
import LunaMailAccount
import LunaMailTransport
import LunaSocial
import LunaPriceUI
import UIKit

/// Sends a reading-list item (or a bare URL) to one or more recipients as a
/// nicely-formatted Luna email, and records each recipient in the friends list.
/// The email carries the `X-Luna-Share` marker so a recipient's Luna app can
/// recognise and import it.
public final class EmailShareCenter {

    public static let shared = EmailShareCenter()

    private let store: ReadingListStore
    private let accountStore: EmailAccountStore
    private let friends: FriendsStore
    private let recentRecipients: RecentFriendRecipientsStore

    public init(store: ReadingListStore = .shared,
                accountStore: EmailAccountStore = .shared,
                friends: FriendsStore = .shared,
                recentRecipients: RecentFriendRecipientsStore = .shared) {
        self.store = store
        self.accountStore = accountStore
        self.friends = friends
        self.recentRecipients = recentRecipients
    }

    public enum ShareError: Error, LocalizedError {
        case notConfigured
        case noRecipients
        case buildFailed

        public var errorDescription: String? {
            switch self {
            case .notConfigured: return "Set up your email account first."
            case .noRecipients: return "Choose at least one recipient."
            case .buildFailed: return "Couldn't build the email."
            }
        }
    }

    /// Whether an email account is connected (required to send).
    public var isConfigured: Bool { accountStore.isConfigured }

    /// Sends a reading-list item to the given email addresses.
    @MainActor
    public func send(item: ReadingListItem, to emails: [String]) async throws {
        try await deliver(urlString: item.urlString, title: item.title, item: item, to: emails)
    }

    /// Sends a bare URL (no stored item) to the given email addresses.
    @MainActor
    public func share(urlString: String, title: String?, to emails: [String]) async throws {
        try await deliver(urlString: urlString, title: title, item: nil, to: emails)
    }

    // MARK: - Delivery

    @MainActor
    private func deliver(
        urlString: String, title: String?, item: ReadingListItem?, to emails: [String]
    ) async throws {
        let recipients = emails
            .map(Friend.normalize)
            .filter(Friend.isValidEmail)
        guard !recipients.isEmpty else { throw ShareError.noRecipients }
        guard let account = accountStore.account, let transport = MailTransportFactory.make(store: accountStore)
        else { throw ShareError.notConfigured }

        let kind = kindString(for: item)
        let marker = LunaShareMarker(
            url: urlString, title: title ?? "", kind: kind, sender: account.displayName)

        let (body, inlineImages) = buildBody(
            item: item, urlString: urlString, title: title, marker: marker)

        let raw = EmailMIMEBuilder.build(
            from: account.fromHeader, to: recipients, subject: body.subject,
            plainBody: body.plain, htmlBody: body.html, inlineImages: inlineImages,
            headers: [LunaShareMarker.headerName: marker.headerValue()])

        try await transport.send(OutgoingEmail(
            recipients: recipients, subject: body.subject, rawMIME: raw))

        // Record every recipient as a friend (accepted — the user chose them).
        for email in recipients { friends.add(email: email) }
        recentRecipients.recordSent(to: recipients)
    }

    // MARK: - Body building

    @MainActor
    private func buildBody(
        item: ReadingListItem?, urlString: String, title: String?, marker: LunaShareMarker
    ) -> (body: RenderedEmailBody, images: [InlineImage]) {
        // Article / document: render the full text with inline images.
        if let item, item.priceTracker == nil, item.platform == nil, !item.isYouTubeVideo,
           let content = store.content(for: item), content.isArticleLike {
            let rendered = EmailContentRenderer.renderArticle(
                content, originalURL: urlString, marker: marker)
            let images = rendered.imageRefs.compactMap { inlineImage(fileName: $0.imageFileName, cid: $0.contentID) }
            return (rendered, images)
        }

        // Everything else: a compact card with an optional hero image.
        var heroImage: InlineImage?
        var detailLines: [String] = []

        if let tracker = item?.priceTracker {
            detailLines.append(priceSummary(for: tracker))
            if let snapshot = priceSnapshot(for: tracker) {
                heroImage = InlineImage(contentID: "hero", mimeType: "image/jpeg", data: snapshot)
            } else if let thumb = item?.thumbnailFileName {
                heroImage = inlineImage(fileName: thumb, cid: "hero")
            }
        } else {
            if let creator = item?.mediaCreatorName ?? item?.channelName { detailLines.append(creator) }
            if let mediaTitle = item?.mediaItemTitle, mediaTitle != title { detailLines.append(mediaTitle) }
            if let thumb = item?.thumbnailFileName {
                heroImage = inlineImage(fileName: thumb, cid: "hero")
            }
        }

        let rendered = EmailContentRenderer.renderCard(
            title: title ?? urlString, originalURL: urlString, marker: marker,
            heroImageCID: heroImage == nil ? nil : "hero", detailLines: detailLines)
        return (rendered, [heroImage].compactMap { $0 })
    }

    private func kindString(for item: ReadingListItem?) -> String {
        guard let item else { return "link" }
        if item.priceTracker != nil { return "product" }
        if item.isYouTubeVideo { return "video" }
        if let platform = item.platform { return platform.rawValue }
        if item.sanitizedDocumentType != nil { return "document" }
        return "article"
    }

    private func priceSummary(for tracker: PriceTracker) -> String {
        let price = PriceFormatting.string(
            amount: tracker.currentBestPrice, currency: tracker.displayCurrency)
        return "Best price: \(price)"
    }

    /// Loads a local image file (in the Articles directory) as an inline image.
    private func inlineImage(fileName: String, cid: String) -> InlineImage? {
        let url = store.articlesDirectory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let mime = fileName.lowercased().hasSuffix(".png") ? "image/png" : "image/jpeg"
        return InlineImage(contentID: cid, mimeType: mime, data: data)
    }

    /// Renders the price graph to a JPEG for inline embedding.
    @MainActor
    private func priceSnapshot(for tracker: PriceTracker) -> Data? {
        let series = PriceHistory.series(for: tracker)
        guard series.count >= 2 else { return nil }
        let view = PriceGraphView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        view.backgroundColor = .white
        view.setData(series, currency: tracker.displayCurrency)
        view.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let image = renderer.image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        return image.jpegData(compressionQuality: 0.85)
    }
}

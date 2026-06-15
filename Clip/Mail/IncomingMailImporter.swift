//
//  IncomingMailImporter.swift
//  Clip
//

import Foundation

/// Fetches new mail from allowed senders (via IMAP) and turns the first URL in
/// each message into a reading-list item. Runs on launch/foreground — no
/// background fetch. Reuses the send-to-Kindle Gmail account + app password.
final class IncomingMailImporter {

    static let shared = IncomingMailImporter()

    private let makeClient: () -> IMAPFetching
    private let credentials: SendCredentialsStoring
    private let store: ReadingListStore
    /// Kicks ingestion for a saved URL; injectable for tests.
    private let ingest: (ReadingListItem) -> Void
    private var isRunning = false

    init(makeClient: @escaping () -> IMAPFetching = { GmailIMAPClient() },
         credentials: SendCredentialsStoring = KeychainSendCredentialsStore.shared,
         store: ReadingListStore = .shared,
         ingest: ((ReadingListItem) -> Void)? = nil) {
        self.makeClient = makeClient
        self.credentials = credentials
        self.store = store
        self.ingest = ingest ?? { item in
            Task {
                await ReadingListIngestor.shared.ingest(item)
                // Optionally forward the imported article to Kindle once parsed.
                if IncomingMailSettings.autoSendToKindle,
                   ArticleSendCoordinator.shared.isConfigured,
                   let ready = ReadingListStore.shared.item(withID: item.id),
                   ready.state == .ready {
                    await ArticleSendCoordinator.shared.send(ready)
                }
            }
        }
    }

    /// Whether incoming import can run (enabled, has at least one sender or
    /// subject filter, has a Gmail account + password).
    var isConfigured: Bool {
        IncomingMailSettings.isEnabled
            && !(IncomingMailSettings.allowedSenders.isEmpty
                 && IncomingMailSettings.subjectFilters.isEmpty)
            && !KindleSendSettings.smtpUsername.isEmpty
            && !(credentials.smtpPassword() ?? "").isEmpty
    }

    /// Fetches and imports. Safe to call repeatedly; coalesces overlaps.
    func importNewMail() async {
        guard isConfigured, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let account = KindleSendSettings.smtpUsername
        guard let password = credentials.smtpPassword() else { return }

        do {
            let outcome = try await makeClient().fetchNewMessages(
                account: account, password: password,
                senders: IncomingMailSettings.allowedSenders,
                subjectFilters: IncomingMailSettings.subjectFilters,
                afterUID: IncomingMailSettings.lastUID,
                knownUIDValidity: IncomingMailSettings.uidValidity == 0
                    ? nil : IncomingMailSettings.uidValidity)

            var imported = 0
            for message in outcome.messages {
                if let content = MailArticleBuilder.article(from: message) {
                    // Newsletters etc.: the email body IS the article. Save it
                    // directly (no fetch), tagged with the sender.
                    let item = store.add(urlString: "clipmail://\(message.uid)")
                    if let sender = MailArticleBuilder.senderName(from: message.from) {
                        store.setChannelName(sender, for: item.id)
                    }
                    _ = store.saveContent(content, for: item)
                    imported += 1
                    DiagnosticLog.shared.record(
                        "incoming mail: imported uid \(message.uid) as article \"\(content.title)\" (\(content.blocks.count) blocks)",
                        category: "mail")
                    autoSendToKindleIfEnabled(itemID: item.id)
                } else if let url = message.urls.first {
                    // No usable body but there's a link — save + ingest it.
                    let item = store.add(urlString: url.absoluteString)
                    if item.state == .pending { ingest(item) }
                    imported += 1
                    DiagnosticLog.shared.record(
                        "incoming mail: imported uid \(message.uid) as link \(url.absoluteString)",
                        category: "mail")
                } else {
                    DiagnosticLog.shared.record(
                        "incoming mail: uid \(message.uid) skipped — no article body and no link",
                        category: "mail")
                }
            }
            IncomingMailSettings.uidValidity = outcome.uidValidity
            IncomingMailSettings.lastUID = outcome.highestUID
            DiagnosticLog.shared.record(
                "incoming mail: imported \(imported) of \(outcome.messages.count) message(s)",
                category: "mail")
        } catch {
            DiagnosticLog.shared.record(
                "incoming mail fetch failed: \(String(describing: error))", category: "mail")
        }
    }

    /// Forwards a just-imported article to Kindle when the user enabled it and
    /// Send-to-Kindle is configured.
    private func autoSendToKindleIfEnabled(itemID: UUID) {
        guard IncomingMailSettings.autoSendToKindle,
              ArticleSendCoordinator.shared.isConfigured,
              let ready = store.item(withID: itemID), ready.state == .ready else { return }
        Task { await ArticleSendCoordinator.shared.send(ready) }
    }
}

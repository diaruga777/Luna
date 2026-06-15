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

    /// Whether incoming import can run (enabled, has senders, has a Gmail
    /// account + password).
    var isConfigured: Bool {
        IncomingMailSettings.isEnabled
            && !IncomingMailSettings.allowedSenders.isEmpty
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
                afterUID: IncomingMailSettings.lastUID,
                knownUIDValidity: IncomingMailSettings.uidValidity == 0
                    ? nil : IncomingMailSettings.uidValidity)

            var imported = 0
            for message in outcome.messages {
                guard let url = message.urls.first else { continue }
                let item = store.add(urlString: url.absoluteString)
                if item.state == .pending { ingest(item) }
                imported += 1
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
}

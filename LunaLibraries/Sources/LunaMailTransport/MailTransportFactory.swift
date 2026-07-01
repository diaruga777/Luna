//
//  MailTransportFactory.swift
//  LunaMailTransport
//

import Foundation
import LunaMailAccount

/// Builds the right `EmailTransport` for the connected account: the app-password
/// IMAP/SMTP backend for Gmail/iCloud/Yahoo/custom, or the Graph backend for
/// Outlook. Returns nil when no account is configured.
public enum MailTransportFactory {

    public static func make(store: EmailAccountStore = .shared) -> EmailTransport? {
        guard let account = store.account, let credential = store.credential else { return nil }
        switch credential {
        case .appPassword(let password):
            return try? IMAPSMTPTransport(account: account, password: password)
        case .oauth:
            return GraphMailTransport(store: store)
        }
    }
}

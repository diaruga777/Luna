//
//  FilterGuide.swift
//  LunaMailAccount
//

import Foundation

/// Per-provider guidance for setting up an inbox filter that keeps Luna share
/// emails out of the way (mark read / skip inbox). Outlook is created
/// automatically via Graph; the others need the user to add a rule, so this
/// supplies the exact criteria, a deep link to the provider's filter settings,
/// and (for generic IMAP) an importable Sieve script.
public enum FilterGuide {

    /// The subject all Luna shares carry — the simplest thing to match on.
    public static let subjectMatch = "From Luna:"

    /// Whether Luna creates the filter itself for this provider.
    public static func isAutomatic(_ id: MailProvider.ID) -> Bool {
        MailProvider.provider(for: id).filterSupport == .automatic && id == .outlook
    }

    /// A link to the provider's filter/rules settings (opened in the browser).
    public static func settingsURL(for id: MailProvider.ID) -> URL? {
        switch id {
        case .gmail:
            return URL(string: "https://mail.google.com/mail/u/0/#settings/filters")
        case .icloud:
            return URL(string: "https://www.icloud.com/mail")
        case .yahoo:
            return URL(string: "https://mail.yahoo.com/d/settings/1")
        case .outlook:
            return URL(string: "https://outlook.live.com/mail/0/options/mail/rules")
        case .generic:
            return nil
        }
    }

    /// Step-by-step instructions for adding the filter manually.
    public static func instructions(for id: MailProvider.ID) -> String {
        let markRead = "match the Subject containing \"\(subjectMatch)\" and mark it as read / skip the inbox."
        switch id {
        case .gmail:
            return "In Gmail settings → Filters and Blocked Addresses → Create a new "
                + "filter, set Subject to \"\(subjectMatch)\", then choose "
                + "\"Skip the Inbox\" and \"Mark as read\"."
        case .icloud:
            return "In iCloud Mail → Settings → Rules → Add a Rule that matches the "
                + "Subject containing \"\(subjectMatch)\" and moves it to a folder / "
                + "marks it as read."
        case .yahoo:
            return "In Yahoo Mail → Settings → Filters → Add, \(markRead)"
        case .outlook:
            return "Luna sets this up automatically for Outlook."
        case .generic:
            return "If your provider supports filters (Sieve), add a rule to \(markRead)\n\n"
                + sieveScript
        }
    }

    /// An importable Sieve rule for ManageSieve-capable custom servers.
    public static let sieveScript = """
    require ["imap4flags", "fileinto"];
    if header :contains "subject" "\(subjectMatch)" {
        setflag "\\\\Seen";
        fileinto "Luna";
    }
    """
}

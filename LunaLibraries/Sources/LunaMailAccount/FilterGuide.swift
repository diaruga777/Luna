//
//  FilterGuide.swift
//  LunaMailAccount
//

import Foundation
import LunaModels

/// Per-provider guidance for setting up an inbox filter that keeps Luna share
/// emails out of the way (mark read / skip inbox). Outlook is created
/// automatically via Graph; the others need the user to add a rule, so this
/// supplies the exact criteria, a deep link to the provider's filter settings,
/// and (for generic IMAP) an importable Sieve script.
public enum FilterGuide {

    /// The invisible character in Luna's share subject prefix.
    public static let subjectInvisibleMarker = "\u{200C}"

    /// The subject all Luna shares carry — the simplest thing to match on.
    public static let subjectMatch = "via Lu\(subjectInvisibleMarker)na:"

    /// The outgoing subject prefix, including the human separator after the marker.
    public static let subjectPrefix = "\(subjectMatch) "

    /// Whether Luna creates the filter itself for this provider. Outlook is the
    /// only provider with a filter API Luna can call (Graph); every other
    /// provider needs the user to add a rule manually.
    public static func isAutomatic(_ id: MailProvider.ID) -> Bool {
        id == .outlook
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
        let markRead = L10n.string("MailAccount_filterGuide_matchSubjectInstruction", subjectMatch)
        switch id {
        case .gmail:
            return L10n.string("MailAccount_filterGuide_gmailInstructions", subjectMatch)
        case .icloud:
            return L10n.string("MailAccount_filterGuide_icloudInstructions", subjectMatch)
        case .yahoo:
            return L10n.string("MailAccount_filterGuide_yahooInstructions", markRead)
        case .outlook:
            return L10n.string("MailAccount_filterGuide_outlookInstructions")
        case .generic:
            return "\(L10n.string("MailAccount_filterGuide_genericInstructions", markRead))\n\n\(sieveScript)"
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

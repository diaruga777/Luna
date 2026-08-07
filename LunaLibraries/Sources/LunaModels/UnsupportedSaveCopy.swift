//
//  UnsupportedSaveCopy.swift
//  LunaModels
//

import Foundation

/// The ONE wording for "this app can't take this link", shared by every surface
/// that has to say it: the in-app card, the share/action extensions' card, and
/// the App Intents' error dialog (which has no UI of its own and so speaks the
/// two lines as one sentence).
///
/// Lives in LunaModels — next to `LunaApp`, below every UI tier — so the app
/// shell, the design system's card, the ingest gate, and the intents all read
/// the same strings instead of each writing their own apology.
public enum UnsupportedSaveCopy {

    /// The header every drop shows, whether or not a sibling app owns the link.
    public static func header(current: LunaApp = .current) -> String {
        L10n.string("UnsupportedSave_header", current.displayName)
    }

    /// The sibling-app line, shown under that app's icon. Only for a drop whose
    /// kind actually belongs to another Luna app.
    public static func upsell(owner: LunaApp) -> String {
        L10n.string("UnsupportedSave_upsell", owner.displayName)
    }

    /// Both lines as one sentence, for surfaces that can only speak (the App
    /// Intents' thrown dialog). `owner == nil` — or the running app itself —
    /// leaves just the header.
    public static func sentence(owner: LunaApp?, current: LunaApp = .current) -> String {
        guard let owner, owner != current else { return header(current: current) + "." }
        return header(current: current) + ". " + upsell(owner: owner) + "."
    }
}

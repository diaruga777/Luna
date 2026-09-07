//
//  PendingSaveStatus.swift
//  LunaModels
//

import Foundation

/// Answers what a `.pending` save is waiting on, in the user's words, so the
/// generic pending card can say more than "Loading…". Nil means the card keeps
/// its default line.
public protocol PendingSaveStatusProviding: AnyObject {
    func status(forSaveID id: UUID) -> String?
}

/// Where that provider is installed. The card lives in the app shell and the
/// transcription store below it; neither can see the other, so the app's
/// composition root fills this slot (`claudedocs/plans/transcription-plugins.md`
/// §6).
public enum PendingSaveStatus {
    public static var provider: (any PendingSaveStatusProviding)?
}

//
//  LLMHandoffResume.swift
//  Luna
//
//  The app's end of `<scheme>://llm?item=…` (`claudedocs/llm-handoff.md`).
//
//  An extension may only ask its host to open a URL, and the host may refuse.
//  When it does, the extension opens Luna at this link instead, and the app —
//  which is always allowed to open a provider — finishes the hand-off from the
//  record the extension already wrote.
//
//  Universal (no membership exception): every type it names is universal-tier,
//  so all four apps answer the route.
//

import LunaDesignSystem
import LunaModels
import LunaStorage
import UIKit

@MainActor
enum LLMHandoffResume {

    /// Opens the provider the extension recorded for `itemID`. Does nothing
    /// when the record has expired or the save is gone — there is nothing left
    /// to write a prompt about.
    static func open(itemID: UUID) {
        guard let record = LLMHandoffStore.shared.record(forItemID: itemID),
              let item = SavesStore.shared.item(withID: itemID) else { return }
        FailedSaveCardFactory.startHandoff(for: item, to: record.provider)
    }
}

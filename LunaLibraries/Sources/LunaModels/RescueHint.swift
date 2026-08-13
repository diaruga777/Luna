//
//  RescueHint.swift
//  LunaModels
//

import Foundation

/// What a failed save should be rescued INTO. Lives in LunaModels (the lowest
/// tier) so the engine, the coordinator, the extension handoff store, and the
/// price/media UI can all name it without pulling in the rescue engine module
/// (which extensions must never link).
///
/// **Never user-facing.** No surface asks which kind a page is — the model
/// classifies it (`RescueRequest.ContentHint.auto`). Only two PROGRAMMATIC
/// callers pick a specific hint, because they know from where the user
/// pressed: the price editor's no-price retry (`.product`) and the media
/// card's no-assets retry (`.media`). Hence no `displayName` — nothing
/// displays it.
public enum RescueHint: String, Codable, CaseIterable {
    case article
    case product
    case media
}

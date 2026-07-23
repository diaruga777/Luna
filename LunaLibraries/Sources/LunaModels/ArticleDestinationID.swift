//
//  ArticleDestinationID.swift
//  Luna
//

/// Stable destination ids, used as keys in `ReadingListItem.sendStates` and to
/// target explicit sends. Lives in LunaModels (not LunaSend) because the pure
/// `SavePressPolicy` and the universal save path reference the ids without
/// needing the send machinery itself.
public enum ArticleDestinationID {
    public static let kindle = "kindle"
}

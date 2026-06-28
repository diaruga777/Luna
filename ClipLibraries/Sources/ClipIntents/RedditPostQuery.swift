//
//  RedditPostQuery.swift
//  ClipIntents
//

import Foundation

/// Builds a Reddit search query from precise fields using Reddit's `subreddit:`
/// and `author:` operators. Pure, so the formatting is testable.
public enum RedditPostQuery {
    public static func searchQuery(subreddit: String, title: String, author: String?) -> String {
        let sub = subreddit.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "r/", with: "", options: [.anchored, .caseInsensitive])
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return "" }
        var parts = [cleanTitle]
        if !sub.isEmpty { parts.append("subreddit:\(sub)") }
        if let author {
            let user = author.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "u/", with: "", options: [.anchored, .caseInsensitive])
            if !user.isEmpty { parts.append("author:\(user)") }
        }
        return parts.joined(separator: " ")
    }
}

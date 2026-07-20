import Foundation

public enum HTMLClassification {
    public static func declaresPaywall(in html: String) -> Bool {
        let compact = html.lowercased().filter { !$0.isWhitespace }
        if compact.contains("\"isaccessibleforfree\":false")
            || compact.contains("\"isaccessibleforfree\":\"false\"") {
            return true
        }
        return ["locked", "metered", "premium"].contains { value in
            compact.contains("content_tier\"content=\"\(value)")
                || compact.contains("content-tier\"content=\"\(value)")
                || compact.contains("content=\"\(value)\"property=\"article:content_tier")
                || compact.contains("content=\"\(value)\"name=\"article:content_tier")
        }
    }
}

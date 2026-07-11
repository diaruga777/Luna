//
//  ArticleRelativeDateFilter.swift
//  LunaIntents
//

import Foundation

/// A relative-date phrase `ArticleQueryParser` can pull out of a Siri search
/// string ("yesterday", "today", "this week") so `ArticleMatcher` can filter
/// candidates by save date.
public enum ArticleRelativeDateFilter: Equatable {
    case today
    case yesterday
    case thisWeek

    /// Whether `date` falls within this relative window of `now`.
    public static func matches(
        date: Date, filter: ArticleRelativeDateFilter, now: Date, calendar: Calendar
    ) -> Bool {
        switch filter {
        case .today:
            return calendar.isDate(date, inSameDayAs: now)
        case .yesterday:
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return false }
            return calendar.isDate(date, inSameDayAs: yesterday)
        case .thisWeek:
            return calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear)
                && calendar.isDate(date, equalTo: now, toGranularity: .yearForWeekOfYear)
        }
    }
}

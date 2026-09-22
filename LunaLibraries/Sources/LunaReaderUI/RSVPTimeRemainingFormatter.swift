//
//  RSVPTimeRemainingFormatter.swift
//  LunaReaderUI
//

import Foundation

/// Formats RSVP playback estimates in the compact, locale-aware form used by
/// the reader footer (for example `42s`, `5m 8s`, or `1h 12m 4s`).
public enum RSVPTimeRemainingFormatter {
    public static func string(
        from duration: TimeInterval, locale: Locale = .current
    ) -> String {
        let roundedSeconds = max(0, ceil(duration.isFinite ? duration : 0))
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        formatter.calendar = calendar

        return formatter.string(from: roundedSeconds) ?? "0s"
    }
}

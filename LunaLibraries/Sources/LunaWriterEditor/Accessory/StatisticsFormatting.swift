//
//  StatisticsFormatting.swift
//  LunaWriterEditor
//

import Foundation
import LunaModels
import LunaWriterModels
import LunaWriterText

/// Reads a sheet's counts against a goal and words them for the statistics
/// sheet.
public enum StatisticsFormatting {

    /// "412 words · 2 min".
    public static func summary(_ stats: TextStatistics.Stats) -> String {
        L10n.string(
            "WriterEditor_statisticsSummary", stats.words as CVarArg, readingTime(stats.readingTime))
    }

    public static func readingTime(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        return L10n.string("WriterEditor_statisticsMinutes", minutes as CVarArg)
    }

    /// How far the writing has come against its goal, capped at one.
    public static func fraction(of stats: TextStatistics.Stats, against goal: WritingGoal) -> Double {
        guard goal.target > 0 else { return 0 }
        return min(1, Double(measure(stats, in: goal.unit)) / Double(goal.target))
    }

    public static func measure(_ stats: TextStatistics.Stats, in unit: WritingGoal.Unit) -> Int {
        switch unit {
        case .words: return stats.words
        case .characters: return stats.characters
        case .sentences: return stats.sentences
        case .readingMinutes: return Int((stats.readingTime / 60).rounded())
        }
    }
}

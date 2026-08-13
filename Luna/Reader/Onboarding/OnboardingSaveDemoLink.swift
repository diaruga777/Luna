//
//  OnboardingSaveDemoLink.swift
//  Luna
//

import LunaModels
import LunaStorage
import LunaWeekly

/// The link the save lesson rehearses with, decided at the moment the user taps
/// into it.
///
/// The lesson runs the REAL share surface, which means it needs a REAL link —
/// and the best one available is this app's live Save of the Week, because it
/// is a genuine page of the kind this app is for, chosen this week, that the
/// user has not seen. Failing that (no signed entry yet, or the
/// weekly feature undeployed) the bundled practice link stands in: the extensions
/// recognize it, short-circuit before the network, and show the same bundled
/// preview they always did — which is the real code path, not a mock of it.
///
/// Offline, neither can be fetched, so the lesson shows what a failed save
/// actually looks like rather than pretending one succeeded.
struct OnboardingSaveDemoLink: Equatable {
    /// What the conversation's bubble reads, what the real share sheet shares,
    /// and what the hosted surface is handed.
    let urlString: String
    /// True when it came from a live Save of the Week. The only case that reaches
    /// the network — a practice link never does.
    let isWeeklySave: Bool
    /// True when there is no usable connection at all, so the hosted surface is
    /// driven straight into the genuine offline failure.
    let isOffline: Bool

    /// Resolves the link. Every dependency is injected so the three branches are
    /// assertable without a network, a CloudKit container, or a signing key.
    static func resolve(
        practiceURLString: String,
        app: LunaApp = .current,
        weeklyURLString: (LunaApp) -> String? = Self.liveWeeklyURLString(for:),
        isOnline: () -> Bool = { NetworkReachability.shared.isOnline }
    ) -> Self {
        guard isOnline() else {
            return Self(
                urlString: practiceURLString, isWeeklySave: false, isOffline: true)
        }
        let weekly = weeklyURLString(app)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !weekly.isEmpty else {
            return Self(
                urlString: practiceURLString, isWeeklySave: false, isOffline: false)
        }
        return Self(urlString: weekly, isWeeklySave: true, isOffline: false)
    }

    /// This app's live weekly pick, for the kinds this app shows. A cheap
    /// synchronous read of the on-disk mirror — the refresher is somebody else's
    /// job, and a lesson must never wait on the network to start.
    static func liveWeeklyURLString(for app: LunaApp) -> String? {
        WeeklySaveStore.shared
            .liveDisplays(for: WeeklySaveKind.kinds(for: app))
            .first?.save.urlString
    }
}

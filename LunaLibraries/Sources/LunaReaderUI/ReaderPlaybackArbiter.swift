//
//  ReaderPlaybackArbiter.swift
//  LunaReaderUI
//
//  Two readers on one screen, one voice — and one moving word.
//

import UIKit

/// A reader that can be told to stop because the reader beside it started.
@MainActor
public protocol ReaderPlaybackPausable: AnyObject {
    func pauseForExclusivePlayback()
}

/// Keeps at most one reader playing while two of them share the screen.
///
/// Read-aloud was already exclusive on its own: every in-app voice goes through
/// the single `AudioPlaybackCenter`, which plays one item at a time. The SILENT
/// speed reader is what isn't — its word timer is per-instance, so two RSVP
/// columns would both march, and a silent column would keep marching while the
/// other one was being read out loud. This closes both gaps from one place.
///
/// **Why the pairing switch.** Luna deliberately keeps read-aloud going when you
/// navigate away — that is the whole point of background audio and the
/// mini-player. A rule that paused the current voice whenever any reader started
/// playing would silence a backgrounded article the moment you opened another
/// card. So the arbiter always records who is playing, but only ENFORCES while
/// two readers are actually side by side, which is the only situation the rule
/// is about.
@MainActor
public enum ReaderPlaybackArbiter {

    /// True only while two readers share the screen (the iPad's paired reader
    /// columns). The host that pairs them owns this.
    public static var isPaired = false {
        didSet {
            // Unpairing settles nothing: whoever is playing keeps playing. Only
            // the *next* claim stops mattering.
            guard !isPaired else { return }
            holder = nil
        }
    }

    private static weak var holder: ReaderPlaybackPausable?

    /// `player` is starting. While paired, whoever held playback is paused.
    public static func claim(_ player: ReaderPlaybackPausable) {
        if isPaired, let previous = holder, previous !== player {
            previous.pauseForExclusivePlayback()
        }
        holder = player
    }

    /// `player` stopped. Clears the claim only if it still holds it, so a stale
    /// pause from a torn-down reader can't blank out its successor.
    public static func resign(_ player: ReaderPlaybackPausable) {
        guard holder === player else { return }
        holder = nil
    }

    /// Whether `player` is the one currently allowed to play. Diagnostics and
    /// tests only — no production branch reads this.
    public static func holds(_ player: ReaderPlaybackPausable) -> Bool {
        holder === player
    }
}

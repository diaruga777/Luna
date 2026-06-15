//
//  AppReaderProviders.swift
//  Clip
//

import UIKit

/// Main-app sharing provider, backed by the social stack (ShareSuggestionStore
/// + SendToFriendSheet → CloudKit). Injected into readers in the main app; the
/// share extension passes nil instead, so neither this type nor CloudKit is
/// compiled into the extension.
final class AppReaderShareProvider: ReaderShareProviding {
    static let shared = AppReaderShareProvider()

    func suggestedFriendName(forURLString urlString: String) -> String? {
        ShareSuggestionStore.shared.suggestedFriend(forURLString: urlString)?.username
    }

    func presentShareSheet(
        urlString: String, title: String?, from presenter: UIViewController, sourceView: UIView
    ) {
        SendToFriendSheet.present(
            from: presenter, sourceView: sourceView, urlString: urlString, title: title)
    }

    func sendToSuggestedFriend(urlString: String, title: String?, from presenter: UIViewController) {
        guard let suggestion = ShareSuggestionStore.shared.suggestedFriend(forURLString: urlString)
        else { return }
        SendToFriendSheet.sendToFriend(
            uuid: suggestion.uuid, urlString: urlString, title: title, from: presenter)
    }
}

/// Main-app gaze-tracker factory: a real `EyeGazeWordTracker` when eye tracking
/// is enabled, else nil. The extension never uses this (no camera/ARKit).
enum AppGazeTracker {
    static let factory: GazeTrackerFactory = { textView, wordMap, seed in
        guard ReaderSettings.eyeTrackingEnabled else { return nil }
        return EyeGazeWordTracker(textView: textView, wordMap: wordMap, seedWordIndex: seed)
    }
}

extension EyeGazeWordTracker: GazeTracking {}

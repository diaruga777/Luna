//
//  ScreenAnalysisPromptIntent.swift
//  Clip
//

import ClipIntents
import AppIntents

/// Returns the screen-analysis prompt for extracting user-visible identifying
/// metadata from the current app's screen. When a prompt is returned, the shortcut
/// appends a screenshot and runs prompt + image through an image-understanding
/// model; the result feeds `SaveFromAppIntent`. Returns an empty string for a
/// supported app that needs no prompt (Safari — the tracked page URL is saved), and
/// the exact string "unsupported" when the current app isn't one Quartz can save from
/// (the shortcut branches on that).
public struct ScreenAnalysisPromptIntent: AppIntent {
    public init() {}
    public static let title: LocalizedStringResource = "Screen Analysis Prompt"
    public static let description = IntentDescription("""
        Returns a prompt to extract identifying metadata from the current app's \
        screen. Pass the current app. If the result is non-empty, attach a \
        screenshot of the screen and run the prompt and image through an \
        image-understanding model, then pass the answer to Save from App. Returns \
        "unsupported" when the current app can't be saved from, and empty when it \
        needs no prompt.
        """)
    public static let openAppWhenRun: Bool = false

    @Parameter(title: "App", description: "The current app, from Get Current App.")
    public var app: String?

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let app else { return .result(value: "unsupported") }
        if let prompt = AppNamePlatform.screenPrompt(forAppName: app) {
            return .result(value: prompt)
        }
        // Supported but no prompt (Safari) → empty; otherwise "unsupported".
        return .result(value: AppNamePlatform.isSupported(forAppName: app) ? "" : "unsupported")
    }
}

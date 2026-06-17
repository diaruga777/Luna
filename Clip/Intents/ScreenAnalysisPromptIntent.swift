//
//  ScreenAnalysisPromptIntent.swift
//  Clip
//

import AppIntents

/// Returns the Apple-Intelligence prompt for extracting user-visible identifying
/// metadata from the current app's screen, or an empty string when none applies
/// (Safari, unknown apps — the shortcut then skips taking a screenshot). When a
/// prompt is returned, the shortcut appends a screenshot of the current screen
/// and sends prompt + image to Apple Intelligence; the result feeds `SaveFromAppIntent`.
struct ScreenAnalysisPromptIntent: AppIntent {
    static let title: LocalizedStringResource = "Screen Analysis Prompt"
    static let description = IntentDescription("""
        Returns an Apple Intelligence prompt to extract identifying metadata from \
        the current app's screen, or empty if none applies. Pass the current app \
        (from Get Current App). If the result is non-empty, append a screenshot of \
        the screen and send both to Apple Intelligence; feed its answer to "Save from App".
        """)
    static let openAppWhenRun: Bool = false

    @Parameter(title: "App", description: "The current app, from Get Current App.")
    var app: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: AppNamePlatform.screenPrompt(forAppName: app) ?? "")
    }
}

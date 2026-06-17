//
//  ScreenAnalysisPromptIntent.swift
//  Clip
//

import AppIntents

/// Returns the screen-analysis prompt for extracting user-visible identifying
/// metadata from the current app's screen, or an empty string when none applies
/// (the shortcut then skips taking a screenshot). When a prompt is returned, the
/// shortcut appends a screenshot and runs prompt + image through an
/// image-understanding model; the result feeds `SaveFromAppIntent`.
struct ScreenAnalysisPromptIntent: AppIntent {
    static let title: LocalizedStringResource = "Screen Analysis Prompt"
    static let description = IntentDescription("""
        Returns a prompt to extract identifying metadata from the current app's \
        screen, or empty if none applies. Pass the current app. If the result is \
        non-empty, attach a screenshot of the screen and run the prompt and image \
        through an image-understanding model, then pass the answer to Save from App.
        """)
    static let openAppWhenRun: Bool = false

    @Parameter(title: "App", description: "The current app, from Get Current App.")
    var app: String?

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: app.flatMap { AppNamePlatform.screenPrompt(forAppName: $0) } ?? "")
    }
}

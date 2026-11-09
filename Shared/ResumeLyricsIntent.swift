import AppIntents

/// "Resume" button inside the Live Activity (shown when the card is stale).
///
/// LiveActivityIntents always run in the APP's process (the system launches it
/// in the background if needed), so this file is compiled into both targets:
/// the widget needs the type for `Button(intent:)`, the app runs `perform()`.
/// `CARLYRICS_APP` is only defined for the app target (see project.yml).
struct ResumeLyricsIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Resume CarLyrics"
    static var description = IntentDescription("Resumes the lyrics session and the Live Activity.")
    static var isDiscoverable: Bool = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        #if CARLYRICS_APP
        LyricsSessionModel.shared.resume(reason: "Live Activity button")
        #endif
        return .result()
    }
}

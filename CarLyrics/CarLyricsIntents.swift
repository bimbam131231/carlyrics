import AppIntents

/// "Start CarLyrics" — meant for a Shortcuts automation "When CarPlay connects"
/// (set it to run without asking). As a LiveActivityIntent it may start the
/// Live Activity from the background. If that fails on device, set
/// `openAppWhenRun = true` (the app then opens briefly to start).
struct StartCarLyricsIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Start CarLyrics"
    static var description = IntentDescription(
        "Starts Spotify lyrics sync and a fresh Live Activity (e.g. when CarPlay connects).")
    static var openAppWhenRun: Bool = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        LyricsSessionModel.shared.start(reason: "Shortcut")
        return .result()
    }
}

struct StopCarLyricsIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop CarLyrics"
    static var description = IntentDescription("Stops lyrics sync and ends the Live Activity.")
    static var openAppWhenRun: Bool = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        LyricsSessionModel.shared.stop(reason: "Shortcut")
        return .result()
    }
}

struct CarLyricsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartCarLyricsIntent(),
            phrases: ["Start \(.applicationName)"],
            shortTitle: "Start CarLyrics",
            systemImageName: "music.note"
        )
        AppShortcut(
            intent: StopCarLyricsIntent(),
            phrases: ["Stop \(.applicationName)"],
            shortTitle: "Stop CarLyrics",
            systemImageName: "stop.circle"
        )
    }
}

import AppIntents

/// "Start CarLyrics" — meant for a Shortcuts automation "When CarPlay connects"
/// (set it to run without asking). It first tries to start from the background
/// (LiveActivityIntent). If that isn't fully effective (not connected, Live
/// Activity refused, or location keep-alive can't start in the background
/// without "Always" permission), it asks to continue in the foreground: the
/// app opens and the start is repeated there.
struct StartCarLyricsIntent: LiveActivityIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Start CarLyrics"
    static var description = IntentDescription(
        "Starts Spotify lyrics sync and a fresh Live Activity (e.g. when CarPlay connects).")
    static var openAppWhenRun: Bool = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = LyricsSessionModel.shared
        if model.start(reason: "Shortcut") {
            return .result()
        }
        model.log("Shortcut: background start not effective, opening the app")
        throw needsToContinueInForegroundError(IntentDialog("Opening CarLyrics to start lyrics.")) {
            _ = LyricsSessionModel.shared.start(reason: "Shortcut (foreground)")
        }
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

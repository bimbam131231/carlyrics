import ActivityKit
import SwiftUI

struct ContentView: View {
    @State private var activity: Activity<LyricsActivityAttributes>?
    @State private var status = "Idle"
    @State private var testIndex = 0

    /// A fake "song" mixing Hebrew, English and mixed-direction lines.
    private let testLines: [String] = [
        "Here comes the morning light",
        "שמש עולה מעל העיר",
        "Tel Aviv בלילה, the city never sleeps",
        "אני שומע את ה-radio מתנגן",
        "Every line in its own direction",
        "וזה נראה בדיוק כמו שצריך",
        "One more line to end the test",
    ]

    /// (background, accent) pairs to test the album-color gradient and contrast.
    private let testThemes: [(String, String)] = [
        ("#1E3A5F", "#E07A5F"), // deep blue / coral
        ("#2D1B4E", "#C77DFF"), // purple
        ("#F1E3C8", "#C98A3D"), // light cream -> dark text
        ("#0B3D2E", "#4ADE80"), // green
        ("#7A1F1F", "#F59E0B"), // red / amber
        ("#D9EEF7", "#4A90B8"), // light sky -> dark text
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("CarLyrics").font(.largeTitle.bold())
                Text(status).font(.footnote).foregroundStyle(.secondary)

                preview

                Button("Start test Live Activity") { start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(activity != nil)

                Button("Next test line") { next() }
                    .buttonStyle(.bordered)

                Button("Stop", role: .destructive) { stop() }
                    .buttonStyle(.bordered)
                    .disabled(activity == nil)
            }
            .padding()
        }
    }

    private var preview: some View {
        let s = state(for: testIndex)
        let theme = LyricsTheme(state: s)
        return VStack(spacing: 12) {
            LyricsStackView(state: s, theme: theme)
                .background(LyricsBackground(theme: theme))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            CarPlayLyricsView(state: s, theme: theme)
                .frame(width: 200, height: 90)
                .background(LyricsBackground(theme: theme))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .animation(.easeInOut(duration: 0.3), value: testIndex)
    }

    private func state(for index: Int) -> LyricsActivityAttributes.ContentState {
        let n = testLines.count
        let i = index % n
        let (bg, accent) = testThemes[index % testThemes.count]
        return .init(
            previous: i > 0 ? testLines[i - 1] : "",
            current: testLines[i],
            next: i + 1 < n ? testLines[i + 1] : "",
            trackTitle: "Test Track",
            artist: "Test Artist",
            backgroundColorHex: bg,
            accentColorHex: accent
        )
    }

    private func start() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            status = "Live Activities are disabled in Settings"
            return
        }
        do {
            activity = try Activity.request(
                attributes: LyricsActivityAttributes(),
                content: .init(state: state(for: testIndex), staleDate: nil),
                pushType: nil
            )
            status = "Activity started"
        } catch {
            status = "Failed: \(error.localizedDescription)"
        }
    }

    private func next() {
        testIndex += 1
        status = "Line \(testIndex % testLines.count + 1), theme \(testIndex % testThemes.count + 1)"
        guard let activity else { return }
        let content = ActivityContent(state: state(for: testIndex), staleDate: nil)
        Task { await activity.update(content) }
    }

    private func stop() {
        guard let activity else { return }
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        self.activity = nil
        status = "Stopped"
    }
}

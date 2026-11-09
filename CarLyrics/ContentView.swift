import ActivityKit
import SwiftUI

struct ContentView: View {
    @State private var activity: Activity<LyricsActivityAttributes>?
    @State private var status = "Idle"
    @State private var testIndex = 0

    private let testLines: [(String, String)] = [
        ("Hello from CarLyrics", "This is a test Live Activity"),
        ("שלום מקאר-ליריקס", "זו שורה בעברית"),
        ("Mixed line works too", "Last test line"),
    ]

    var body: some View {
        VStack(spacing: 20) {
            Text("CarLyrics").font(.largeTitle.bold())
            Text(status).font(.footnote).foregroundStyle(.secondary)

            Button("Start test Live Activity") { start() }
                .buttonStyle(.borderedProminent)
                .disabled(activity != nil)

            Button("Next test line") { next() }
                .buttonStyle(.bordered)
                .disabled(activity == nil)

            Button("Stop", role: .destructive) { stop() }
                .buttonStyle(.bordered)
                .disabled(activity == nil)
        }
        .padding()
    }

    private func state(for index: Int) -> LyricsActivityAttributes.ContentState {
        let (cur, nxt) = testLines[index % testLines.count]
        return .init(
            currentLine: cur,
            nextLine: nxt,
            isRTLCurrent: TextDirection.isRTL(cur),
            isRTLNext: TextDirection.isRTL(nxt),
            trackTitle: "Test Track",
            artist: "Test Artist"
        )
    }

    private func start() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            status = "Live Activities are disabled in Settings"
            return
        }
        do {
            testIndex = 0
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
        guard let activity else { return }
        testIndex += 1
        let content = ActivityContent(state: state(for: testIndex), staleDate: nil)
        Task { await activity.update(content) }
        status = "Updated to line \(testIndex % testLines.count + 1)"
    }

    private func stop() {
        guard let activity else { return }
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        self.activity = nil
        status = "Stopped"
    }
}

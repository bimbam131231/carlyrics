import SwiftUI

struct ContentView: View {
    @ObservedObject private var model = LyricsSessionModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("CarLyrics").font(.largeTitle.bold())

                spotifySection
                nowPlayingSection
                sessionButtons

                Divider().padding(.vertical, 4)
                TestActivitySection()

                Divider().padding(.vertical, 4)
                DebugLogView(logs: model.logs)
            }
            .padding()
        }
        .onOpenURL { url in
            // Tapping the Live Activity opens carlyrics://resume
            if url.scheme == "carlyrics", url.host == "resume" {
                model.resume(reason: "Live Activity tap")
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.appBecameActive() }
        }
    }

    // MARK: Spotify

    private var spotifySection: some View {
        VStack(spacing: 8) {
            Text(model.status)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if model.isConnected {
                Button("Disconnect Spotify", role: .destructive) { model.disconnect() }
                    .font(.footnote)
            } else {
                Button("Connect Spotify") { Task { await model.connect() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
            }
        }
    }

    // MARK: Now playing

    private var nowPlayingSection: some View {
        let state = model.cardState
        let theme = LyricsTheme(state: state)
        return VStack(spacing: 10) {
            if let track = model.track {
                VStack(spacing: 2) {
                    Text(track.title).font(.headline).lineLimit(1)
                    Text(track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Text(model.positionText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Group {
                if case .synced(let lines) = model.lyricsStatus {
                    ScrollingLyricsView(lines: lines, currentIndex: model.lineIndex, theme: theme)
                        .id(model.track?.id)
                } else {
                    LyricsStackView(state: state, theme: theme, showsTrackInfo: false)
                        .frame(height: 210)
                }
            }
            .background(LyricsBackground(theme: theme))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: state)
        }
    }

    private var sessionButtons: some View {
        HStack(spacing: 12) {
            Button("Start") { model.start(reason: "app button") }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isConnected || model.isRunning)
            Button("Stop", role: .destructive) { model.stop(reason: "app button") }
                .buttonStyle(.bordered)
                .disabled(!model.isRunning)
        }
    }
}

struct DebugLogView: View {
    let logs: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Debug log").font(.caption.bold()).foregroundStyle(.secondary)
            if logs.isEmpty {
                Text("No events yet").font(.caption2).foregroundStyle(.tertiary)
            }
            ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

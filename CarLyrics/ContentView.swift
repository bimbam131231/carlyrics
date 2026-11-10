import SwiftUI

struct ContentView: View {
    @ObservedObject private var model = LyricsSessionModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(LyricsSessionModel.autoStartKey) private var autoStart = true
    @State private var showDeveloper = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("CarLyrics").font(.largeTitle.bold())

                spotifySection
                nowPlayingSection
                sessionButtons
                settingsSection

                Divider().padding(.vertical, 4)
                DisclosureGroup("Developer", isExpanded: $showDeveloper) {
                    VStack(spacing: 18) {
                        TestActivitySection()
                        Divider()
                        MissingLyricsView(entries: model.missingEntries,
                                          report: model.missingLyricsReport,
                                          onClear: { model.clearMissingLyrics() })
                        Divider()
                        diagnosticsButtons
                        DebugLogView(logs: model.logs)
                    }
                    .padding(.top, 12)
                }
                .font(.subheadline)
            }
            .padding()
        }
        .onAppear { model.autoStartIfNeeded() }
        .onOpenURL { url in
            // Tapping the Live Activity opens carlyrics://resume
            if url.scheme == "carlyrics", url.host == "resume" {
                model.resume(reason: "Live Activity tap")
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.appBecameActive()
                model.autoStartIfNeeded()
            }
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

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Auto-start", isOn: $autoStart)
                .font(.subheadline)
            Text("Start lyrics automatically when the app opens and Spotify is connected "
                 + "(for the \"When CarPlay connects\" Shortcuts automation).")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var diagnosticsButtons: some View {
        HStack(spacing: 10) {
            Button("Log audio status") { model.logAudioStatus() }
            ShareLink(item: LyricsSessionModel.logFileURL) {
                Label("Share log", systemImage: "square.and.arrow.up")
            }
            Button("Clear", role: .destructive) { model.clearLogs() }
        }
        .font(.caption)
        .buttonStyle(.bordered)
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

/// Tracks where every LRCLIB attempt failed, with the queries tried.
struct MissingLyricsView: View {
    let entries: [MissingLyricsEntry]
    let report: String
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Missing lyrics (\(entries.count))").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                ShareLink(item: report) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(entries.isEmpty)
                Button("Clear", role: .destructive, action: onClear)
                    .disabled(entries.isEmpty)
            }
            .font(.caption)
            .buttonStyle(.bordered)

            if entries.isEmpty {
                Text("No misses yet").font(.caption2).foregroundStyle(.tertiary)
            }
            ForEach(entries) { e in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 3) {
                        detail("he", e.hebrewNames?.summary ?? "unavailable")
                        detail("en", e.englishNames?.summary ?? "unavailable")
                        detail("album", e.album)
                        detail("duration", "\(e.durationSeconds / 60):\(String(format: "%02d", e.durationSeconds % 60))")
                        detail("result", e.outcome)
                        Text("Queries (\(e.queries.count)):")
                            .font(.caption2.bold()).foregroundStyle(.secondary).padding(.top, 2)
                        ForEach(Array(e.queries.enumerated()), id: \.offset) { _, q in
                            Text(q)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.top, 4)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title).font(.caption.bold()).lineLimit(1)
                        Text(e.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detail(_ key: String, _ value: String) -> some View {
        (Text(key + ": ").bold() + Text(value))
            .font(.caption2)
            .frame(maxWidth: .infinity, alignment: .leading)
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

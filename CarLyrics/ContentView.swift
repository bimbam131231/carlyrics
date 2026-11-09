import SwiftUI

struct ContentView: View {
    @ObservedObject private var model = LyricsSessionModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(LocationKeepAlive.settingKey) private var locationKeepAlive = false
    @AppStorage(LiveActivityController.minimalSettingKey) private var minimalLiveActivity = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("CarLyrics").font(.largeTitle.bold())

                spotifySection
                nowPlayingSection
                sessionButtons
                settingsSection

                Divider().padding(.vertical, 4)
                TestActivitySection()

                Divider().padding(.vertical, 4)
                diagnosticsButtons
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

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Plan B: keep alive with location", isOn: $locationKeepAlive)
                .font(.subheadline)
                .onChange(of: locationKeepAlive) { _, enabled in
                    model.locationSettingChanged(enabled)
                }
            Text("Low-accuracy location updates keep the app running when locked. "
                 + "For the car (phone charging). Shows the blue location indicator.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Toggle("Minimal Live Activity", isOn: $minimalLiveActivity)
                .font(.subheadline)
                .padding(.top, 6)
                .onChange(of: minimalLiveActivity) { _, enabled in
                    model.minimalSettingChanged(enabled)
                }
            Text("Diagnostic: plain white text on black, no gradient, shadow or animation. "
                 + "The \"#N\" in the card corner is the update number iOS rendered.")
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

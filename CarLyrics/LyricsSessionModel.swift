import ActivityKit
import Foundation

enum LyricsStatus: Equatable {
    case idle
    case loading
    case synced([LyricLine])
    case plainOnly
    case instrumental
    case notFound
    case failed(String)
}

/// The whole lyrics session: Spotify polling + local position estimate +
/// synced line + Live Activity + silent-audio keep-alive.
///
/// Polling only stops when: the user taps Stop (app / Shortcut), nothing has
/// played for 2 minutes, or the Spotify login is unrecoverable. Each of those
/// is logged and shown. Every failure goes to the debug log.
@MainActor
final class LyricsSessionModel: ObservableObject {
    static let shared = LyricsSessionModel()

    @Published private(set) var isConnected: Bool
    @Published private(set) var isRunning = false
    @Published private(set) var status: String
    @Published private(set) var track: SpotifyTrack?
    @Published private(set) var isPlaying = false
    @Published private(set) var lyricsStatus: LyricsStatus = .idle
    @Published private(set) var lineIndex: Int?
    @Published private(set) var positionSeconds = 0
    @Published private(set) var backgroundHex = Config.defaultBackgroundHex
    @Published private(set) var accentHex = Config.defaultAccentHex
    @Published private(set) var logs: [String] = []

    private let auth: SpotifyAuth
    private let client: SpotifyClient
    private let lyricsProvider: LRCLIBProvider
    private let cache: LyricsCache
    private let colorLoader: AlbumColorLoader
    private let audio: KeepAliveAudio
    private let liveActivity: LiveActivityController

    private var snapshot: PlaybackSnapshot?
    private var pollTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var colorTask: Task<Void, Never>?

    private var consecutiveFailures = 0
    /// Since when nothing is playing / playback is paused (nil while playing).
    private var idleSince: Date?
    private var lastAudioCheck = Date.distantPast
    private var lastActivityRestart = Date.distantPast

    static let idleStopAfter: TimeInterval = 120
    static let maxBackoff: TimeInterval = 30

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private init() {
        let spotifyAuth = SpotifyAuth()
        let connected = spotifyAuth.hasRefreshToken
        auth = spotifyAuth
        client = SpotifyClient(auth: spotifyAuth)
        lyricsProvider = LRCLIBProvider()
        cache = LyricsCache()
        colorLoader = AlbumColorLoader()
        audio = KeepAliveAudio()
        liveActivity = LiveActivityController()
        isConnected = connected
        status = connected ? "Connected to Spotify" : "Not connected"

        auth.onLog = { [weak self] in self?.log($0) }
        lyricsProvider.onLog = { [weak self] in self?.log($0) }
        audio.onLog = { [weak self] in self?.log($0) }
        liveActivity.onLog = { [weak self] in self?.log($0) }
        liveActivity.onEndedExternally = { [weak self] state in self?.activityEndedExternally(state) }
    }

    // MARK: - Spotify connection

    func connect() async {
        status = "Connecting…"
        do {
            try await auth.connect()
            isConnected = true
            status = "Connected to Spotify"
        } catch {
            status = error.localizedDescription
            log("Connect failed: \(error.localizedDescription)")
        }
    }

    func disconnect() {
        stop(reason: "disconnect")
        auth.disconnect()
        isConnected = false
        track = nil
        lyricsStatus = .idle
        status = "Not connected"
        log("Disconnected")
    }

    // MARK: - Session control

    /// Start (or restart) the session with a FRESH Live Activity.
    /// Ending the old activity on every start handles the 8-hour limit.
    func start(reason: String) {
        guard isConnected else {
            status = "Connect Spotify first"
            log("Start (\(reason)) ignored: not connected")
            return
        }
        log("Start (\(reason))")
        idleSince = nil
        audio.start()
        if !isRunning { launchLoops() }
        liveActivity.startFresh(cardState)
        lastActivityRestart = Date()
    }

    /// Resume after the card went stale / the app was suspended or relaunched.
    /// Keeps a still-visible activity instead of replacing it.
    func resume(reason: String) {
        guard isConnected else {
            log("Resume (\(reason)) ignored: not connected")
            return
        }
        log("Resume (\(reason))")
        idleSince = nil
        audio.start()
        if isRunning {
            pollTask?.cancel()
            pollTask = Task { [weak self] in await self?.pollLoop() }
        } else {
            launchLoops()
        }
        liveActivity.attachOrStart(cardState)
    }

    func stop(reason: String) {
        guard isRunning || liveActivity.hasActivity else { return }
        pollTask?.cancel()
        tickTask?.cancel()
        pollTask = nil
        tickTask = nil
        isRunning = false
        audio.stop()
        liveActivity.end()
        status = isConnected ? "Stopped" : "Not connected"
        log("Session stopped (\(reason))")
    }

    /// App came to the foreground: make sure everything is alive.
    func appBecameActive() {
        guard isRunning else { return }
        audio.ensurePlaying()
        if !liveActivity.hasActivity {
            log("Foreground: Live Activity missing, restarting it")
            liveActivity.attachOrStart(cardState)
        }
    }

    private func launchLoops() {
        isRunning = true
        consecutiveFailures = 0
        status = "Starting…"
        pollTask = Task { [weak self] in await self?.pollLoop() }
        tickTask = Task { [weak self] in await self?.tickLoop() }
    }

    private func activityEndedExternally(_ state: ActivityState) {
        guard isRunning else { return }
        // E.g. 8-hour limit reached, or swiped away. Start a new one (rate limited).
        guard Date().timeIntervalSince(lastActivityRestart) > 60 else {
            log("Live Activity ended again within 60s, not restarting (tap Start)")
            return
        }
        lastActivityRestart = Date()
        if !liveActivity.startFresh(cardState) {
            log("Could not restart Live Activity from background; open the app or tap Resume")
        }
    }

    // MARK: - Loops

    private func pollLoop() async {
        while !Task.isCancelled {
            var delay = Config.pollInterval
            do {
                let result = try await client.currentlyPlaying()
                if Task.isCancelled { return }
                if consecutiveFailures > 0 {
                    log("Spotify reachable again after \(consecutiveFailures) failure(s)")
                    consecutiveFailures = 0
                }
                switch result {
                case .playing(let snap):
                    apply(snap)
                case .nothingPlaying:
                    apply(nil)
                case .rateLimited(let retryAfter):
                    log("Spotify rate limited (429), waiting \(Int(retryAfter))s")
                    delay = max(retryAfter, delay)
                }
            } catch {
                if Task.isCancelled { return }
                if let e = error as? SpotifyError, case .notConnected = e {
                    isConnected = false
                    log("Spotify login is no longer valid")
                    // Leave a visible message on the card for a few minutes.
                    var msg = cardState
                    msg.currentLine = "Reconnect Spotify in CarLyrics"
                    msg.isRTLCurrent = false
                    msg.nextLine = ""
                    msg.previousLine = ""
                    msg.lineID = -100
                    pollTask = nil
                    tickTask?.cancel()
                    tickTask = nil
                    isRunning = false
                    audio.stop()
                    liveActivity.end(final: msg, dismissAfter: 300)
                    status = "Spotify login expired, please reconnect"
                    return
                }
                consecutiveFailures += 1
                delay = min(Self.maxBackoff, pow(2, Double(consecutiveFailures)))
                log("Poll failed (#\(consecutiveFailures)): \(error.localizedDescription) — retry in \(Int(delay))s")
                status = "Network issue, retrying in \(Int(delay))s…"
            }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func tickLoop() async {
        while !Task.isCancelled {
            updatePosition()
            housekeeping()
            if !isRunning { return }
            liveActivity.push(cardState)
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func housekeeping() {
        let now = Date()
        if now.timeIntervalSince(lastAudioCheck) > 15 {
            lastAudioCheck = now
            audio.ensurePlaying()
        }
        if let idleSince, now.timeIntervalSince(idleSince) > Self.idleStopAfter {
            stop(reason: "nothing playing for 2 minutes")
            self.idleSince = nil
        }
    }

    // MARK: - State updates

    private func apply(_ snap: PlaybackSnapshot?) {
        snapshot = snap
        guard let snap, let newTrack = snap.track else {
            if idleSince == nil { idleSince = Date() }
            if isPlaying || status != "Nothing playing" { log("Nothing playing") }
            isPlaying = false
            status = "Nothing playing"
            return
        }
        if snap.isPlaying != isPlaying {
            isPlaying = snap.isPlaying
            log(snap.isPlaying ? "Playing" : "Paused")
        }
        if snap.isPlaying {
            idleSince = nil
        } else if idleSince == nil {
            idleSince = Date()
        }
        status = snap.isPlaying ? "Playing" : "Paused"
        if newTrack.id != track?.id { trackChanged(newTrack) }
        updatePosition()
    }

    private func updatePosition() {
        guard let snapshot, snapshot.track != nil else { return }
        let pos = snapshot.position()
        let sec = Int(pos)
        if sec != positionSeconds { positionSeconds = sec }
        if case .synced(let lines) = lyricsStatus {
            let idx = LRCParser.index(at: pos + Config.lyricsLeadSeconds, in: lines)
            if idx != lineIndex { lineIndex = idx }
        }
    }

    private func trackChanged(_ t: SpotifyTrack) {
        track = t
        lineIndex = nil
        log("Track: \(t.title) — \(t.artist)")
        lyricsTask?.cancel()
        colorTask?.cancel()
        lyricsTask = Task { [weak self] in await self?.loadLyrics(for: t) }
        colorTask = Task { [weak self] in await self?.loadColors(for: t) }
    }

    private func loadLyrics(for t: SpotifyTrack) async {
        if let cached = cache.get(t.id) {
            setLyrics(cached, source: "cache")
            return
        }
        lyricsStatus = .loading
        let query = LyricsQuery(title: t.title, artist: t.primaryArtist, album: t.album, duration: t.duration)
        do {
            let result = try await lyricsProvider.fetchLyrics(for: query)
            guard !Task.isCancelled, track?.id == t.id else { return }
            cache.set(result, for: t.id)
            setLyrics(result, source: lyricsProvider.name)
        } catch {
            guard !Task.isCancelled, track?.id == t.id else { return }
            lyricsStatus = .failed(error.localizedDescription)
            log("Lyrics failed: \(error.localizedDescription)")
        }
    }

    private func setLyrics(_ result: LyricsResult, source: String) {
        switch result {
        case .synced(let lines):
            lyricsStatus = .synced(lines)
            log("Synced lyrics: \(lines.count) lines (\(source))")
        case .plainOnly:
            lyricsStatus = .plainOnly
            log("Only plain lyrics (\(source))")
        case .instrumental:
            lyricsStatus = .instrumental
            log("Instrumental (\(source))")
        case .notFound:
            lyricsStatus = .notFound
            log("No lyrics found (\(source))")
        }
        lineIndex = nil
        updatePosition()
    }

    private func loadColors(for t: SpotifyTrack) async {
        var colors: (background: String, accent: String)?
        if let url = t.imageURL { colors = await colorLoader.colors(for: url) }
        guard !Task.isCancelled, track?.id == t.id else { return }
        if colors == nil, t.imageURL != nil { log("Album colors unavailable, using defaults") }
        backgroundHex = colors?.background ?? Config.defaultBackgroundHex
        accentHex = colors?.accent ?? Config.defaultAccentHex
    }

    // MARK: - Display

    /// Three-line card content, used by the app card and the Live Activity.
    var cardState: LyricsActivityAttributes.ContentState {
        let title = track?.title ?? ""
        let artist = track?.artist ?? ""
        let bg = backgroundHex, accent = accentHex
        func make(_ previous: String, _ current: String, _ next: String,
                  _ id: Int = -100) -> LyricsActivityAttributes.ContentState {
            .init(previous: previous, current: current, next: next,
                  trackTitle: title, artist: artist,
                  backgroundColorHex: bg, accentColorHex: accent, lineID: id)
        }

        guard track != nil else {
            return make("", isConnected ? (isRunning ? "Nothing playing" : "Press Start") : "Connect Spotify", "")
        }
        switch lyricsStatus {
        case .idle, .loading: return make("", "Loading lyrics…", title)
        case .plainOnly: return make("", "No synced lyrics", title)
        case .instrumental: return make("", "Instrumental ♪", title)
        case .notFound: return make("", "No lyrics found", title)
        case .failed: return make("", "Lyrics unavailable", title)
        case .synced(let lines):
            func text(_ i: Int) -> String {
                guard lines.indices.contains(i) else { return "" }
                return lines[i].text.isEmpty ? "♪" : lines[i].text
            }
            guard let i = lineIndex else { return make("", "♪", text(0), -1) }
            return make(text(i - 1), text(i), text(i + 1), i)
        }
    }

    var positionText: String {
        guard let track else { return "" }
        return "\(Self.mmss(positionSeconds)) / \(Self.mmss(Int(track.duration)))"
    }

    private static func mmss(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }

    // MARK: - Debug log

    func log(_ message: String) {
        let line = "\(Self.timeFormatter.string(from: Date()))  \(message)"
        logs.insert(line, at: 0)
        if logs.count > 50 { logs.removeLast(logs.count - 50) }
    }
}

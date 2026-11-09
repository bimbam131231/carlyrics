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

/// Spotify polling + local position estimate + synced lyric line.
/// Phase 4 will feed `cardState` into the Live Activity.
@MainActor
final class LyricsSessionModel: ObservableObject {
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

    private var snapshot: PlaybackSnapshot?
    private var pollTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var colorTask: Task<Void, Never>?

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init() {
        let spotifyAuth = SpotifyAuth()
        let connected = spotifyAuth.hasRefreshToken
        auth = spotifyAuth
        client = SpotifyClient(auth: spotifyAuth)
        lyricsProvider = LRCLIBProvider()
        cache = LyricsCache()
        colorLoader = AlbumColorLoader()
        isConnected = connected
        status = connected ? "Connected to Spotify" : "Not connected"
        auth.onLog = { [weak self] in self?.log($0) }
        lyricsProvider.onLog = { [weak self] in self?.log($0) }
    }

    // MARK: - Actions

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
        stop()
        auth.disconnect()
        isConnected = false
        track = nil
        lyricsStatus = .idle
        status = "Not connected"
        log("Disconnected")
    }

    func start() {
        guard isConnected, !isRunning else { return }
        isRunning = true
        status = "Starting…"
        log("Session started")
        pollTask = Task { [weak self] in await self?.pollLoop() }
        tickTask = Task { [weak self] in await self?.tickLoop() }
    }

    func stop() {
        guard isRunning else { return }
        pollTask?.cancel()
        tickTask?.cancel()
        pollTask = nil
        tickTask = nil
        isRunning = false
        status = isConnected ? "Stopped" : "Not connected"
        log("Session stopped")
    }

    // MARK: - Loops

    private func pollLoop() async {
        while !Task.isCancelled {
            var delay = Config.pollInterval
            do {
                switch try await client.currentlyPlaying() {
                case .playing(let snap):
                    apply(snap)
                case .nothingPlaying:
                    apply(nil)
                case .rateLimited(let retryAfter):
                    log("Rate limited (429), waiting \(Int(retryAfter))s")
                    delay = max(retryAfter, delay)
                }
            } catch {
                if Task.isCancelled { return }
                if let e = error as? SpotifyError, case .notConnected = e {
                    isConnected = false
                    stop()
                    status = "Spotify login expired, please reconnect"
                    return
                }
                log("Poll error: \(error.localizedDescription)")
                status = "Network issue, retrying…"
                delay = 5
            }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func tickLoop() async {
        while !Task.isCancelled {
            updatePosition()
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // MARK: - State updates

    private func apply(_ snap: PlaybackSnapshot?) {
        snapshot = snap
        guard let snap, let newTrack = snap.track else {
            if isPlaying || status != "Nothing playing" { log("Nothing playing") }
            isPlaying = false
            status = "Nothing playing"
            return
        }
        if snap.isPlaying != isPlaying {
            isPlaying = snap.isPlaying
            log(snap.isPlaying ? "Playing" : "Paused")
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
        backgroundHex = colors?.background ?? Config.defaultBackgroundHex
        accentHex = colors?.accent ?? Config.defaultAccentHex
    }

    // MARK: - Display

    /// Three-line card content (same shape the Live Activity will use in Phase 4).
    var cardState: LyricsActivityAttributes.ContentState {
        let title = track?.title ?? ""
        let artist = track?.artist ?? ""
        let bg = backgroundHex, accent = accentHex
        func make(_ previous: String, _ current: String, _ next: String) -> LyricsActivityAttributes.ContentState {
            .init(previous: previous, current: current, next: next,
                  trackTitle: title, artist: artist,
                  backgroundColorHex: bg, accentColorHex: accent)
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
            guard let i = lineIndex else { return make("", "♪", text(0)) }
            return make(text(i - 1), text(i), text(i + 1))
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

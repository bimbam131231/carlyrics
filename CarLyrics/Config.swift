import Foundation

enum Config {
    /// Spotify app Client ID (not a secret when using PKCE).
    static let spotifyClientID = "78eb3eb09ae143029ef5014fef4af85e"
    static let spotifyRedirectURI = "carlyrics://callback"
    static let spotifyCallbackScheme = "carlyrics"
    static let spotifyScopes = "user-read-currently-playing user-read-playback-state"
    static let userAgent = "CarLyrics/1.0 (personal)"

    /// Seconds between `currently-playing` polls.
    static let pollInterval: TimeInterval = 3
    /// Show a line slightly early to compensate for network/render latency.
    static let lyricsLeadSeconds: TimeInterval = 0.3

    /// Card colors when no album art is available.
    static let defaultBackgroundHex = "#1A1A2E"
    static let defaultAccentHex = "#4A4E69"
}

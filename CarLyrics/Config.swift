import Foundation

enum Config {
    /// Spotify app Client ID (not a secret when using PKCE).
    static let spotifyClientID = "78eb3eb09ae143029ef5014fef4af85e"
    static let spotifyRedirectURI = "carlyrics://callback"
    static let spotifyScopes = "user-read-currently-playing user-read-playback-state"
    static let userAgent = "CarLyrics/1.0 (personal)"
}

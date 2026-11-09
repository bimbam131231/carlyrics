import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

enum SpotifyError: LocalizedError {
    case notConnected
    case authCancelled
    case authFailed(String)
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to Spotify"
        case .authCancelled: return "Login cancelled"
        case .authFailed(let msg): return "Login failed: \(msg)"
        case .http(let code, let body): return "HTTP \(code) \(body)"
        case .badResponse: return "Bad response"
        }
    }
}

enum PKCE {
    static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }

    /// 64 random bytes -> 86 chars (spec: 43...128).
    static func makeVerifier() -> String { randomURLSafe(bytes: 64) }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct SpotifyTokenResponse: Decodable {
    let access_token: String
    let expires_in: Int
    let refresh_token: String?
}

/// Holds the window the login sheet is presented from.
private final class AuthAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    let window: UIWindow
    init(window: UIWindow) { self.window = window }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window }
}

/// Spotify Authorization Code + PKCE. Refresh token in Keychain, access token in memory.
@MainActor
final class SpotifyAuth {
    private static let refreshTokenKey = "spotifyRefreshToken"

    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast
    private var authSession: ASWebAuthenticationSession?
    private var anchorProvider: AuthAnchorProvider?

    var onLog: (String) -> Void = { _ in }

    var hasRefreshToken: Bool { Keychain.get(Self.refreshTokenKey) != nil }

    // MARK: Login

    func connect() async throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow })
                ?? scenes.first?.windows.first else {
            throw SpotifyError.authFailed("No window to present login")
        }

        let verifier = PKCE.makeVerifier()
        let state = PKCE.randomURLSafe(bytes: 16)
        var comps = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: Config.spotifyClientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Config.spotifyRedirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "scope", value: Config.spotifyScopes),
            URLQueryItem(name: "state", value: state),
        ]
        guard let authURL = comps.url else { throw SpotifyError.authFailed("Bad authorize URL") }

        let provider = AuthAnchorProvider(window: window)
        self.anchorProvider = provider
        defer {
            self.authSession = nil
            self.anchorProvider = nil
        }

        let callbackURL: URL = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: Config.spotifyCallbackScheme
            ) { url, error in
                if let url {
                    cont.resume(returning: url)
                } else if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin {
                    cont.resume(throwing: SpotifyError.authCancelled)
                } else {
                    cont.resume(throwing: error ?? SpotifyError.authFailed("No callback"))
                }
            }
            session.presentationContextProvider = provider
            self.authSession = session
            if !session.start() {
                cont.resume(throwing: SpotifyError.authFailed("Could not open login sheet"))
            }
        }

        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let err = value("error") { throw SpotifyError.authFailed(err) }
        guard value("state") == state else { throw SpotifyError.authFailed("State mismatch") }
        guard let code = value("code") else { throw SpotifyError.authFailed("No code in callback") }

        let tokens = try await tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Config.spotifyRedirectURI,
            "client_id": Config.spotifyClientID,
            "code_verifier": verifier,
        ])
        store(tokens)
        onLog("Spotify connected")
    }

    func disconnect() {
        Keychain.delete(Self.refreshTokenKey)
        accessToken = nil
        accessTokenExpiry = .distantPast
    }

    // MARK: Tokens

    func validAccessToken() async throws -> String {
        if let token = accessToken, Date() < accessTokenExpiry.addingTimeInterval(-60) {
            return token
        }
        try await refresh()
        guard let token = accessToken else { throw SpotifyError.notConnected }
        return token
    }

    func invalidateAccessToken() {
        accessToken = nil
        accessTokenExpiry = .distantPast
    }

    private func refresh() async throws {
        guard let refreshToken = Keychain.get(Self.refreshTokenKey) else { throw SpotifyError.notConnected }
        let tokens = try await tokenRequest([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Config.spotifyClientID,
        ])
        store(tokens)
        onLog("Access token refreshed")
    }

    private func store(_ tokens: SpotifyTokenResponse) {
        accessToken = tokens.access_token
        accessTokenExpiry = Date().addingTimeInterval(TimeInterval(tokens.expires_in))
        if let rt = tokens.refresh_token {
            Keychain.set(rt, for: Self.refreshTokenKey)
        }
    }

    private func tokenRequest(_ params: [String: String]) async throws -> SpotifyTokenResponse {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formEncode(params).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if code == 400 && body.contains("invalid_grant") {
                onLog("Refresh token rejected, please reconnect")
                disconnect()
                throw SpotifyError.notConnected
            }
            throw SpotifyError.http(code, String(body.prefix(200)))
        }
        return try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
    }

    private static func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }
}

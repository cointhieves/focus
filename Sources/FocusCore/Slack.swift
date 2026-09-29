import CryptoKit
import Foundation

// Slack sign-in for a desktop app: OAuth v2 with PKCE and a user token only.
// https://docs.slack.dev/authentication/using-pkce
// https://docs.slack.dev/authentication/using-token-rotation

public enum SlackConfig {
    /// The company's Focus Slack app, from the build (Resources/Org.plist). A PKCE app is
    /// a public client, so its client ID is not a secret. There is no client secret anywhere.
    public static var clientId: String { OrgConfig.slackClientID }
    public static let callbackPort: UInt16 = 53682
    public static let callbackPath = "/slack/callback"
    public static var redirectURI: String { "http://localhost:\(callbackPort)\(callbackPath)" }
    /// Read-only scopes for mentions, DMs and thread replies. Must match the app manifest.
    public static let userScopes = ["search:read", "im:read", "im:history", "mpim:read", "mpim:history",
                                    "channels:history", "groups:history", "users:read", "usergroups:read"]
}

public enum PKCE {
    /// URL-safe base64 without padding (RFC 4648 section 5), as PKCE requires.
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A fresh random secret for one sign-in (also used for the CSRF `state`).
    public static func randomToken(bytes: Int = 32) -> String {
        var raw = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &raw)
        return base64url(Data(raw))
    }

    /// S256 challenge for a verifier.
    public static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

/// One Slack conversation, thread or mention waiting on me.
public struct SlackItemState: Equatable, Sendable {
    /// `dm:C`, `group:C`, `thread:C:TS` or `mention:C:TS`.
    public let key: String
    public var kind: String { String(key.split(separator: ":").first ?? "") }
    public let title: String
    public let detail: String
    public let url: URL?
    /// The first message from someone else that I haven't answered.
    public let waitingSince: Date
    /// The newest such message's ts; changes when more arrive (does not re-pop).
    public let marker: String
    public init(key: String, title: String, detail: String, url: URL?, waitingSince: Date, marker: String) {
        self.key = key; self.title = title; self.detail = detail; self.url = url
        self.waitingSince = waitingSince; self.marker = marker
    }
}

public struct SlackSyncResult: Sendable {
    public let states: [SlackItemState]
    /// Keys I answered (a later message from me, or a reaction on their newest message).
    public let answered: Set<String>
    public init(states: [SlackItemState], answered: Set<String>) { self.states = states; self.answered = answered }
}

public enum SlackKind {
    public static let all = ["dm", "group", "thread", "mention"]
}

/// The signed-in user's tokens, stored as one Keychain item.
public struct SlackTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var userId: String

    /// Refresh a little early so a sync never starts with a token about to expire.
    public func needsRefresh(now: Date = Date()) -> Bool {
        guard let expiresAt, refreshToken != nil else { return false }
        return expiresAt.timeIntervalSince(now) < 10 * 60
    }
}

public struct SlackError: Error, CustomStringConvertible {
    public let description: String
    /// Slack's error code, e.g. "invalid_auth", when the API returned one.
    public let code: String?
    public init(_ description: String, code: String? = nil) { self.description = description; self.code = code }
}

public struct SlackIdentity: Sendable {
    public let user: String
    public let team: String
    public let userId: String
}

public struct SlackClient: Sendable {
    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public static func authorizeURL(challenge: String, state: String) -> URL {
        var c = URLComponents(string: "https://slack.com/oauth/v2/authorize")!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: SlackConfig.clientId),
            URLQueryItem(name: "scope", value: ""),   // no bot scopes
            URLQueryItem(name: "user_scope", value: SlackConfig.userScopes.joined(separator: ",")),
            URLQueryItem(name: "redirect_uri", value: SlackConfig.redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return c.url!
    }

    /// Exchanges the code from the redirect for tokens. No client_secret (PKCE).
    public func exchange(code: String, verifier: String, now: Date = Date()) async throws -> SlackTokens {
        // The code is single use, so this one call is never retried.
        let json = try await post("oauth.v2.access", form: [
            "client_id": SlackConfig.clientId, "code": code,
            "code_verifier": verifier, "redirect_uri": SlackConfig.redirectURI,
        ], retry: false)
        return try Self.tokens(from: json, now: now)
    }

    /// Rotates tokens. Refresh tokens are single use, so the result must be saved.
    public func refresh(_ tokens: SlackTokens, now: Date = Date()) async throws -> SlackTokens {
        guard let refresh = tokens.refreshToken else { throw SlackError("no refresh token; reconnect Slack") }
        let json = try await post("oauth.v2.access", form: [
            "client_id": SlackConfig.clientId, "grant_type": "refresh_token", "refresh_token": refresh,
        ])
        var fresh = try Self.tokens(from: json, now: now)
        if fresh.userId.isEmpty { fresh.userId = tokens.userId }
        return fresh
    }

    /// Invalidates a token at Slack (access or refresh). Used on Disconnect.
    public func revoke(_ token: String) async {
        _ = try? await post("auth.revoke", form: [:], token: token)
    }

    public func authTest(token: String) async throws -> SlackIdentity {
        let json = try await post("auth.test", form: [:], token: token)
        return SlackIdentity(user: json["user"] as? String ?? "?", team: json["team"] as? String ?? "?",
                             userId: json["user_id"] as? String ?? "")
    }

    /// The user token sits under `authed_user` on first sign-in; a refresh of a user
    /// token may return the fields at the top level. Accept both.
    static func tokens(from json: [String: Any], now: Date) throws -> SlackTokens {
        let src = (json["authed_user"] as? [String: Any]).flatMap { $0["access_token"] != nil ? $0 : nil } ?? json
        guard let access = src["access_token"] as? String else {
            throw SlackError("Slack returned no user token")
        }
        let expiresIn = (src["expires_in"] as? NSNumber)?.doubleValue
        return SlackTokens(accessToken: access, refreshToken: src["refresh_token"] as? String,
                           expiresAt: expiresIn.map { now.addingTimeInterval($0) },
                           userId: src["id"] as? String ?? "")
    }

    /// Slack answers HTTP 200 with {"ok": false, "error": "..."} on failure.
    public func post(_ method: String, form: [String: String], token: String? = nil,
                     retry: Bool = true) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://slack.com/api/\(method)")!, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents leaves "+" alone, which a form body would read as a space.
        req.httpBody = Data((body.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await Retry.data(session, for: req, attempts: retry ? 3 : 1)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 { throw SlackError("Slack rate limited \(method)", code: "ratelimited") }
        guard (200..<300).contains(status) else { throw SlackError("Slack returned HTTP \(status) for \(method)") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SlackError("unexpected Slack response for \(method)")
        }
        guard json["ok"] as? Bool == true else {
            let code = json["error"] as? String ?? "unknown_error"
            throw SlackError("Slack \(method) failed: \(code)", code: code)
        }
        return json
    }
}

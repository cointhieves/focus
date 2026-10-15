import Foundation
import Testing
@testable import FocusCore

@Test func pkceMatchesSlackDocExample() {
    // docs.slack.dev/authentication/using-pkce: verifier "secretpassword".
    #expect(PKCE.challenge(for: "secretpassword") == "ldMBaaWcQYtSATMV_IG8mf3wp7A6EW80arYoSW80ntU")
    let v = PKCE.randomToken()
    #expect(v.count >= 43 && !v.contains("=") && !v.contains("+") && !v.contains("/"))
}

@Test func authorizeURLHasPKCEAndUserScopesOnly() throws {
    let url = SlackClient.authorizeURL(challenge: "abc", state: "st")
    let q = Dictionary(uniqueKeysWithValues: try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        .map { ($0.name, $0.value ?? "") })
    #expect(q["code_challenge_method"] == "S256")
    #expect(q["code_challenge"] == "abc")
    #expect(q["scope"] == "")
    #expect(q["user_scope"]?.contains("search:read") == true)
    #expect(q["redirect_uri"] == "http://localhost:53682/slack/callback")
    #expect(q["client_secret"] == nil)
}

@Test func tokensParseFromFirstSignInAndFromRefresh() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let first: [String: Any] = ["ok": true, "authed_user": [
        "id": "U1", "access_token": "xoxe.xoxp-1", "refresh_token": "xoxe-1-r", "expires_in": 43200]]
    let t = try SlackClient.tokens(from: first, now: now)
    #expect(t.userId == "U1" && t.accessToken == "xoxe.xoxp-1" && t.refreshToken == "xoxe-1-r")
    #expect(t.expiresAt == now.addingTimeInterval(43200))
    let refreshed: [String: Any] = ["ok": true, "access_token": "xoxe.xoxp-2", "refresh_token": "xoxe-1-s",
                                    "expires_in": 43200, "token_type": "user"]
    #expect(try SlackClient.tokens(from: refreshed, now: now).accessToken == "xoxe.xoxp-2")
    #expect(throws: SlackError.self) { try SlackClient.tokens(from: ["ok": true], now: now) }
}

@Test func needsRefreshTenMinutesEarly() {
    let now = Date()
    var t = SlackTokens(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(9 * 60), userId: "U")
    #expect(t.needsRefresh(now: now))
    t.expiresAt = now.addingTimeInterval(3600)
    #expect(!t.needsRefresh(now: now))
}

@Test func callbackParsesCodeAndChecksState() throws {
    let s = try OAuthCallbackServer(port: 53999, path: "/slack/callback", state: "good")
    #expect(s.parse("GET /slack/callback?code=abc&state=good HTTP/1.1\r\nHost: x\r\n\r\n") == .code("abc"))
    #expect(s.parse("GET /slack/callback?code=abc&state=evil HTTP/1.1\r\n\r\n") == .failed("state did not match this sign-in"))
    #expect(s.parse("GET /slack/callback?error=access_denied&state=good HTTP/1.1\r\n\r\n") == .denied("access_denied"))
    #expect(s.parse("GET /favicon.ico HTTP/1.1\r\n\r\n") == nil)
}

/// End to end over real sockets, on both 127.0.0.1 and ::1: browsers may resolve
/// "localhost" to either.
/// The two hosts run one after the other (not in parallel), and a port taken between
/// picking and binding is retried, so the test can't fail on "address already in use".
@Test(.serialized, arguments: ["127.0.0.1", "[::1]"])
func callbackServerReceivesRedirect(host: String) async throws {
    var outcome: OAuthCallbackServer.Outcome = .failed("not run")
    for _ in 0..<5 {
        let port = freePort()
        let server = try OAuthCallbackServer(port: port, path: "/slack/callback", state: "s1")
        outcome = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<OAuthCallbackServer.Outcome, Error>) in
            server.start(timeout: 10) { cont.resume(returning: $0) }
            Task {
                try await Task.sleep(nanoseconds: 300_000_000)
                _ = try? await URLSession.shared.data(from: URL(string: "http://\(host):\(port)/slack/callback?code=C9&state=s1")!)
            }
        }
        if case .failed(let why) = outcome, why.contains("Address already in use") { continue }
        break
    }
    #expect(outcome == .code("C9"))
}


/// Asks the OS for an unused TCP port (bind to port 0, read it back, release it).
private func freePort() -> UInt16 {
    let fd = socket(AF_INET6, SOCK_STREAM, 0)
    defer { close(fd) }
    var addr = sockaddr_in6()
    addr.sin6_family = sa_family_t(AF_INET6)
    addr.sin6_port = 0
    addr.sin6_addr = in6addr_any
    var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
    _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
    _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
    return UInt16(bigEndian: addr.sin6_port)
}

// Slack items open straight in the desktop app (no leftover browser tab).
@Test func slackAppLinkFromPermalinks() {
    let thread = URL(string: "https://x.slack.com/archives/C111/p1791561084578999?thread_ts=1791546127.539479&cid=C111")!
    #expect(SlackAppLink.from(thread, teamId: "T1")?.absoluteString
            == "slack://channel?team=T1&id=C111&message=1791561084.578999&thread_ts=1791546127.539479")
    let dm = URL(string: "https://x.slack.com/archives/D222")!
    #expect(SlackAppLink.from(dm, teamId: "T1")?.absoluteString == "slack://channel?team=T1&id=D222")
    let mention = URL(string: "https://x.slack.com/archives/C333/p1700000000123456")!
    #expect(SlackAppLink.from(mention, teamId: "T1")?.absoluteString == "slack://channel?team=T1&id=C333&message=1700000000.123456")
    // No workspace id yet, or not a Slack link: keep the original link.
    #expect(SlackAppLink.from(thread, teamId: "") == nil)
    #expect(SlackAppLink.from(URL(string: "https://example.atlassian.net/browse/ABC-1")!, teamId: "T1") == nil)
}

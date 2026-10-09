import Foundation
@testable import FocusCore

/// Canned HTTP responses for tests, so the Jira and Slack sync paths run without the network.
/// A route matches when the request URL contains every fragment in `match` (path and
/// decoded query text); the first matching route wins, so put specific routes first.
final class FakeNet: URLProtocol, @unchecked Sendable {
    struct Route: Sendable {
        let match: [String]
        let status: Int
        let body: String
    }

    nonisolated(unsafe) private static var routes: [String: [Route]] = [:]
    nonisolated(unsafe) private static var seen: [String: [String]] = [:]
    private static let lock = NSLock()

    /// A session whose requests are answered from `routes`. Each session gets its own
    /// route table (keyed by a header), so parallel tests don't see each other's routes.
    static func session(_ routes: [Route]) -> (URLSession, id: String) {
        let id = UUID().uuidString
        lock.lock(); self.routes[id] = routes; lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeNet.self]
        config.httpAdditionalHeaders = ["X-Fake-Net": id]
        return (URLSession(configuration: config), id)
    }

    /// Every request URL a session made, in order (decoded).
    static func requests(_ id: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return seen[id] ?? []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: "X-Fake-Net") ?? ""
        var text = request.url?.absoluteString.removingPercentEncoding ?? ""
        // Slack calls are form POSTs: match the body too.
        if let body = request.httpBody ?? request.httpBodyStream.map(Self.read),
           let s = String(data: body, encoding: .utf8) {
            text += "?" + (s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s)
        }
        Self.lock.lock()
        Self.seen[id, default: []].append(text)
        let route = Self.routes[id]?.first { r in r.match.allSatisfy { text.contains($0) } }
        Self.lock.unlock()
        let status = route?.status ?? 404
        let body = route?.body ?? #"{"error":"no fake route for \#(text)"}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var data = Data(), buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }
}

/// Small JSON builders for Jira fixtures.
enum JiraFixture {
    static let me = "acct-me"

    static func myself() -> FakeNet.Route {
        .init(match: ["/rest/api/3/myself"], status: 200,
              body: #"{"accountId":"\#(me)","accountType":"atlassian","displayName":"Me"}"#)
    }

    /// One search page of issues; `status` is each issue's own live status category key.
    static func issues(_ items: [(key: String, status: String)]) -> String {
        let list = items.map { #"{"key":"\#($0.key)","fields":{"summary":"\#($0.key) summary","status":{"statusCategory":{"key":"\#($0.status)"}}}}"# }
        return #"{"issues":[\#(list.joined(separator: ","))],"isLast":true}"#
    }

    static func comments(_ items: [(id: String, author: String, created: String)]) -> String {
        let list = items.map {
            #"{"id":"\#($0.id)","author":{"accountId":"\#($0.author)","accountType":"atlassian","displayName":"\#($0.author)"},"created":"\#($0.created)"}"#
        }
        return #"{"comments":[\#(list.joined(separator: ","))],"total":\#(items.count),"startAt":0}"#
    }
}

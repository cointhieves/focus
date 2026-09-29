import Foundation
import Network

/// Catches the OAuth redirect on http://localhost:<port>. Listens on the loopback
/// interface only, so nothing outside this Mac can reach it, and only while a sign-in
/// is in progress. Checks `state` so an unrelated local request cannot inject a code.
public final class OAuthCallbackServer: @unchecked Sendable {
    public enum Outcome: Sendable, Equatable { case code(String), denied(String), failed(String) }

    private let listener: NWListener
    private let path: String
    private let state: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "io.github.omegaleon.focus.oauth")
    private var finished = false
    private var completion: (@Sendable (Outcome) -> Void)?

    public init(port: UInt16, path: String, state: String) throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw SlackError("bad port \(port)") }
        listener = try NWListener(using: params, on: nwPort)
        self.path = path
        self.state = state
        self.port = port
    }

    /// Starts listening. `completion` runs once, on a background queue.
    public func start(timeout: TimeInterval = 300, completion: @escaping @Sendable (Outcome) -> Void) {
        self.completion = completion
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.stateUpdateHandler = { [weak self] st in
            if case .failed(let error) = st {
                self?.finish(.failed("could not listen on port \(self?.port ?? 0): \(error)"))
            }
        }
        listener.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failed("timed out waiting for Slack; try Connect again"))
        }
    }

    public func cancel() { queue.async { [weak self] in self?.finish(.failed("cancelled")) } }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { conn.cancel(); return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let outcome = self.parse(request)
            let (status, message): (String, String) = switch outcome {
            case .code?: ("200 OK", "Focus is connected to Slack. You can close this tab.")
            case .denied(let why)?: ("200 OK", "Slack sign-in was not completed (\(why)). You can close this tab.")
            case .failed(let why)?: ("400 Bad Request", "Focus could not use this response: \(why)")
            case nil: ("404 Not Found", "Not found")
            }
            let html = "<!doctype html><meta charset=utf-8><body style=\"font:16px -apple-system;margin:40px\">\(message)</body>"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
            if let outcome { self.finish(outcome) }
        }
    }

    /// nil means "not our path" (e.g. a favicon request) and is ignored.
    func parse(_ request: String) -> Outcome? {
        let firstLine = request.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let comps = URLComponents(string: "http://localhost" + parts[1]), comps.path == path else { return nil }
        let q = Dictionary((comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard q["state"] == state else { return .failed("state did not match this sign-in") }
        if let error = q["error"] { return .denied(error) }
        guard let code = q["code"], !code.isEmpty else { return .failed("no code in the redirect") }
        return .code(code)
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        listener.cancel()
        let done = completion
        completion = nil
        done?(outcome)
    }
}

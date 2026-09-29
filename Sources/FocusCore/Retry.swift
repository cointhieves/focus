import Foundation

/// Retries a request on transient failures: a dropped or stale connection (the first
/// call after the Mac sat idle often fails with "network connection lost"), a timeout,
/// or HTTP 429 (waits the server's Retry-After, capped). Anything else fails at once.
enum Retry {
    static let transient: Set<URLError.Code> = [.networkConnectionLost, .timedOut, .cannotConnectToHost,
                                                .dnsLookupFailed, .secureConnectionFailed]

    static func data(_ session: URLSession, for req: URLRequest, attempts: Int = 3) async throws -> (Data, URLResponse) {
        var attempt = 1
        while true {
            do {
                let (data, response) = try await session.data(for: req)
                if let http = response as? HTTPURLResponse, http.statusCode == 429, attempt < attempts {
                    let wait = min(Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2, 30)
                    try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    attempt += 1
                    continue
                }
                return (data, response)
            } catch let e as URLError where transient.contains(e.code) && attempt < attempts {
                try await Task.sleep(nanoseconds: UInt64(0.5 * Double(attempt) * 1_000_000_000))
                attempt += 1
            }
        }
    }
}

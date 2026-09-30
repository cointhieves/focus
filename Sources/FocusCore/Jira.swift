import Foundation

// MARK: - Config

/// Jira connection settings. The token lives in the Keychain, the rest in the DB.
public struct JiraConfig: Equatable, Sendable {
    public var enabled = false
    /// From the build (Resources/Org.plist); not a user setting.
    public var site = OrgConfig.jiraSite
    public var email = ""
    /// Account ids whose comments never count as "someone replied" (bots posting as users).
    public var ignoredAccountIds: [String] = []

    public init() {}

    var baseURL: URL? {
        var s = site.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.hasPrefix("http") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }
}

// MARK: - API models (only the fields Focus uses)

public struct JiraUser: Decodable, Equatable, Sendable {
    public let accountId: String
    public let accountType: String?
    public let displayName: String?
}

public struct JiraComment: Decodable, Equatable, Sendable {
    public let id: String
    public let author: JiraUser?
    public let created: Date
}

public struct JiraIssue: Decodable, Sendable {
    public let key: String
    public let summary: String

    private struct Fields: Decodable { let summary: String? }
    private enum CodingKeys: String, CodingKey { case key, fields }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        summary = (try? c.decode(Fields.self, forKey: .fields).summary) ?? key
    }
    public init(key: String, summary: String) { self.key = key; self.summary = summary }
}

// MARK: - Classification (pure, unit tested)

public struct JiraTicketState: Equatable, Sendable {
    public let key: String
    public let summary: String
    public let myLastComment: Date?
    /// A human comment by someone else, newer than my last comment.
    public let waitingOnMe: Bool
    public let changeMarker: String
    public init(key: String, summary: String, myLastComment: Date?, waitingOnMe: Bool, changeMarker: String) {
        self.key = key; self.summary = summary; self.myLastComment = myLastComment
        self.waitingOnMe = waitingOnMe; self.changeMarker = changeMarker
    }
}

public enum JiraClassifier {
    /// Returns nil when the ticket should not be in the queue (I responded recently
    /// and nobody has replied since).
    public static func classify(issue: JiraIssue, comments: [JiraComment], me: String,
                                ignored: Set<String>, greenUntilHours: Double,
                                workStartHour: Double = 9, workEndHour: Double = 17,
                                now: Date, calendar: Calendar = .current) -> JiraTicketState? {
        let newestFirst = comments.sorted { $0.created > $1.created }
        let mine = newestFirst.first { $0.author?.accountId == me }
        let replies = newestFirst.filter { c in
            guard let a = c.author, a.accountId != me, !ignored.contains(a.accountId) else { return false }
            // Only real people count: "app" accounts are integrations/automation.
            return (a.accountType ?? "atlassian") == "atlassian"
        }
        let newestReply = replies.first { reply in mine.map { reply.created > $0.created } ?? true }

        // My comment hides the ticket until the start of the next workday (the user's own
        // workday start, not a fixed time), so anything I answered today is on tomorrow's
        // list. A shorter "green until" can bring it back sooner the same day.
        let stale: Bool = {
            guard let mine else { return true }
            if now >= BusinessClock.nextWorkdayStart(after: mine.created, startHour: workStartHour,
                                                     calendar: calendar) { return true }
            return BusinessClock.hours(from: mine.created, to: now, startHour: workStartHour,
                                       endHour: workEndHour, calendar: calendar) >= greenUntilHours
        }()
        guard newestReply != nil || stale else { return nil }

        return JiraTicketState(
            key: issue.key, summary: issue.summary,
            myLastComment: mine?.created,
            waitingOnMe: newestReply != nil,
            changeMarker: newestReply?.id ?? mine?.id ?? "none")
    }
}

/// One sync's result. A ticket that leaves the queue is explained by the key sets:
/// in `doneKeys` it closed; in `inScopeKeys` it no longer needs a response (I replied);
/// in neither it left scope (back to To Do, out of the sprint, reassigned).
public struct JiraSyncResult: Sendable {
    public let states: [JiraTicketState]
    public let doneKeys: Set<String>
    /// My In Progress tickets in open sprints, whether or not they need a response.
    public let inScopeKeys: Set<String>
    public init(states: [JiraTicketState], doneKeys: Set<String>, inScopeKeys: Set<String>) {
        self.states = states; self.doneKeys = doneKeys; self.inScopeKeys = inScopeKeys
    }
}

// MARK: - HTTP client

public struct JiraError: Error, CustomStringConvertible {
    public let description: String
}

public struct JiraClient: Sendable {
    let config: JiraConfig
    let token: String
    let session: URLSession

    public init(config: JiraConfig, token: String, session: URLSession = .shared) {
        self.config = config
        self.token = token
        self.session = session
    }

    static let decoder: JSONDecoder = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"   // Jira: 2026-09-27T13:00:00.000-0400
        let d = JSONDecoder()
        d.dateDecodingStrategy = .formatted(f)
        return d
    }()

    public func myself() async throws -> JiraUser {
        try await get("/rest/api/3/myself", query: [])
    }

    /// My started tickets in open sprints. Jira's "In Progress" status category covers
    /// In Progress and In Review; To Do (not started) and Done are excluded.
    public func sprintIssues(statusCategory: String = "In Progress") async throws -> [JiraIssue] {
        struct Page: Decodable { let issues: [JiraIssue]; let nextPageToken: String?; let isLast: Bool? }
        var all: [JiraIssue] = []
        var token: String?
        repeat {
            var q = [URLQueryItem(name: "jql", value: "assignee = currentUser() AND sprint in openSprints() AND statusCategory = \"\(statusCategory)\""),
                     URLQueryItem(name: "fields", value: "summary"),
                     URLQueryItem(name: "maxResults", value: "100")]
            if let token { q.append(URLQueryItem(name: "nextPageToken", value: token)) }
            let page: Page = try await get("/rest/api/3/search/jql", query: q)
            all += page.issues
            token = (page.isLast ?? true) ? nil : page.nextPageToken
        } while token != nil && all.count < 1000
        return all
    }

    /// Newest-first comments; stops once one of mine is found (older ones don't matter).
    public func comments(for key: String, me: String) async throws -> [JiraComment] {
        struct Page: Decodable { let comments: [JiraComment]; let total: Int; let startAt: Int }
        var all: [JiraComment] = []
        var start = 0
        while true {
            let page: Page = try await get("/rest/api/3/issue/\(key)/comment", query: [
                URLQueryItem(name: "orderBy", value: "-created"),
                URLQueryItem(name: "startAt", value: String(start)),
                URLQueryItem(name: "maxResults", value: "100"),
            ])
            all += page.comments
            start += page.comments.count
            if page.comments.isEmpty || start >= page.total || page.comments.contains(where: { $0.author?.accountId == me }) {
                return all
            }
        }
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> T {
        let data = try await raw(path, query: query)
        do { return try Self.decoder.decode(T.self, from: data) }
        catch { throw JiraError(description: "unexpected Jira response for \(path): \(error)") }
    }

    /// A GET as untyped JSON (for ADF bodies, which have no fixed shape).
    func json(_ path: String, query: [URLQueryItem]) async throws -> [String: Any] {
        let data = try await raw(path, query: query)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JiraError(description: "unexpected Jira response for \(path)")
        }
        return obj
    }

    private func raw(_ path: String, query: [URLQueryItem]) async throws -> Data {
        guard let base = config.baseURL, var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        else { throw JiraError(description: "invalid Jira site '\(config.site)'") }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw JiraError(description: "invalid request URL") }
        var req = URLRequest(url: url, timeoutInterval: 30)
        let basic = Data("\(config.email):\(token)".utf8).base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Retry.data(session, for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            switch status {
            case 401: throw JiraError(description: "Jira rejected the email or API token (401)")
            case 403: throw JiraError(description: "Jira denied access (403)")
            default: throw JiraError(description: "Jira returned HTTP \(status) for \(path)")
            }
        }
        return data
    }

    /// Fetches everything and classifies it. Comment fetches run in parallel.
    public func fetchStates(greenUntilHours: Double, workStartHour: Double = 9, workEndHour: Double = 17,
                            now: Date = Date(),
                            maxConcurrent: Int = 8) async throws -> JiraSyncResult {
        let me = try await myself().accountId
        let issues = try await sprintIssues()
        let done = try await sprintIssues(statusCategory: "Done").map(\.key)
        let ignored = Set(config.ignoredAccountIds)
        var results: [String: [JiraComment]] = [:]
        try await withThrowingTaskGroup(of: (String, [JiraComment]).self) { group in
            var queue = issues.makeIterator()
            func addNext() {
                guard let issue = queue.next() else { return }
                group.addTask { (issue.key, try await comments(for: issue.key, me: me)) }
            }
            for _ in 0..<maxConcurrent { addNext() }
            while let (key, comments) = try await group.next() {
                results[key] = comments
                addNext()
            }
        }
        // Classify in the original issue order.
        let states = issues.compactMap { issue in
            JiraClassifier.classify(issue: issue, comments: results[issue.key] ?? [], me: me,
                                    ignored: ignored, greenUntilHours: greenUntilHours,
                                    workStartHour: workStartHour, workEndHour: workEndHour, now: now)
        }
        return JiraSyncResult(states: states, doneKeys: Set(done), inScopeKeys: Set(issues.map(\.key)))
    }
}

// MARK: - Mentions on tickets outside my sprint

/// A ticket where someone @mentioned me after my last comment.
public struct JiraMentionState: Equatable, Sendable {
    public let key: String
    public let summary: String
    public let mentionedBy: String
    /// The first mention I haven't answered (starts the age clock).
    public let waitingSince: Date
    /// Id of the newest unanswered mention; changes when a new one arrives.
    public let marker: String
    public init(key: String, summary: String, mentionedBy: String, waitingSince: Date, marker: String) {
        self.key = key; self.summary = summary; self.mentionedBy = mentionedBy
        self.waitingSince = waitingSince; self.marker = marker
    }
}

public struct JiraMentionResult: Sendable {
    public let states: [JiraMentionState]
    /// Open mention items I answered (commented after the mention).
    public let answered: Set<String>
    /// Open mention items whose ticket is now Done.
    public let closed: Set<String>
    public init(states: [JiraMentionState], answered: Set<String>, closed: Set<String>) {
        self.states = states; self.answered = answered; self.closed = closed
    }
}

public enum JiraMentions {
    /// True if an ADF document contains a mention node for `me`.
    public static func mentions(_ adf: Any?, _ me: String) -> Bool {
        if let d = adf as? [String: Any] {
            if d["type"] as? String == "mention", (d["attrs"] as? [String: Any])?["id"] as? String == me { return true }
            return d.values.contains { mentions($0, me) }
        }
        if let a = adf as? [Any] { return a.contains { mentions($0, me) } }
        return false
    }

    public struct Comment: Sendable {
        public let id: String, author: String, authorName: String, created: Date, mentionsMe: Bool
        public init(id: String, author: String, authorName: String, created: Date, mentionsMe: Bool) {
            self.id = id; self.author = author; self.authorName = authorName; self.created = created; self.mentionsMe = mentionsMe
        }
    }

    /// The unanswered state for one ticket, or nil if nothing waits on me.
    /// `descriptionMention` is (created, reporter id, reporter name) when the description mentions me.
    public static func classify(key: String, summary: String, me: String, comments: [Comment],
                                descriptionMention: (Date, String, String)?) -> JiraMentionState? {
        let myLast = comments.filter { $0.author == me }.map(\.created).max() ?? .distantPast
        var hits = comments.filter { $0.author != me && $0.mentionsMe && $0.created > myLast }
            .map { (id: $0.id, at: $0.created, who: $0.authorName) }
        if let (at, reporter, name) = descriptionMention, reporter != me, at > myLast {
            hits.append((id: "description", at: at, who: name))
        }
        hits.sort { $0.at < $1.at }
        guard let first = hits.first, let newest = hits.last else { return nil }
        return JiraMentionState(key: key, summary: summary, mentionedBy: newest.who,
                                waitingSince: first.at, marker: newest.id)
    }
}

extension JiraClient {
    static let isoParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return f
    }()

    /// Finds tickets where I was @mentioned (comment or description) and haven't answered.
    /// `days` bounds the search; `open` are mention keys already in the queue, re-checked
    /// here so they stay until answered or Done even if the ticket goes quiet.
    /// `skip` are keys already shown as sprint tickets.
    public func fetchMentions(days: Int, open: Set<String>, skip: Set<String>, maxConcurrent: Int = 8) async throws -> JiraMentionResult {
        let me = try await myself().accountId
        let jql = "(comment ~ currentUser() OR description ~ currentUser()) AND updated >= -\(days)d AND statusCategory != Done"
        var keys = Set<String>(), token: String?
        repeat {
            var q = [URLQueryItem(name: "jql", value: jql), URLQueryItem(name: "fields", value: "summary"),
                     URLQueryItem(name: "maxResults", value: "100")]
            if let token { q.append(URLQueryItem(name: "nextPageToken", value: token)) }
            let page = try await json("/rest/api/3/search/jql", query: q)
            for i in (page["issues"] as? [[String: Any]]) ?? [] { if let k = i["key"] as? String { keys.insert(k) } }
            token = (page["isLast"] as? Bool ?? true) ? nil : page["nextPageToken"] as? String
        } while token != nil && keys.count < 500
        keys.formUnion(open)
        keys.subtract(skip)

        /// (state or nil, answered-if-open, closed)
        func check(_ key: String) async throws -> (JiraMentionState?, Bool) {
            let issue = try await json("/rest/api/3/issue/\(key)", query: [
                URLQueryItem(name: "fields", value: "summary,status,description,reporter,created")])
            let f = issue["fields"] as? [String: Any] ?? [:]
            let done = ((f["status"] as? [String: Any])?["statusCategory"] as? [String: Any])?["key"] as? String == "done"
            if done { return (nil, true) }
            var comments: [JiraMentions.Comment] = [], start = 0
            while true {
                let page = try await json("/rest/api/3/issue/\(key)/comment", query: [
                    URLQueryItem(name: "orderBy", value: "created"), URLQueryItem(name: "startAt", value: String(start)),
                    URLQueryItem(name: "maxResults", value: "100")])
                let batch = (page["comments"] as? [[String: Any]]) ?? []
                for c in batch {
                    let a = c["author"] as? [String: Any]
                    guard let created = (c["created"] as? String).flatMap(Self.isoParser.date(from:)) else { continue }
                    comments.append(.init(id: c["id"] as? String ?? "", author: a?["accountId"] as? String ?? "",
                                          authorName: a?["displayName"] as? String ?? "someone", created: created,
                                          mentionsMe: JiraMentions.mentions(c["body"], me)))
                }
                start += batch.count
                if batch.isEmpty || start >= (page["total"] as? Int ?? 0) { break }
            }
            var desc: (Date, String, String)?
            if JiraMentions.mentions(f["description"], me),
               let created = (f["created"] as? String).flatMap(Self.isoParser.date(from:)) {
                let r = f["reporter"] as? [String: Any]
                desc = (created, r?["accountId"] as? String ?? "", r?["displayName"] as? String ?? "someone")
            }
            let st = JiraMentions.classify(key: key, summary: f["summary"] as? String ?? key, me: me,
                                           comments: comments, descriptionMention: desc)
            return (st, false)
        }

        var states: [JiraMentionState] = [], answered = Set<String>(), closed = Set<String>()
        try await withThrowingTaskGroup(of: (String, JiraMentionState?, Bool).self) { group in
            var it = keys.makeIterator()
            func next() {
                guard let k = it.next() else { return }
                group.addTask { let (st, done) = try await check(k); return (k, st, done) }
            }
            for _ in 0..<maxConcurrent { next() }
            while let (k, st, done) = try await group.next() {
                if done { if open.contains(k) { closed.insert(k) } }
                else if let st { states.append(st) }
                else if open.contains(k) { answered.insert(k) }
                next()
            }
        }
        return JiraMentionResult(states: states, answered: answered, closed: closed)
    }
}

import Foundation

public enum ItemSource: String, Codable, Sendable {
    case jira, slack, idea
}

public struct Item: Identifiable, Equatable, Sendable {
    /// Short numeric id (SQLite rowid) so the CLI can refer to items easily.
    public let id: Int64
    public var source: ItemSource
    /// Identity in the source system (e.g. a Jira key). Nil for ideas.
    public var externalId: String?
    public var title: String
    /// Short context line, e.g. a ticket key or a channel name.
    public var detail: String
    public var url: URL?
    public var createdAt: Date
    /// When I last responded. `nil` means I have never responded.
    public var lastMyResponse: Date?
    /// Set when the item was popped to the front; higher = more recent.
    public var popSeq: Int64?
    /// Set when the item was skipped to the back; higher = more recent.
    public var backSeq: Int64?
    /// Last time the item appeared or moved to the front (drives the shake).
    public var movedAt: Date
    /// Optional one-shot deadline (ideas only).
    public var dueAt: Date?
    /// Deadline warnings already fired: 0 none, 1 at 10% left, 2 at 5% left, 3 at due.
    public var warnedLevel: Int
    /// A Jira ticket that left scope (To Do, out of the sprint, reassigned). It stays,
    /// greyed out, until cleared by hand or until it comes back into scope.
    public var removedAt: Date?
    /// Slack: when the first message I haven't answered arrived (starts the age clock).
    public var waitingSince: Date?
    /// Boomeranged: sits at the bottom until this time, then pops back.
    public var snoozedUntil: Date?
    public var removed: Bool { removedAt != nil }

    public init(
        id: Int64,
        source: ItemSource,
        externalId: String? = nil,
        title: String,
        detail: String,
        url: URL? = nil,
        createdAt: Date = Date(),
        lastMyResponse: Date? = nil,
        popSeq: Int64? = nil,
        backSeq: Int64? = nil,
        movedAt: Date = Date(),
        dueAt: Date? = nil,
        warnedLevel: Int = 0,
        removedAt: Date? = nil,
        waitingSince: Date? = nil,
        snoozedUntil: Date? = nil
    ) {
        self.id = id
        self.source = source
        self.externalId = externalId
        self.title = title
        self.detail = detail
        self.url = url
        self.createdAt = createdAt
        self.lastMyResponse = lastMyResponse
        self.popSeq = popSeq
        self.backSeq = backSeq
        self.movedAt = movedAt
        self.dueAt = dueAt
        self.warnedLevel = warnedLevel
        self.removedAt = removedAt
        self.waitingSince = waitingSince
        self.snoozedUntil = snoozedUntil
    }
}

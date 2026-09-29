import Foundation
import Testing
@testable import FocusCore

private let me = "me-1"
private let issue = JiraIssue(key: "SEC-1", summary: "Fix the thing")
// Wednesday 2026-09-30 12:00 UTC; all times below are UTC.
private let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
private let now = ISO8601DateFormatter().date(from: "2026-09-30T12:00:00Z")!
private func hoursAgo(_ h: Double) -> Date { now.addingTimeInterval(-h * 3600) }

private func comment(_ id: String, _ author: String, _ type: String = "atlassian", at: Date) -> JiraComment {
    JiraComment(id: id, author: JiraUser(accountId: author, accountType: type, displayName: nil), created: at)
}

private func classify(_ comments: [JiraComment], ignored: Set<String> = []) -> JiraTicketState? {
    JiraClassifier.classify(issue: issue, comments: comments, me: me, ignored: ignored,
                            greenUntilHours: 8, now: now, calendar: cal)
}

@Test func neverCommentedShows() {
    let st = classify([])
    #expect(st?.myLastComment == nil)
    #expect(st?.waitingOnMe == false)
}

@Test func freshCommentHidesTicket() {
    #expect(classify([comment("1", me, at: hoursAgo(3))]) == nil)
}

@Test func staleCommentShows() {
    let st = classify([comment("1", me, at: hoursAgo(30))])
    #expect(st?.waitingOnMe == false)
    #expect(st?.changeMarker == "1")
}

@Test func replyAfterMineIsWaitingEvenWhenFresh() {
    let st = classify([comment("1", me, at: hoursAgo(3)), comment("2", "bob", at: hoursAgo(1))])
    #expect(st?.waitingOnMe == true)
    #expect(st?.changeMarker == "2")
}

@Test func replyBeforeMineDoesNotCount() {
    #expect(classify([comment("1", "bob", at: hoursAgo(5)), comment("2", me, at: hoursAgo(2))]) == nil)
}

@Test func appAndIgnoredAccountsDoNotCount() {
    let mine = comment("1", me, at: hoursAgo(3))
    #expect(classify([mine, comment("2", "automation", "app", at: hoursAgo(1))]) == nil)
    #expect(classify([mine, comment("3", "svc-bot", at: hoursAgo(1))], ignored: ["svc-bot"]) == nil)
}

@Test func decodesJiraResponses() throws {
    let json = """
    {"comments":[{"id":"10","created":"2026-09-30T08:00:00.000-0400",
      "author":{"accountId":"bob","accountType":"atlassian","displayName":"Bob"}}],
     "total":1,"startAt":0,"maxResults":100}
    """
    struct Page: Decodable { let comments: [JiraComment] }
    let page = try JiraClient.decoder.decode(Page.self, from: Data(json.utf8))
    #expect(page.comments.first?.created == ISO8601DateFormatter().date(from: "2026-09-30T12:00:00Z"))

    let issueJSON = #"{"key":"SEC-9","fields":{"summary":"Hello"}}"#
    #expect(try JiraClient.decoder.decode(JiraIssue.self, from: Data(issueJSON.utf8)).summary == "Hello")
}

@Test func applyJiraPopsNewRepliesAndRemovesStaleRows() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("focus-test-\(UUID().uuidString)/focus.db").path
    let s = try Store(path: path)
    let site = URL(string: "https://example.atlassian.net")
    try s.addIdea("older idea", now: now.addingTimeInterval(-99_999))
    try s.upsert(source: .jira, externalId: "DEMO-1", title: "demo", detail: "", url: nil,
                 lastMyResponse: nil, changeMarker: "1")

    let stale = JiraTicketState(key: "SEC-1", summary: "stale", myLastComment: hoursAgo(30),
                                waitingOnMe: false, changeMarker: "c1")
    let waiting = JiraTicketState(key: "SEC-2", summary: "waiting", myLastComment: hoursAgo(3),
                                  waitingOnMe: true, changeMarker: "c9")
    #expect(try s.applyJira([stale, waiting], site: site, now: now) == ["SEC-2"])
    #expect(try s.queue().first?.title == "waiting")
    #expect(try s.queue().first?.url?.absoluteString == "https://example.atlassian.net/browse/SEC-2")

    // Same reply again: no pop.
    #expect(try s.applyJira([stale, waiting], site: site, now: now).isEmpty)

    // I commented on SEC-1 (no longer returned) -> removed; DEMO row survives.
    try s.applyJira([waiting], site: site, now: now)
    let keys = try s.queue().compactMap(\.externalId)
    #expect(!keys.contains("SEC-1"))
    #expect(keys.contains("DEMO-1"))
}

@Test func jiraConfigRoundTrips() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("focus-test-\(UUID().uuidString)/focus.db").path
    let s = try Store(path: path)
    var c = JiraConfig()
    c.enabled = true
    c.email = " me@example.com "
    c.ignoredAccountIds = ["a", " b ", ""]
    try s.saveJiraConfig(c)
    let back = try s.loadJiraConfig()
    #expect(back.enabled)
    #expect(back.email == "me@example.com")
    #expect(back.ignoredAccountIds == ["a", "b"])
    #expect(back.site == OrgConfig.jiraSite)   // from the build, not saved
}

private func tempStore() throws -> Store {
    try Store(path: FileManager.default.temporaryDirectory
        .appendingPathComponent("focus-test-\(UUID().uuidString)/focus.db").path)
}

private func ticket(_ key: String, waiting: Bool = false) -> JiraTicketState {
    JiraTicketState(key: key, summary: key, myLastComment: hoursAgo(30), waitingOnMe: waiting,
                    changeMarker: waiting ? "r-\(key)" : "c-\(key)")
}

@Test func applyJiraSortsLeavingTicketsByReason() throws {
    let s = try tempStore()
    try s.applyJira([ticket("A"), ticket("B"), ticket("C")], inScopeKeys: ["A", "B", "C"], site: nil, now: now)
    // A: I replied (still in scope). B: closed. C: moved out of the sprint.
    try s.applyJira([], inScopeKeys: ["A"], doneKeys: ["B"], site: nil, now: now)
    let q = try s.queue()
    #expect(q.map(\.externalId) == ["C"])
    #expect(q.first?.removed == true)
    #expect(q.first?.popSeq != nil)   // popped so it is noticed
}

@Test func removedTicketStaysUntilClearedAndSurvivesLaterSyncs() throws {
    let s = try tempStore()
    try s.applyJira([ticket("C")], inScopeKeys: ["C"], site: nil, now: now)
    try s.applyJira([], inScopeKeys: [], site: nil, now: now)
    try s.applyJira([], inScopeKeys: [], site: nil, now: now)
    let id = try #require(try s.queue().first?.id)
    #expect(try s.queue().count == 1)
    try s.dismiss(id)   // clear
    #expect(try s.queue().isEmpty)
    #expect(throws: StoreError.self) { try s.item(id) }
}

@Test func removedTicketComingBackClearsTheMark() throws {
    let s = try tempStore()
    try s.applyJira([ticket("C")], inScopeKeys: ["C"], site: nil, now: now)
    try s.applyJira([], inScopeKeys: [], site: nil, now: now)
    try s.applyJira([ticket("C", waiting: true)], inScopeKeys: ["C"], site: nil, now: now)
    #expect(try s.queue().first?.removed == false)
}

@Test func dismissedTicketLeavingScopeIsDeletedNotRemoved() throws {
    let s = try tempStore()
    try s.applyJira([ticket("C")], inScopeKeys: ["C"], site: nil, now: now)
    try s.dismiss(try #require(try s.queue().first?.id))
    try s.applyJira([], inScopeKeys: [], site: nil, now: now)
    #expect(try s.queue().isEmpty)
    // It returns like any new ticket once it needs a response again.
    try s.applyJira([ticket("C", waiting: true)], inScopeKeys: ["C"], site: nil, now: now)
    #expect(try s.queue().first?.removed == false)
}

@Test func turningJiraOffDeletesEverythingAndLimitToProtectsRealTickets() throws {
    let s = try tempStore()
    try s.applyJira([ticket("A"), ticket("DEMO-9")], inScopeKeys: ["A", "DEMO-9"], site: nil, now: now)
    // A demo sync limited to DEMO-9 must not touch A.
    try s.applyJira([], inScopeKeys: [], limitTo: ["DEMO-9"], site: nil, now: now)
    #expect(try s.queue().first { $0.externalId == "A" }?.removed == false)
    #expect(try s.queue().first { $0.externalId == "DEMO-9" }?.removed == true)
    // Off: nil inScopeKeys deletes real rows, never marks them removed.
    try s.applyJira([], site: nil, now: now)
    #expect(!(try s.queue().contains { $0.externalId == "A" }))
}

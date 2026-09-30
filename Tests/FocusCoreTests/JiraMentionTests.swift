import Foundation
import Testing
@testable import FocusCore

private let me = "me-1"
private func t(_ h: Double) -> Date { Date(timeIntervalSince1970: 1_000_000 + h * 3600) }
private func c(_ id: String, _ author: String, _ h: Double, mention: Bool = false) -> JiraMentions.Comment {
    .init(id: id, author: author, authorName: author, created: t(h), mentionsMe: mention)
}

@Test func adfMentionDetection() {
    let adf: [String: Any] = ["type": "doc", "content": [["type": "paragraph", "content": [
        ["type": "text", "text": "hey "], ["type": "mention", "attrs": ["id": "me-1", "text": "@Sam"]]]]]]
    #expect(JiraMentions.mentions(adf, "me-1"))
    #expect(!JiraMentions.mentions(adf, "someone-else"))
    #expect(!JiraMentions.mentions(nil, "me-1"))
}

@Test func mentionUnansweredUntilIComment() {
    // Alex asks twice after my comment: waiting since the first, marker the newest.
    let st = JiraMentions.classify(key: "K-1", summary: "s", me: me,
        comments: [c("1", me, 0), c("2", "jd", 1, mention: true), c("3", "tw", 2), c("4", "jd", 3, mention: true)],
        descriptionMention: nil)
    #expect(st?.waitingSince == t(1))
    #expect(st?.marker == "4")
    #expect(st?.mentionedBy == "jd")
    // I replied afterwards: nothing waiting.
    #expect(JiraMentions.classify(key: "K-1", summary: "s", me: me,
        comments: [c("2", "jd", 1, mention: true), c("5", me, 4)], descriptionMention: nil) == nil)
    // A comment that doesn't mention me doesn't count.
    #expect(JiraMentions.classify(key: "K-1", summary: "s", me: me, comments: [c("6", "jd", 1)], descriptionMention: nil) == nil)
}

@Test func descriptionMentionCountsUnlessIWroteIt() {
    let st = JiraMentions.classify(key: "K-2", summary: "s", me: me, comments: [], descriptionMention: (t(0), "rep", "Rep"))
    #expect(st?.marker == "description")
    #expect(JiraMentions.classify(key: "K-2", summary: "s", me: me, comments: [], descriptionMention: (t(0), me, "Me")) == nil)
    #expect(JiraMentions.classify(key: "K-2", summary: "s", me: me, comments: [c("1", me, 1)],
                                  descriptionMention: (t(0), "rep", "Rep")) == nil)
}

private func store() throws -> Store {
    try Store(path: FileManager.default.temporaryDirectory.appendingPathComponent("focus-m-\(UUID().uuidString)/focus.db").path)
}
private func m(_ key: String, _ marker: String) -> JiraMentionState {
    JiraMentionState(key: key, summary: "ticket \(key)", mentionedBy: "jd", waitingSince: t(0), marker: marker)
}

@Test func mentionItemsStayUntilAnsweredAndAreNotShownTwice() throws {
    let s = try store()
    try s.applyJiraMentions([m("K-1", "a"), m("K-2", "a")], remove: [], site: nil)
    #expect(try s.mentionKeys() == ["K-1", "K-2"])
    try s.applyJiraMentions([], remove: [], site: nil)                 // quiet sync: both stay
    #expect(try s.mentionKeys().count == 2)
    try s.applyJiraMentions([], remove: ["K-1"], site: nil)            // answered
    #expect(try s.mentionKeys() == ["K-2"])
    // K-2 becomes a sprint ticket: the mention row goes, the sprint row stays.
    let sprint = JiraTicketState(key: "K-2", summary: "sprint", myLastComment: nil, waitingOnMe: false, changeMarker: "none")
    try s.applyJira([sprint], inScopeKeys: ["K-2"], site: nil)
    #expect(try s.mentionKeys().isEmpty)
    #expect(try s.queue().map(\.externalId) == ["K-2"])
    // A sprint sync never deletes mention rows.
    try s.applyJiraMentions([m("K-3", "a")], remove: [], site: nil)
    try s.applyJira([], inScopeKeys: [], site: nil)
    #expect(try s.mentionKeys() == ["K-3"])
}

// "Tickets I reported": a support-queue ticket. On my ticket, a comment after mine counts
// unless it tags someone else; a direct @mention of me still counts (and wins the reason).
private let t0 = Date(timeIntervalSince1970: 1_000_000)
private func c(_ id: String, _ who: String, _ min: Double, me: Bool = false, others: Bool = false,
               human: Bool = true) -> JiraMentions.Comment {
    .init(id: id, author: who, authorName: who, created: t0.addingTimeInterval(min * 60),
          mentionsMe: me, mentionsOthers: others, human: human)
}

@Test func reportedTicketCountsUntaggedCommentsOnly() {
    let side = [c("1", "agent", 1, others: true)]          // "Hi Hai, could you help?"
    #expect(JiraMentions.classify(key: "E-1", summary: "s", me: "me", comments: side,
                                  descriptionMention: nil as (Date, String, String)?, reportedByMe: true) == nil)
    let plain = side + [c("2", "agent", 2)]                // "Leon, please do X" (no @)
    let st = JiraMentions.classify(key: "E-1", summary: "s", me: "me", comments: plain,
                                   descriptionMention: nil as (Date, String, String)?, reportedByMe: true)
    #expect(st?.marker == "2")
    #expect(st?.viaReport == true)
    // Not my ticket: the same comment doesn't count.
    #expect(JiraMentions.classify(key: "E-1", summary: "s", me: "me", comments: plain,
                                  descriptionMention: nil as (Date, String, String)?, reportedByMe: false) == nil)
}

@Test func reportedTicketClearsWhenIReplyAndSkipsApps() {
    let answered = [c("1", "agent", 1), c("2", "me", 2)]
    #expect(JiraMentions.classify(key: "E-1", summary: "s", me: "me", comments: answered,
                                  descriptionMention: nil as (Date, String, String)?, reportedByMe: true) == nil)
    let bot = [c("1", "automation", 1, human: false)]
    #expect(JiraMentions.classify(key: "E-1", summary: "s", me: "me", comments: bot,
                                  descriptionMention: nil as (Date, String, String)?, reportedByMe: true) == nil)
}

@Test func mentionOnReportedTicketIsAMention() {
    let st = JiraMentions.classify(key: "E-1", summary: "s", me: "me",
                                   comments: [c("1", "agent", 1), c("2", "agent", 2, me: true)],
                                   descriptionMention: nil as (Date, String, String)?, reportedByMe: true)
    #expect(st?.viaReport == false)
}

@Test func reportedRowsHideWithTheirToggleAndSwitchReason() throws {
    let s = try store()
    let r = JiraMentionState(key: "E-1", summary: "s", mentionedBy: "a", waitingSince: Date(), marker: "1", viaReport: true)
    _ = try s.applyJiraMentions([r], remove: [], site: nil)
    #expect(try s.queue().map { $0.externalId ?? "" } == ["reported:E-1"])
    #expect(try s.queue().first?.detail == "E-1 · a commented")
    try s.setPref("jira_reported", "0")
    #expect(try s.queue().isEmpty)
    try s.setPref("jira_reported", "1")
    let m = JiraMentionState(key: "E-1", summary: "s", mentionedBy: "a", waitingSince: Date(), marker: "2")
    _ = try s.applyJiraMentions([m], remove: [], site: nil)
    #expect(try s.queue().map { $0.externalId ?? "" } == ["mention:E-1"])
    #expect(try s.mentionKeys() == ["E-1"])
    _ = try s.applyJiraMentions([], remove: ["E-1"], site: nil)
    #expect(try s.queue().isEmpty)
}

@Test func projectOfKey() {
    #expect(JiraClient.project(of: "ABC-123") == "ABC")
    #expect(JiraClient.project(of: "OPS2-7") == "OPS2")
}

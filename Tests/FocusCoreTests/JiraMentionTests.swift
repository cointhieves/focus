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

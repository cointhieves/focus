import Foundation
import Testing
@testable import FocusCore

/// Each test gets its own throwaway database file.
private func tempStorePath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("focus-test-\(UUID().uuidString)/focus.db").path
}

private func titles(_ store: Store) throws -> [String] {
    try store.queue().map(\.title)
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Test func ideasAgeOldestFirst() throws {
    let s = try Store(path: tempStorePath())
    try s.addIdea("old", now: t0)
    try s.addIdea("new", now: t0.addingTimeInterval(60))
    #expect(try titles(s) == ["old", "new"])
}

@Test func emptyIdeaRejected() throws {
    let s = try Store(path: tempStorePath())
    #expect(throws: StoreError.self) { try s.addIdea("   ") }
}

@Test func neverRespondedJiraLeadsAgeLine() throws {
    let s = try Store(path: tempStorePath())
    try s.addIdea("idea", now: t0)
    try s.upsert(source: .jira, externalId: "A-1", title: "stale", detail: "", url: nil,
                 lastMyResponse: t0.addingTimeInterval(-3600), changeMarker: "1", now: t0)
    try s.upsert(source: .jira, externalId: "A-2", title: "never", detail: "", url: nil,
                 lastMyResponse: nil, changeMarker: "1", now: t0)
    #expect(try titles(s) == ["never", "stale", "idea"])
}

@Test func skipSendsToBackAndKeepsSkipOrder() throws {
    let s = try Store(path: tempStorePath())
    let a = try s.addIdea("a", now: t0)
    let b = try s.addIdea("b", now: t0.addingTimeInterval(1))
    try s.addIdea("c", now: t0.addingTimeInterval(2))
    try s.skip(a.id)
    try s.skip(b.id)
    #expect(try titles(s) == ["c", "a", "b"])
}

@Test func poppedItemsGoAboveTheLineOldestFirst() throws {
    let s = try Store(path: tempStorePath())
    try s.addIdea("a", now: t0)
    let b = try s.addIdea("b", now: t0.addingTimeInterval(1))
    let c = try s.addIdea("c", now: t0.addingTimeInterval(2))
    #expect(try s.popToFront(c.id))
    #expect(try s.popToFront(b.id))
    // Both popped above "a"; among popped, the one waiting longest (b) is first.
    #expect(try titles(s) == ["b", "c", "a"])
}

@Test func popWhenAlreadyFirstIsNoOp() throws {
    let s = try Store(path: tempStorePath())
    let a = try s.addIdea("a", now: t0)
    try s.addIdea("b", now: t0.addingTimeInterval(1))
    let before = try s.item(a.id).movedAt
    #expect(try s.popToFront(a.id, now: t0.addingTimeInterval(99)) == false)
    #expect(try s.item(a.id).movedAt == before)   // no shake
}

@Test func popAfterSkipReturnsToFront() throws {
    let s = try Store(path: tempStorePath())
    let a = try s.addIdea("a", now: t0)
    try s.addIdea("b", now: t0.addingTimeInterval(1))
    try s.skip(a.id)
    #expect(try titles(s) == ["b", "a"])
    #expect(try s.popToFront(a.id))
    #expect(try titles(s) == ["a", "b"])
}

@Test func dismissHidesUntilSourceChanges() throws {
    let s = try Store(path: tempStorePath())
    let j = try s.upsert(source: .jira, externalId: "A-1", title: "t", detail: "", url: nil,
                         lastMyResponse: nil, changeMarker: "c1")
    try s.dismiss(j.id)
    #expect(try s.queue().isEmpty)
    // Same marker: still hidden.
    try s.upsert(source: .jira, externalId: "A-1", title: "t", detail: "", url: nil,
                 lastMyResponse: nil, changeMarker: "c1")
    #expect(try s.queue().isEmpty)
    // New comment changes the marker: it returns.
    try s.upsert(source: .jira, externalId: "A-1", title: "t", detail: "", url: nil,
                 lastMyResponse: nil, changeMarker: "c2")
    #expect(try s.queue().map(\.id) == [j.id])
}

@Test func dismissedIdeaStaysHidden() throws {
    let s = try Store(path: tempStorePath())
    let a = try s.addIdea("a")
    try s.dismiss(a.id)
    #expect(try s.queue().isEmpty)
}

@Test func unknownIdThrows() throws {
    let s = try Store(path: tempStorePath())
    #expect(throws: StoreError.self) { try s.skip(999) }
    #expect(throws: StoreError.self) { try s.dismiss(999) }
    #expect(throws: StoreError.self) { try s.popToFront(999) }
}

@Test func persistsAcrossReopen() throws {
    let path = tempStorePath()
    do {
        let s = try Store(path: path)
        try s.addIdea("survives")
    }
    #expect(try titles(Store(path: path)) == ["survives"])
}

/// The app detects CLI writes via data_version, which moves on another connection's commit.
@Test func dataVersionSeesOtherConnectionWrites() throws {
    let path = tempStorePath()
    let app = try Store(path: path)
    let cli = try Store(path: path)
    let before = try app.dataVersion()
    try cli.addIdea("from cli")
    #expect(try app.dataVersion() != before)
    #expect(try titles(app) == ["from cli"])
}

@Test func settingsDefaultThenPersist() throws {
    let path = tempStorePath()
    let s = try Store(path: path)
    #expect(try s.loadSettings() == FocusSettings())
    var changed = FocusSettings()
    changed.fadeDelaySeconds = 9
    changed.redAtHours = 72
    try s.saveSettings(changed)
    let reopened = try Store(path: path).loadSettings()
    #expect(reopened.fadeDelaySeconds == 9)
    #expect(reopened.redAtHours == 72)
    #expect(reopened.ageScale.redAtHours == 72)
}

@Test func settingsAreClamped() throws {
    let s = try Store(path: tempStorePath())
    var bad = FocusSettings()
    bad.idleOpacity = 0
    bad.greenUntilHours = 50
    bad.redAtHours = 10          // below green: pushed above it
    bad.textScale = 9
    let saved = try s.saveSettings(bad)
    #expect(saved.idleOpacity == 0.05)
    #expect(saved.redAtHours == 51)
    #expect(saved.textScale == 1.6)
    #expect(try s.loadSettings() == saved)
}

@Test func deleteDemoItemsLeavesRealItems() throws {
    let s = try Store(path: tempStorePath())
    try s.addIdea("my real idea")
    try s.upsert(source: .jira, externalId: "PROJ-1", title: "real", detail: "", url: nil,
                 lastMyResponse: nil, changeMarker: "1")
    try s.upsert(source: .jira, externalId: "DEMO-1", title: "demo", detail: "", url: nil,
                 lastMyResponse: nil, changeMarker: "1")
    try s.upsert(source: .slack, externalId: "demo-abc", title: "demo", detail: "", url: nil,
                 lastMyResponse: nil, changeMarker: "1")
    #expect(try s.deleteDemoItems() == 2)
    #expect(try Set(s.queue().map(\.title)) == ["my real idea", "real"])
}

@Test func deleteIdeaRemovesOnlyIdeas() throws {
    let s = try Store(path: tempStorePath())
    let idea = try s.addIdea("finish me")
    let jira = try s.upsert(source: .jira, externalId: "A-1", title: "ticket", detail: "", url: nil,
                            lastMyResponse: nil, changeMarker: "1")
    try s.deleteIdea(idea.id)
    #expect(try s.queue().map(\.id) == [jira.id])
    #expect(throws: StoreError.self) { try s.item(idea.id) }
    #expect(throws: StoreError.self) { try s.deleteIdea(jira.id) }   // not an idea
    #expect(throws: StoreError.self) { try s.deleteIdea(999) }       // unknown
}

@Test func boomerangGoesToBottomAndComesBack() throws {
    let s = try Store(path: tempStorePath())
    let a = try s.addIdea("a", now: t0)
    try s.addIdea("b", now: t0.addingTimeInterval(1))
    try s.snooze(a.id, until: t0.addingTimeInterval(100))
    #expect(try titles(s) == ["b", "a"])
    #expect(try s.wakeSnoozed(now: t0.addingTimeInterval(50)).isEmpty)
    #expect(try s.wakeSnoozed(now: t0.addingTimeInterval(100)) == [a.id])
    let back = try s.item(a.id)
    #expect(back.snoozedUntil == nil && back.popSeq == nil)   // back in the age line, not popped
    #expect(back.movedAt == t0.addingTimeInterval(100))          // so it shakes
    #expect(try titles(s).first == "a")                           // oldest, so first in the line
}

@Test func boomerangedTicketReturnsBelowPoppedSlack() throws {
    let s = try Store(path: tempStorePath())
    let ticket = try s.upsert(source: .jira, externalId: "SEC-1", title: "old ticket", detail: "", url: nil,
                              lastMyResponse: t0.addingTimeInterval(-999_999), changeMarker: "c")
    try s.applySlack([SlackItemState(key: "dm:C1", title: "new dm", detail: "DM", url: nil,
                                     waitingSince: t0, marker: "1")], answered: [], kinds: Set(SlackKind.all))
    try s.snooze(ticket.id, until: t0)
    try s.wakeSnoozed(now: t0.addingTimeInterval(1))
    #expect(try titles(s) == ["new dm", "old ticket"])
}

@Test func newActivityEndsBoomerangEarly() throws {
    let s = try Store(path: tempStorePath())
    try s.addIdea("idea", now: t0)
    let st = SlackItemState(key: "dm:C1", title: "Ann: hi", detail: "DM", url: nil, waitingSince: t0, marker: "1")
    try s.applySlack([st], answered: [], kinds: Set(SlackKind.all))
    let id = try #require(try s.queue().first { $0.externalId == "dm:C1" }?.id)
    try s.snooze(id, until: t0.addingTimeInterval(9_999))
    try s.applySlack([st], answered: [], kinds: Set(SlackKind.all))          // same message: stays snoozed
    #expect(try s.item(id).snoozedUntil != nil)
    let more = SlackItemState(key: "dm:C1", title: "Ann: ping", detail: "DM", url: nil, waitingSince: t0, marker: "2")
    try s.applySlack([more], answered: [], kinds: Set(SlackKind.all))        // new message: back now
    #expect(try s.item(id).snoozedUntil == nil)
    #expect(try s.queue().first?.id == id)
}

@Test func poppedSlackOutranksOlderJiraReply() throws {
    let s = try Store(path: tempStorePath())
    let old = try s.upsert(source: .jira, externalId: "SEC-1", title: "old ticket with reply", detail: "", url: nil,
                           lastMyResponse: t0.addingTimeInterval(-999_999), changeMarker: "c")
    try s.popToFront(old.id)
    try s.applySlack([SlackItemState(key: "dm:C1", title: "new dm", detail: "DM", url: nil,
                                     waitingSince: t0, marker: "1")], answered: [], kinds: Set(SlackKind.all))
    #expect(try titles(s) == ["new dm", "old ticket with reply"])
}

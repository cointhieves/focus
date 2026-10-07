import Foundation
import Testing
@testable import FocusCore

private func store() throws -> Store {
    try Store(path: FileManager.default.temporaryDirectory.appendingPathComponent("focus-r-\(UUID().uuidString)/focus.db").path)
}

@Test func placedItemStaysWhereDroppedAndNewItemsFollowRules() throws {
    let s = try store()
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let a = try s.addIdea("a", now: t0)
    let b = try s.addIdea("b", now: t0.addingTimeInterval(1))
    let c = try s.addIdea("c", now: t0.addingTimeInterval(2))
    #expect(try s.queue().map(\.title) == ["a", "b", "c"])
    try s.place(c.id, before: a.id)                      // drag c to the top
    #expect(try s.queue().map(\.title) == ["c", "a", "b"])
    try s.place(a.id, before: nil)                       // drag a to the end
    #expect(try s.queue().map(\.title) == ["c", "b", "a"])
    _ = try s.addIdea("d", now: t0.addingTimeInterval(3)) // new item: normal rules
    #expect(try s.queue().map(\.title) == ["c", "b", "d", "a"])
    _ = b
}

@Test func popClearsPlacementAndPopGoesAbove() throws {
    let s = try store()
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let a = try s.addIdea("a", now: t0)
    let b = try s.addIdea("b", now: t0.addingTimeInterval(1))
    let c = try s.addIdea("c", now: t0.addingTimeInterval(2))
    try s.place(c.id, before: a.id)
    try s.popToFront(b.id)                                // new activity on b
    #expect(try s.queue().map(\.title) == ["b", "c", "a"])
    try s.popToFront(c.id)                                // c gets news: placement cleared
    try s.skip(c.id)                                      // dealt with: normal order (skipped)
    #expect(try s.queue().map(\.title) == ["b", "a", "c"])
}

@Test func skipAndDismissClearPlacement() throws {
    let s = try store()
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let a = try s.addIdea("a", now: t0)
    let b = try s.addIdea("b", now: t0.addingTimeInterval(1))
    try s.place(b.id, before: a.id)
    #expect(try s.queue().map(\.title) == ["b", "a"])
    try s.skip(b.id)
    #expect(try s.queue().map(\.title) == ["a", "b"])
}

@Test func placedRowStaysWhenTheRowBelowItPops() throws {
    let s = try store()
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let a = try s.addIdea("a", now: t0)
    let b = try s.addIdea("b", now: t0.addingTimeInterval(1))
    let c = try s.addIdea("c", now: t0.addingTimeInterval(2))
    let d = try s.addIdea("d", now: t0.addingTimeInterval(3))
    try s.place(d.id, before: c.id)                       // a b d c
    #expect(try s.queue().map(\.title) == ["a", "b", "d", "c"])
    try s.popToFront(c.id)                                // c pops; d must NOT follow it
    #expect(try s.queue().map(\.title) == ["c", "a", "b", "d"])
    _ = (a, b)
}

@Test func placedRowStaysWhenTheRowBelowItIsDeleted() throws {
    let s = try store()
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    _ = try s.addIdea("a", now: t0)
    let b = try s.addIdea("b", now: t0.addingTimeInterval(1))
    let c = try s.addIdea("c", now: t0.addingTimeInterval(2))
    try s.place(c.id, before: b.id)                       // a c b
    #expect(try s.queue().map(\.title) == ["a", "c", "b"])
    try s.deleteIdea(b.id)                                // c keeps its spot (now last)
    #expect(try s.queue().map(\.title) == ["a", "c"])
}

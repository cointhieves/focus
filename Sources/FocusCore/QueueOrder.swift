import Foundation

/// The queue ordering rules, kept pure so they can be unit tested.
///
/// 1. Popped items (someone is waiting on me): timed tasks whose deadline alert fired,
///    then Slack, then everything else (Jira replies), each longest-waiting first.
///    Slack is the priority.
/// 2. The age line: never-responded items first, then oldest last response.
///    Ideas have no responses, so they age from when they were created.
/// 3. Skipped items, in the order they were skipped.
/// 4. Boomeranged (snoozed) items, soonest back first.
public enum QueueOrder {
    public static func sort(_ items: [Item]) -> [Item] {
        items.sorted { a, b in
            let ta = tier(a), tb = tier(b)
            if ta != tb { return ta < tb }
            switch ta {
            case 0:
                let da = a.dueAt != nil && a.warnedLevel > 0, db = b.dueAt != nil && b.warnedLevel > 0
                if da != db { return da }
                if da { return a.dueAt! < b.dueAt! }
                let sa = a.source == .slack, sb = b.source == .slack
                if sa != sb { return sa }
                let ka = ageKey(a), kb = ageKey(b)
                return ka != kb ? ka < kb : a.id < b.id
            case 2: return (a.backSeq ?? 0) < (b.backSeq ?? 0)
            case 3: return a.snoozedUntil! < b.snoozedUntil!
            default:
                let ka = ageKey(a), kb = ageKey(b)
                return ka != kb ? ka < kb : a.id < b.id
            }
        }
    }

    /// Puts manually placed items back where they were dropped: each (in drop order) goes
    /// just before its anchor item; anchor 0 means the end. If the anchor isn't in the
    /// list (gone, hidden), the item keeps its normal position.
    public static func applyPlacements(_ sorted: [Item], placements: [Int64: (before: Int64, seq: Int64)]) -> [Item] {
        guard !placements.isEmpty else { return sorted }
        let ids = Set(sorted.map(\.id))
        let movable = placements.filter { ids.contains($0.key) && ($0.value.before == 0 || ids.contains($0.value.before)) }
        var out = sorted.filter { movable[$0.id] == nil }
        let byId = Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0) })
        for (id, p) in movable.sorted(by: { $0.value.seq < $1.value.seq }) {
            guard let item = byId[id] else { continue }
            if p.before == 0 { out.append(item); continue }
            if let i = out.firstIndex(where: { $0.id == p.before }) { out.insert(item, at: i) }
            else if let normal = sorted.firstIndex(where: { $0.id == id }) {
                // The anchor is itself placed later in the order: fall back to normal position.
                out.insert(item, at: min(normal, out.count))
            }
        }
        return out
    }

    /// Puts each group's tasks right under its heading: tasks whose warning fired first, then
    /// timed tasks soonest first, then untimed ones in group order, then boomeranged ones.
    /// A group with a fired task moves to the very top (several: earliest deadline first).
    public static func applyGroups(_ items: [Item]) -> [Item] {
        let headings = Set(items.filter(\.isGroup).map(\.id))
        let members = Dictionary(grouping: items.filter { $0.groupId.map(headings.contains) ?? false },
                                 by: { $0.groupId! })
        guard !headings.isEmpty else { return items }
        func fired(_ i: Item) -> Bool { i.popSeq != nil && i.snoozedUntil == nil && i.dueAt != nil }
        func rank(_ i: Item) -> Int { i.snoozedUntil != nil ? 3 : fired(i) ? 0 : i.dueAt != nil ? 1 : 2 }
        func ordered(_ g: Int64) -> [Item] {
            (members[g] ?? []).sorted { a, b in
                let ra = rank(a), rb = rank(b)
                if ra != rb { return ra < rb }
                switch ra {
                case 0, 1: return a.dueAt! != b.dueAt! ? a.dueAt! < b.dueAt! : a.id < b.id
                case 3: return a.snoozedUntil! < b.snoozedUntil!
                default: return (a.groupSeq ?? 0, a.id) < (b.groupSeq ?? 0, b.id)
                }
            }
        }
        var top: [(due: Date, block: [Item])] = [], rest: [Item] = []
        for item in items where !(item.groupId.map(headings.contains) ?? false) {
            guard item.isGroup else { rest.append(item); continue }
            let block = [item] + ordered(item.id)
            if let due = block.dropFirst().filter(fired).compactMap(\.dueAt).min() {
                top.append((due, block))
            } else {
                rest += block
            }
        }
        return top.sorted { $0.due < $1.due }.flatMap(\.block) + rest
    }

    static func tier(_ item: Item) -> Int {
        if item.snoozedUntil != nil { return 3 }
        if item.backSeq != nil { return 2 }
        if item.popSeq != nil { return 0 }
        return 1
    }

    /// Smaller = older = earlier in the age line.
    static func ageKey(_ item: Item) -> Double {
        if item.source == .idea { return item.createdAt.timeIntervalSince1970 }
        if item.source == .slack { return (item.waitingSince ?? item.createdAt).timeIntervalSince1970 }
        if let since = item.waitingSince { return since.timeIntervalSince1970 }   // Jira mention
        guard let last = item.lastMyResponse else { return -.infinity }
        return last.timeIntervalSince1970
    }
}

import Foundation
import SQLite3

public struct StoreError: Error, CustomStringConvertible {
    public let description: String
}

/// SQLite-backed queue, shared by the app and the CLI via the same database file.
/// Uses the system sqlite3 library through its C API (no third-party dependency).
public final class Store {
    private var db: OpaquePointer?

    /// SQLITE_TRANSIENT: tells SQLite to copy bound strings.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public static var defaultPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Focus/focus.db").path
    }

    public init(path: String = Store.defaultPath) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw StoreError(description: "cannot open database at \(path)")
        }
        // The app and CLI can write at the same time; wait briefly instead of failing.
        sqlite3_busy_timeout(db, 2000)
        try exec("PRAGMA journal_mode=WAL")
        try migrate()
    }

    deinit { sqlite3_close(db) }

    // MARK: - Schema

    private func migrate() throws {
        let version = try scalarInt("PRAGMA user_version") ?? 0
        if version < 1 {
            try exec("""
            CREATE TABLE IF NOT EXISTS items (
                id               INTEGER PRIMARY KEY,
                source           TEXT NOT NULL,
                external_id      TEXT,
                title            TEXT NOT NULL,
                detail           TEXT NOT NULL DEFAULT '',
                url              TEXT,
                created_at       REAL NOT NULL,
                last_my_response REAL,
                pop_seq          INTEGER,
                back_seq         INTEGER,
                moved_at         REAL NOT NULL,
                change_marker    TEXT NOT NULL DEFAULT '',
                dismissed_marker TEXT,
                UNIQUE (source, external_id)
            );
            PRAGMA user_version = 1;
            """)
        }
        if version < 2 {
            // Timed items: one-shot deadline plus which warnings have already fired.
            try exec("""
            ALTER TABLE items ADD COLUMN due_at REAL;
            ALTER TABLE items ADD COLUMN warned_level INTEGER NOT NULL DEFAULT 0;
            PRAGMA user_version = 2;
            """)
        }
        if version < 3 {
            try exec("""
            CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value REAL NOT NULL);
            PRAGMA user_version = 3;
            """)
        }
        if version < 4 {
            // Text preferences (Jira site, email, ...). Secrets never go here.
            try exec("""
            CREATE TABLE IF NOT EXISTS prefs (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            PRAGMA user_version = 4;
            """)
        }
        if version < 5 {
            // Jira tickets that left scope are kept (greyed) until cleared by hand.
            try exec("""
            ALTER TABLE items ADD COLUMN removed_at REAL;
            PRAGMA user_version = 5;
            """)
        }
        if version < 6 {
            // Slack: when the first unanswered message arrived (the age clock's start).
            try exec("""
            ALTER TABLE items ADD COLUMN waiting_since REAL;
            PRAGMA user_version = 6;
            """)
        }
        if version < 7 {
            // Jira moved from weekday hours to business hours: 24/48 meant 1 and 2 working days.
            try exec("""
            UPDATE settings SET value = 8 WHERE key = 'green_until_hours' AND value = 24;
            UPDATE settings SET value = 16 WHERE key = 'red_at_hours' AND value = 48;
            PRAGMA user_version = 7;
            """)
        }
        if version < 8 {
            // Boomerang: an item sits at the bottom until this time.
            try exec("""
            ALTER TABLE items ADD COLUMN snoozed_until REAL;
            PRAGMA user_version = 8;
            """)
        }
        if version < 9 {
            // "idea" was renamed "task" in the UI; the stored detail line follows.
            try exec("""
            UPDATE items SET detail = 'task' WHERE source = 'idea' AND detail = 'idea';
            PRAGMA user_version = 9;
            """)
        }
    }

    // MARK: - Reads

    /// The visible queue in display order. Dismissed items stay hidden until
    /// their source changes their change marker.
    public func queue() throws -> [Item] {
        let rows = try query("""
            SELECT id, source, external_id, title, detail, url, created_at,
                   last_my_response, pop_seq, back_seq, moved_at, due_at, warned_level, removed_at, waiting_since, snoozed_until
            FROM items
            WHERE dismissed_marker IS NULL OR dismissed_marker != change_marker
            """)
        return QueueOrder.sort(rows.filter(try visibleFilter()))
    }

    /// Items of a source (or Slack type) that's switched off are kept but hidden, so turning
    /// it back on restores them with their dismiss/boomerang state instead of re-popping
    /// everything. Hidden only when explicitly off; demo rows always show.
    private func visibleFilter() throws -> (Item) -> Bool {
        let slackOff = try pref("slack_enabled") == "0"
        let jiraOff = try pref("jira_enabled") == "0"
        let mentionsOff = try pref("jira_mentions") == "0"
        let sprintOff = try pref("jira_sprint") == "0"
        let reportedOff = try pref("jira_reported") == "0"
        let kinds = try pref("slack_kinds").map { Set($0.split(separator: ",").map(String.init)) }
        return { item in
            let ext = item.externalId ?? ""
            if ext.contains("DEMO-") || ext.hasPrefix("demo-") { return true }
            switch item.source {
            case .slack:
                if slackOff { return false }
                if let kinds, !kinds.contains(String(ext.split(separator: ":").first ?? "")) { return false }
                return true
            case .jira:
                if jiraOff { return false }
                if ext.hasPrefix("mention:") { return !mentionsOff }
                if ext.hasPrefix("reported:") { return !reportedOff }
                return !sprintOff
            case .idea: return true
            }
        }
    }

    /// Changes whenever ANOTHER connection commits to the database. Cheap to poll.
    /// A connection's own commits do not change it, so callers reload after writing.
    public func dataVersion() throws -> Int64 {
        try scalarInt("PRAGMA data_version") ?? 0
    }

    // MARK: - Writes

    /// Adds a task (stored with source "idea"). "... by 5pm" or "... in 30 minutes" in the text sets a deadline,
    /// unless `due` is passed explicitly.
    @discardableResult
    public func addIdea(_ text: String, due explicitDue: Date? = nil, now: Date = Date()) throws -> Item {
        let parsed: (title: String, due: Date?) =
            explicitDue == nil ? Deadline.parse(text, now: now) : (text, nil)
        let title = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw StoreError(description: "task text is empty") }
        let due = explicitDue ?? parsed.due
        if let due, due <= now { throw StoreError(description: "due time is in the past") }
        let item = try insert(source: .idea, externalId: nil, title: title, detail: "task",
                              url: nil, lastMyResponse: nil, now: now)
        guard let due else { return item }
        try run("UPDATE items SET due_at = ? WHERE id = ?", due.timeIntervalSince1970, item.id)
        return try self.item(item.id)
    }

    /// Fires any deadline warnings that are due: pops the item to the front and marks it
    /// moved (so it shakes) even if it is already first. Each level fires once.
    /// Returns the ids that were warned.
    @discardableResult
    public func advanceDeadlines(now: Date = Date()) throws -> [Int64] {
        var warned: [Int64] = []
        for item in try queue() {
            guard let due = item.dueAt else { continue }
            let level = Deadline.level(created: item.createdAt, due: due, now: now)
            guard level > item.warnedLevel else { continue }
            try run("""
                UPDATE items SET warned_level = ?, moved_at = ?, back_seq = NULL, snoozed_until = NULL,
                                 pop_seq = (SELECT COALESCE(MAX(pop_seq), 0) + 1 FROM items)
                WHERE id = ?
                """, level, now.timeIntervalSince1970, item.id)
            warned.append(item.id)
        }
        return warned
    }

    /// Adds or updates a source item (Jira, Slack). Used by the Simulate menu now
    /// and by real source pollers later.
    @discardableResult
    public func upsert(source: ItemSource, externalId: String, title: String, detail: String,
                       url: URL?, lastMyResponse: Date?, changeMarker: String,
                       now: Date = Date()) throws -> Item {
        if let existing = try itemId(source: source, externalId: externalId) {
            try run("""
                UPDATE items SET title = ?, detail = ?, url = ?, last_my_response = ?, change_marker = ?,
                                 removed_at = NULL
                WHERE id = ?
                """, title, detail, url?.absoluteString, lastMyResponse?.timeIntervalSince1970,
                changeMarker, existing)
            return try item(existing)
        }
        let item = try insert(source: source, externalId: externalId, title: title, detail: detail,
                              url: url, lastMyResponse: lastMyResponse, now: now)
        try run("UPDATE items SET change_marker = ? WHERE id = ?", changeMarker, item.id)
        return item
    }

    /// Moves an item to the front. Returns false (and changes nothing) if it is already first.
    @discardableResult
    public func popToFront(_ id: Int64, now: Date = Date()) throws -> Bool {
        let current = try queue()
        guard let target = current.first(where: { $0.id == id }) else { throw notFound(id) }
        if current.first?.id == id && target.snoozedUntil == nil { return false }
        // Also ends a boomerang: new activity brings a snoozed item back early.
        try run("""
            UPDATE items SET pop_seq = (SELECT COALESCE(MAX(pop_seq), 0) + 1 FROM items),
                             back_seq = NULL, snoozed_until = NULL, moved_at = ?
            WHERE id = ?
            """, now.timeIntervalSince1970, id)
        return true
    }

    /// Sends an item to the back of the line.
    public func skip(_ id: Int64) throws {
        try requireExists(id)
        try run("""
            UPDATE items SET back_seq = (SELECT COALESCE(MAX(back_seq), 0) + 1 FROM items),
                             pop_seq = NULL, snoozed_until = NULL
            WHERE id = ?
            """, id)
    }

    // MARK: - Boomerang

    /// Sends an item to the bottom until `until`. Its place (popped, age line, skipped)
    /// is kept, so it returns to where it was: Slack stays above Jira.
    public func snooze(_ id: Int64, until: Date) throws {
        try requireExists(id)
        try run("UPDATE items SET snoozed_until = ? WHERE id = ?", until.timeIntervalSince1970, id)
    }

    /// Brings a snoozed item back now, to the place it had before, marked moved so it
    /// shakes and lights up.
    public func unsnooze(_ id: Int64, now: Date = Date()) throws {
        try requireExists(id)
        try run("UPDATE items SET snoozed_until = NULL, moved_at = ? WHERE id = ?", now.timeIntervalSince1970, id)
    }

    /// Pops back every item whose boomerang time has come. Returns their ids.
    @discardableResult
    public func wakeSnoozed(now: Date = Date()) throws -> [Int64] {
        let stmt = try prepare("SELECT id FROM items WHERE snoozed_until IS NOT NULL AND snoozed_until <= ?",
                               [now.timeIntervalSince1970])
        var ids: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW { ids.append(sqlite3_column_int64(stmt, 0)) }
        sqlite3_finalize(stmt)
        for id in ids { try unsnooze(id, now: now) }
        return ids
    }

    /// Hides an item until its source changes it. Tasks never change, so they stay hidden.
    /// A removed (out of scope) ticket is cleared: deleted outright.
    public func dismiss(_ id: Int64) throws {
        if try item(id).removed {
            try run("DELETE FROM items WHERE id = ?", id)
            return
        }
        try run("UPDATE items SET dismissed_marker = change_marker WHERE id = ?", id)
    }

    /// Permanently deletes a task (marking it done). Refuses Jira/Slack items, which a
    /// source poller would just re-create; use dismiss for those.
    public func deleteIdea(_ id: Int64) throws {
        let existing = try item(id)
        guard existing.source == .idea else {
            throw StoreError(description: "item \(id) is a \(existing.source.rawValue) item; use dismiss instead")
        }
        try run("DELETE FROM items WHERE id = ?", id)
    }

    /// Deletes the demo items created by the Settings "Try it" buttons. Returns how many.
    /// Matches only the demo external ids, never real items or user tasks.
    @discardableResult
    public func deleteDemoItems() throws -> Int {
        try run("""
            DELETE FROM items
            WHERE (source = 'slack' AND (external_id LIKE 'demo-%' OR external_id LIKE '%DEMO-%'))
               OR (source = 'jira' AND (external_id LIKE 'DEMO-%' OR external_id LIKE 'mention:DEMO-%'))
            """)
        return Int(sqlite3_changes(db))
    }

    // MARK: - Settings

    /// Saved settings; any value never saved keeps its default. Always returns valid values.
    public func loadSettings() throws -> FocusSettings {
        let stmt = try prepare("SELECT key, value FROM settings", [])
        defer { sqlite3_finalize(stmt) }
        var settings = FocusSettings()
        while sqlite3_step(stmt) == SQLITE_ROW {
            settings.apply(key: String(cString: sqlite3_column_text(stmt, 0)),
                           value: sqlite3_column_double(stmt, 1))
        }
        return settings.clamped()
    }

    /// Saves settings (clamped first) and returns what was actually stored.
    @discardableResult
    public func saveSettings(_ settings: FocusSettings) throws -> FocusSettings {
        let valid = settings.clamped()
        try exec("BEGIN IMMEDIATE")
        do {
            for (key, value) in valid.asPairs {
                try run("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                        key, value)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return valid
    }

    // MARK: - Jira

    /// A single text preference, or nil if never set.
    public func pref(_ key: String) throws -> String? {
        let stmt = try prepare("SELECT value FROM prefs WHERE key = ?", [key])
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? String(cString: sqlite3_column_text(stmt, 0)) : nil
    }

    public func setPref(_ key: String, _ value: String) throws {
        try run("INSERT INTO prefs (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", key, value)
    }

    public func loadJiraConfig() throws -> JiraConfig {
        let stmt = try prepare("SELECT key, value FROM prefs WHERE key LIKE 'jira_%'", [])
        defer { sqlite3_finalize(stmt) }
        var c = JiraConfig()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let key = String(cString: sqlite3_column_text(stmt, 0))
            let value = String(cString: sqlite3_column_text(stmt, 1))
            switch key {
            case "jira_enabled": c.enabled = value == "1"
            case "jira_email": c.email = value
            case "jira_ignored": c.ignoredAccountIds = value.split(separator: ",").map(String.init)
            default: break
            }
        }
        return c
    }

    public func saveJiraConfig(_ c: JiraConfig) throws {
        let ignored = c.ignoredAccountIds
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ",")
        for (k, v) in [("jira_enabled", c.enabled ? "1" : "0"),
                       ("jira_email", c.email.trimmingCharacters(in: .whitespaces)), ("jira_ignored", ignored)] {
            try run("INSERT INTO prefs (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", k, v)
        }
    }

    /// Applies a Jira sync: upserts qualifying tickets, pops ones with a new reply, and
    /// handles Jira rows that no longer qualify (DEMO-* rows from Try it are kept):
    /// - still in scope (I replied) or closed: deleted;
    /// - out of scope: marked removed and popped to the front, so it is noticed, and kept
    ///   until cleared by hand (a dismissed one is just deleted).
    /// With `inScopeKeys` nil (Jira turned off) every other Jira row is deleted.
    /// Returns the keys that were popped.
    @discardableResult
    /// `limitTo` restricts the removal pass to those keys (the Try it demos use it so a
    /// synthetic sync never touches real tickets); by default DEMO-* rows are skipped.
    public func applyJira(_ states: [JiraTicketState], inScopeKeys: Set<String>? = nil,
                          doneKeys: Set<String> = [], limitTo: Set<String>? = nil,
                          site: URL?, now: Date = Date()) throws -> [String] {
        var popped: [String] = []
        for st in states {
            let previous = try changeMarker(source: .jira, externalId: st.key)
            let detail = st.waitingOnMe ? "\(st.key) · waiting on you"
                : st.myLastComment == nil ? "\(st.key) · never commented" : st.key
            let item = try upsert(source: .jira, externalId: st.key, title: st.summary, detail: detail,
                                  url: site?.appendingPathComponent("browse/\(st.key)"),
                                  lastMyResponse: st.myLastComment, changeMarker: st.changeMarker, now: now)
            // A new reply (marker changed, or first time seen while waiting) pops it to the front.
            if st.waitingOnMe && previous != st.changeMarker {
                if try popToFront(item.id, now: now) { popped.append(st.key) }
            }
        }
        let keep = Set(states.map(\.key))
        // Mention rows ("mention:KEY") are managed by applyJiraMentions; a ticket that is
        // now a sprint item drops its mention row so it isn't shown twice.
        for (id, key) in try externalIds(source: .jira) where Self.mentionKey(key).map(keep.contains) == true {
            try run("DELETE FROM items WHERE id = ?", id)
        }
        for (id, key) in try externalIds(source: .jira) where Self.mentionKey(key) == nil && !keep.contains(key) && (limitTo?.contains(key) ?? !key.hasPrefix("DEMO-")) {
            guard let inScopeKeys, !inScopeKeys.contains(key), !doneKeys.contains(key) else {
                try run("DELETE FROM items WHERE id = ?", id)
                continue
            }
            try markRemoved(id, now: now)
        }
        return popped
    }

    /// Marks a ticket as out of scope and pops it to the front. Already-removed rows are
    /// left alone; a dismissed one is deleted, since it was already hidden.
    /// Public so the Try it demo can use it.
    public func markRemoved(_ id: Int64, now: Date = Date()) throws {
        try run("DELETE FROM items WHERE id = ? AND removed_at IS NULL AND dismissed_marker = change_marker", id)
        try run("""
            UPDATE items SET removed_at = ?, moved_at = ?, back_seq = NULL, snoozed_until = NULL,
                             pop_seq = (SELECT COALESCE(MAX(pop_seq), 0) + 1 FROM items)
            WHERE id = ? AND removed_at IS NULL
            """, now.timeIntervalSince1970, now.timeIntervalSince1970, id)
    }

    // MARK: - Jira mentions

    /// Applies a mention sync, like Slack: new items pop once; a new mention on a snoozed
    /// or dismissed item brings it back; answered or Done items are deleted; items not in
    /// this sync are kept until answered. Rows are "mention:KEY".
    @discardableResult
    public func applyJiraMentions(_ states: [JiraMentionState], remove: Set<String>, site: URL?,
                                  limitTo: Set<String>? = nil, now: Date = Date()) throws -> [String] {
        var popped: [String] = []
        for st in states {
            let ext = (st.viaReport ? "reported:" : "mention:") + st.key
            // One row per ticket: if the reason changed (a mention arrived on my reported
            // ticket, or the reverse), the new row replaces the old one.
            try run("DELETE FROM items WHERE source = 'jira' AND external_id = ?",
                    (st.viaReport ? "mention:" : "reported:") + st.key)
            let existing = try itemId(source: .jira, externalId: ext)
            let wasHidden = try existing.map { try isDismissed($0) } ?? false
            let previous = try changeMarker(source: .jira, externalId: ext)
            let item = try upsert(source: .jira, externalId: ext, title: st.summary,
                                  detail: "\(st.key) · \(st.mentionedBy) " + (st.viaReport ? "commented" : "mentioned you"),
                                  url: site?.appendingPathComponent("browse/\(st.key)"),
                                  lastMyResponse: nil, changeMarker: st.marker, now: now)
            try run("UPDATE items SET waiting_since = COALESCE(waiting_since, ?) WHERE id = ?",
                    st.waitingSince.timeIntervalSince1970, item.id)
            let visible = try !isDismissed(item.id)
            let snoozedWithNews = try self.item(item.id).snoozedUntil != nil && previous != st.marker
            if existing == nil || (wasHidden && visible) || snoozedWithNews {
                if try popToFront(item.id, now: now) { popped.append(st.key) }
                else { try run("UPDATE items SET moved_at = ? WHERE id = ?", now.timeIntervalSince1970, item.id) }
            }
        }
        for key in remove where limitTo?.contains(key) ?? !key.hasPrefix("DEMO-") {
            try run("DELETE FROM items WHERE source = 'jira' AND external_id IN (?, ?)", "mention:\(key)", "reported:\(key)")
        }
        return popped
    }

    /// Mention keys currently in the queue (without the "mention:" prefix).
    public func mentionKeys() throws -> Set<String> {
        Set(try externalIds(source: .jira).map(\.1).filter { !$0.contains("DEMO-") }.compactMap(Self.mentionKey))
    }

    /// Deletes every real Jira row (Jira disconnected).
    public func deleteJiraItems() throws {
        try run("DELETE FROM items WHERE source = 'jira' AND external_id NOT LIKE '%DEMO-%'")
    }

    /// The ticket key of a mention-style row ("mention:KEY" or "reported:KEY"), else nil.
    public static func mentionKey(_ externalId: String) -> String? {
        for p in ["mention:", "reported:"] where externalId.hasPrefix(p) { return String(externalId.dropFirst(p.count)) }
        return nil
    }

    public func deleteMentionItems() throws {
        try run("DELETE FROM items WHERE source = 'jira' AND external_id LIKE 'mention:%' AND external_id NOT LIKE '%DEMO-%'")
    }

    // MARK: - Slack

    /// Applies a Slack sync:
    /// - each waiting conversation/thread/mention is upserted; it pops only when it is new
    ///   (or was dismissed and has new activity), so more messages don't re-pop it;
    /// - rows whose key is in `answered` (I replied or reacted) are deleted;
    /// - rows of a kind not in `kinds` are deleted;
    /// - other rows not in this sync are kept: items stay until answered.
    /// `limitTo` restricts the delete pass (Try it demos); by default DEMO rows are skipped.
    /// Returns the keys that popped.
    @discardableResult
    public func applySlack(_ states: [SlackItemState], answered: Set<String>, kinds: Set<String>,
                           limitTo: Set<String>? = nil, now: Date = Date()) throws -> [String] {
        var popped: [String] = []
        for st in states where kinds.contains(st.kind) {
            let existing = try itemId(source: .slack, externalId: st.key)
            let wasHidden = try existing.map { try isDismissed($0) } ?? false
            let previous = try changeMarker(source: .slack, externalId: st.key)
            let item = try upsert(source: .slack, externalId: st.key, title: st.title, detail: st.detail,
                                  url: st.url, lastMyResponse: nil, changeMarker: st.marker, now: now)
            // Each sync recomputes when the first unanswered message arrived; a reply or
            // reaction moves it later, so take the sync's value rather than keeping the old one.
            try run("UPDATE items SET waiting_since = ? WHERE id = ?", st.waitingSince.timeIntervalSince1970, item.id)
            let nowVisible = try !isDismissed(item.id)
            let snoozedWithNews = try self.item(item.id).snoozedUntil != nil && previous != st.marker
            if existing == nil || (wasHidden && nowVisible) || snoozedWithNews {
                if try popToFront(item.id, now: now) { popped.append(st.key) }
                else { try run("UPDATE items SET moved_at = ? WHERE id = ?", now.timeIntervalSince1970, item.id) }
            }
        }
        for (id, key) in try externalIds(source: .slack) where limitTo?.contains(key) ?? !key.contains("DEMO-") {
            // Turned-off kinds are hidden by queue(), not deleted, so they keep their state.
            if answered.contains(key) {
                try run("DELETE FROM items WHERE id = ?", id)
            }
        }
        return popped
    }

    /// Deletes every real Slack row (Slack turned off or disconnected).
    public func deleteSlackItems() throws {
        try run("DELETE FROM items WHERE source = 'slack' AND external_id NOT LIKE '%DEMO-%' AND external_id NOT LIKE 'demo-%'")
    }

    /// Slack keys currently stored, with their newest-message marker (for re-checking).
    public func slackMarkers() throws -> [String: String] {
        let stmt = try prepare("SELECT external_id, change_marker FROM items WHERE source = 'slack' AND external_id IS NOT NULL", [])
        defer { sqlite3_finalize(stmt) }
        var out: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            out[String(cString: sqlite3_column_text(stmt, 0))] = String(cString: sqlite3_column_text(stmt, 1))
        }
        return out.filter { !$0.key.contains("DEMO-") && !$0.key.hasPrefix("demo-") }
    }

    private func isDismissed(_ id: Int64) throws -> Bool {
        let stmt = try prepare("SELECT dismissed_marker IS NOT NULL AND dismissed_marker = change_marker FROM items WHERE id = ?", [id])
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 0) == 1
    }

    private func changeMarker(source: ItemSource, externalId: String) throws -> String? {
        let stmt = try prepare("SELECT change_marker FROM items WHERE source = ? AND external_id = ?",
                               [source.rawValue, externalId])
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? String(cString: sqlite3_column_text(stmt, 0)) : nil
    }

    private func externalIds(source: ItemSource) throws -> [(Int64, String)] {
        let stmt = try prepare("SELECT id, external_id FROM items WHERE source = ? AND external_id IS NOT NULL",
                               [source.rawValue])
        defer { sqlite3_finalize(stmt) }
        var out: [(Int64, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((sqlite3_column_int64(stmt, 0), String(cString: sqlite3_column_text(stmt, 1))))
        }
        return out
    }

    // MARK: - Helpers

    private func insert(source: ItemSource, externalId: String?, title: String, detail: String,
                        url: URL?, lastMyResponse: Date?, now: Date) throws -> Item {
        try run("""
            INSERT INTO items (source, external_id, title, detail, url, created_at, last_my_response, moved_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, source.rawValue, externalId, title, detail, url?.absoluteString,
            now.timeIntervalSince1970, lastMyResponse?.timeIntervalSince1970, now.timeIntervalSince1970)
        return try item(sqlite3_last_insert_rowid(db))
    }

    public func item(_ id: Int64) throws -> Item {
        let rows = try query("""
            SELECT id, source, external_id, title, detail, url, created_at,
                   last_my_response, pop_seq, back_seq, moved_at, due_at, warned_level, removed_at, waiting_since, snoozed_until
            FROM items WHERE id = ?
            """, id)
        guard let row = rows.first else { throw notFound(id) }
        return row
    }

    private func itemId(source: ItemSource, externalId: String) throws -> Int64? {
        let stmt = try prepare("SELECT id FROM items WHERE source = ? AND external_id = ?",
                               [source.rawValue, externalId])
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : nil
    }

    private func requireExists(_ id: Int64) throws { _ = try item(id) }

    private func notFound(_ id: Int64) -> StoreError { StoreError(description: "no item with id \(id)") }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(err)
            throw StoreError(description: msg)
        }
    }

    private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError(description: String(cString: sqlite3_errmsg(db)))
        }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case nil: sqlite3_bind_null(stmt, idx)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            default:
                sqlite3_finalize(stmt)
                throw StoreError(description: "unsupported bind type \(type(of: arg!))")
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ args: Any?...) throws {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError(description: String(cString: sqlite3_errmsg(db)))
        }
    }

    private func scalarInt(_ sql: String) throws -> Int64? {
        let stmt = try prepare(sql, [])
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : nil
    }

    private func query(_ sql: String, _ args: Any?...) throws -> [Item] {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var items: [Item] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func text(_ i: Int32) -> String? {
                sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, i))
            }
            func double(_ i: Int32) -> Double? {
                sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, i)
            }
            func int(_ i: Int32) -> Int64? {
                sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, i)
            }
            items.append(Item(
                id: sqlite3_column_int64(stmt, 0),
                source: ItemSource(rawValue: text(1) ?? "") ?? .idea,
                externalId: text(2),
                title: text(3) ?? "",
                detail: text(4) ?? "",
                url: text(5).flatMap(URL.init(string:)),
                createdAt: Date(timeIntervalSince1970: double(6) ?? 0),
                lastMyResponse: double(7).map(Date.init(timeIntervalSince1970:)),
                popSeq: int(8),
                backSeq: int(9),
                movedAt: Date(timeIntervalSince1970: double(10) ?? 0),
                dueAt: double(11).map(Date.init(timeIntervalSince1970:)),
                warnedLevel: Int(int(12) ?? 0),
                removedAt: double(13).map(Date.init(timeIntervalSince1970:)),
                waitingSince: double(14).map(Date.init(timeIntervalSince1970:)),
                snoozedUntil: double(15).map(Date.init(timeIntervalSince1970:))
            ))
        }
        return items
    }
}

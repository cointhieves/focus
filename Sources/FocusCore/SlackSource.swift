import Foundation

/// Finds Slack conversations, threads and mentions waiting on me. See PLAN.md 5d.
/// Everything is found by search (fast, and within Slack's limits); reading every DM
/// is not possible (the probe hit 368 rate-limit refusals out of 499).
public final class SlackSource: @unchecked Sendable {
    let client: SlackClient
    public let token: String
    let me: String
    /// user id -> (display name, is a real person). Kept across syncs.
    private var users: [String: (name: String, human: Bool)] = [:]
    /// User groups I'm in (ids), refreshed hourly. Empty if the token lacks usergroups:read
    /// (connected before that permission was added): group mentions are then skipped.
    private var myGroups: [String] = []
    private var groupsFetchedAt = Date.distantPast

    public init(client: SlackClient = SlackClient(), token: String, me: String) {
        self.client = client; self.token = token; self.me = me
    }

    /// Same user and name cache, new token (after rotation).
    public func with(token: String) -> SlackSource {
        let s = SlackSource(client: client, token: token, me: me)
        s.users = users
        s.myGroups = myGroups
        s.groupsFetchedAt = groupsFetchedAt
        return s
    }

    // MARK: - Pure helpers (unit tested)

    /// A Slack title without the message: "Ann: hi" -> "Message from Ann",
    /// "Ann in #ops: hi" -> "Message from Ann in #ops".
    public static func withoutText(_ title: String) -> String {
        guard let r = title.range(of: ": ") else { return title }
        return "Message from " + title[..<r.lowerBound]
    }

    static func ts(_ s: Any?) -> Double? { (s as? String).flatMap(Double.init) }

    /// thread_ts from a search permalink (`?thread_ts=`), or nil for a top-level message.
    static func threadParam(_ permalink: String?) -> String? {
        permalink.flatMap { URLComponents(string: $0)?.queryItems?.first { $0.name == "thread_ts" }?.value }
    }

    /// Slack markup to plain text: <@U1> -> @name, <#C1|x> -> #x, <url|label> -> label,
    /// <!here> -> @here, HTML entities; single line, truncated.
    static func clean(_ text: String, names: [String: String], limit: Int = 140) -> String {
        func sub(_ s: String, _ pattern: String, _ template: String) -> String {
            let re = try! NSRegularExpression(pattern: pattern)
            return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        var s = text
        for (id, name) in names {
            s = sub(s, "<@\(id)(\\|[^>]*)?>", NSRegularExpression.escapedTemplate(for: "@" + name))
        }
        s = sub(s, "<@[UW][A-Z0-9]+\\|([^>]+)>", "@$1")
        s = sub(s, "<@[UW][A-Z0-9]+>", "@someone")
        s = sub(s, "<#[A-Z0-9]+\\|([^>]+)>", "#$1")
        s = sub(s, "<#[A-Z0-9]+>", "#channel")
        s = sub(s, "<!([a-z]+)[^>]*>", "@$1")
        s = sub(s, "<(https?://[^|>]+)\\|([^>]+)>", "$2")
        s = sub(s, "<(https?://[^>]+)>", "$1")
        // Common status shortcodes used by alert bots.
        for (code, emoji) in [("white_check_mark", "✅"), ("warning", "⚠️"), ("x", "❌"), ("rotating_light", "🚨"),
                              ("red_circle", "🔴"), ("large_yellow_circle", "🟡"), ("large_green_circle", "🟢"),
                              ("fire", "🔥"), ("heavy_check_mark", "✔️"), ("exclamation", "❗")] {
            s = s.replacingOccurrences(of: ":\(code):", with: emoji)
        }
        s = s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        s = sub(s, "\\s+", " ").trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return "(attachment)" }
        return s.count > limit ? String(s.prefix(limit - 1)) + "…" : s
    }

    static func mentionIds(_ text: String) -> [String] {
        let re = try! NSRegularExpression(pattern: "<@([UW][A-Z0-9]+)")
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    // MARK: - Slack calls

    func call(_ method: String, _ form: [String: String]) async throws -> [String: Any] {
        try await client.post(method, form: form, token: token)
    }

    func user(_ id: String) async -> (name: String, human: Bool) {
        if let u = users[id] { return u }
        let j = try? await call("users.info", ["user": id])
        let u = j?["user"] as? [String: Any]
        let p = u?["profile"] as? [String: Any]
        let name = (p?["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (u?["real_name"] as? String) ?? id
        let bot = u?["is_bot"] as? Bool == true || u?["is_app_user"] as? Bool == true
            || u?["is_workflow_bot"] as? Bool == true || u?["deleted"] as? Bool == true
            // Slack's own accounts aren't flagged as bots: Slackbot, and "Slack" (system notices).
            || id == "USLACKBOT" || id == "USLACK"
        // Only cache a real lookup, so a failed call is retried next sync.
        if u != nil { users[id] = (name, !bot) }
        return (name, u != nil && !bot)
    }

    /// A message from another real person (not me, not a bot, not a system message).
    func fromOtherHuman(_ m: [String: Any]) async -> Bool {
        guard let uid = m["user"] as? String, uid != me, m["bot_id"] == nil else { return false }
        if let sub = m["subtype"] as? String, sub != "thread_broadcast" { return false }
        return await user(uid).human
    }

    func reactedByMe(_ m: [String: Any]?) -> Bool {
        ((m?["reactions"] as? [[String: Any]]) ?? []).contains { ($0["users"] as? [String] ?? []).contains(me) }
    }

    func text(_ m: [String: Any]) async -> String {
        let raw = m["text"] as? String ?? ""
        var names: [String: String] = [:]
        for id in Set(Self.mentionIds(raw)) { names[id] = await user(id).name }
        return Self.clean(raw, names: names)
    }

    func searchAll(_ query: String) async throws -> [[String: Any]] {
        var all: [[String: Any]] = [], page = 1, pages = 1
        repeat {
            let j = try await call("search.messages", ["query": query, "sort": "timestamp", "count": "100", "page": String(page)])
            let m = j["messages"] as? [String: Any]
            all += (m?["matches"] as? [[String: Any]]) ?? []
            pages = ((m?["paging"] as? [String: Any])?["pages"] as? Int) ?? 1
            page += 1
        } while page <= min(pages, 5)
        return all
    }

    /// My user groups, cached for an hour. A missing permission is not an error.
    func groups(now: Date) async -> [String] {
        guard now.timeIntervalSince(groupsFetchedAt) > 3600 else { return myGroups }
        if let j = try? await call("usergroups.list", ["include_users": "true"]) {
            let all = (j["usergroups"] as? [[String: Any]]) ?? []
            myGroups = all.filter { (($0["users"] as? [String]) ?? []).contains(me) }.compactMap { $0["id"] as? String }
        }
        groupsFetchedAt = now   // on failure too, so it isn't retried every sync
        return myGroups
    }

    /// First readable text in Block Kit blocks: a header, else a section's text or first field.
    static func blockText(_ blocks: Any?) -> String? {
        for b in (blocks as? [[String: Any]]) ?? [] {
            if let t = (b["text"] as? [String: Any])?["text"] as? String, !t.isEmpty { return t }
            if let f = (b["fields"] as? [[String: Any]])?.first?["text"] as? String, !f.isEmpty { return f }
        }
        return nil
    }

    /// Bot posts keep their content in blocks or attachments; fall back to those.
    func alertText(_ m: [String: Any]) async -> String {
        let t = await text(m)
        guard t == "(attachment)" else { return t }
        if let b = Self.blockText(m["blocks"]) { return Self.clean(b, names: [:]) }
        let a = (m["attachments"] as? [[String: Any]])?.first
        let raw = (a?["title"] as? String) ?? (a?["fallback"] as? String) ?? (a?["text"] as? String) ?? ""
        return raw.isEmpty ? t : Self.clean(raw, names: [:])
    }

    /// Normalizes a channel name for matching: lowercase, no leading #.
    public static func channelKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "#", with: "")
    }

    /// One top-level message (for its reactions).
    func message(_ channel: String, _ ts: String) async -> [String: Any]? {
        let j = try? await call("conversations.history", ["channel": channel, "latest": ts, "inclusive": "true", "limit": "1"])
        return (j?["messages"] as? [[String: Any]])?.first { ($0["ts"] as? String) == ts }
    }

    /// True if I already replied; otherwise checks for my reaction (one API call).
    func repliedOrReacted(_ replied: Bool, _ channel: String, _ ts: String) async throws -> Bool {
        if replied { return true }
        return reactedByMe(await message(channel, ts))
    }

    // MARK: - Sync

    /// `open`: keys already in the queue -> their stored marker (newest message ts).
    /// `botChannels`: channel names where bot messages that mention me (or my groups) count.
    public func sync(open: [String: String], kinds: Set<String>, firstRun: Bool,
                     botChannels: Set<String> = [], now: Date = Date()) async throws -> SlackSyncResult {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"
        // `after:` excludes the given day, so step back one more.
        func after(_ d: Date) -> String { day.string(from: d.addingTimeInterval(-86_400)) }
        let newSince = firstRun ? WeekdayClock.date(weekdayHours: 72, before: now) : now.addingTimeInterval(-2 * 86_400)
        let wideSince = min(newSince, now.addingTimeInterval(-7 * 86_400))

        var states: [SlackItemState] = [], answered = Set<String>(), handled = Set<String>()
        var channelNames: [String: String] = [:]
        var host = "slack.com"
        func note(_ m: [String: Any]) {
            let ch = m["channel"] as? [String: Any]
            if let id = ch?["id"] as? String, let n = ch?["name"] as? String { channelNames[id] = n }
            if let p = m["permalink"] as? String, let h = URL(string: p)?.host { host = h }
        }

        // 1. My own recent messages: my latest per conversation ("C") and per thread ("C:TTS").
        var myLatest: [String: Double] = [:]
        func bump(_ k: String, _ t: Double) { myLatest[k] = max(myLatest[k] ?? 0, t) }
        for m in try await searchAll("from:<@\(me)> after:\(after(wideSince))") {
            note(m)
            guard let c = (m["channel"] as? [String: Any])?["id"] as? String, let tsS = m["ts"] as? String, let t = Self.ts(tsS) else { continue }
            if let tts = Self.threadParam(m["permalink"] as? String), tts != tsS {
                bump("\(c):\(tts)", t)
            } else {
                bump(c, t)
                bump("\(c):\(tsS)", t)   // a parent of mine counts as being in its thread
            }
        }

        // 2. Mentions of me or of a user group I'm in. DM mentions are covered by the DM
        //    rule; thread mentions from people join the threads. Bot posts count only in the
        //    channels the user listed, each as its own item cleared by a reply in its thread
        //    or a reaction.
        var threads: [String: (channel: String, tts: String)] = [:]
        if kinds.contains("mention") || kinds.contains("thread") {
            var queries = ["<@\(me)>"]
            queries += await groups(now: now).map { "<!subteam^\($0)>" }
            var seen = Set<String>()
            var matches: [[String: Any]] = []
            for q in queries {
                for m in try await searchAll("\(q) -from:<@\(me)> after:\(after(newSince))") {
                    let id = ((m["channel"] as? [String: Any])?["id"] as? String ?? "") + ":" + (m["ts"] as? String ?? "")
                    if seen.insert(id).inserted { matches.append(m) }
                }
            }
            for m in matches {
                note(m)
                let ch = m["channel"] as? [String: Any]
                guard let c = ch?["id"] as? String, ch?["is_im"] as? Bool != true, ch?["is_mpim"] as? Bool != true,
                      let tsS = m["ts"] as? String, let t = Self.ts(tsS) else { continue }
                let human = await fromOtherHuman(m)
                let alertChannel = botChannels.contains(Self.channelKey(ch?["name"] as? String ?? ""))
                let isAlert = !human && alertChannel && (m["user"] as? String) != me
                guard human || isAlert else { continue }
                if isAlert {
                    guard kinds.contains("mention") else { continue }
                    let key = "mention:\(c):\(tsS)"
                    handled.insert(key)
                    // My reply in the alert's own thread, or my reaction; other chatter doesn't count.
                    if try await repliedOrReacted(myLatest["\(c):\(tsS)"] != nil, c, tsS) {
                        if open[key] != nil { answered.insert(key) }
                        continue
                    }
                    var who = (m["username"] as? String) ?? ""
                    if who.isEmpty { who = await user(m["user"] as? String ?? "").name }
                    states.append(SlackItemState(key: key, title: "\(who) in #\(channelNames[c] ?? "channel"): \(await alertText(m))",
                                                 detail: "mention · #\(channelNames[c] ?? "channel")",
                                                 url: (m["permalink"] as? String).flatMap(URL.init(string:)),
                                                 waitingSince: Date(timeIntervalSince1970: t), marker: tsS))
                    continue
                }
                if let tts = Self.threadParam(m["permalink"] as? String) {
                    threads["thread:\(c):\(tts)"] = (c, tts)
                    continue
                }
                guard kinds.contains("mention") else { continue }
                let key = "mention:\(c):\(tsS)"
                handled.insert(key)
                let repliedHere = (myLatest[c] ?? 0) > t || myLatest["\(c):\(tsS)"] != nil
                if try await repliedOrReacted(repliedHere, c, tsS) {
                    if open[key] != nil { answered.insert(key) }
                    continue
                }
                let who = await user(m["user"] as? String ?? "").name
                states.append(SlackItemState(key: key, title: "\(who) in #\(channelNames[c] ?? "channel"): \(await text(m))",
                                             detail: "mention · #\(channelNames[c] ?? "channel")",
                                             url: (m["permalink"] as? String).flatMap(URL.init(string:)),
                                             waitingSince: Date(timeIntervalSince1970: t), marker: tsS))
            }
        }

        // 3. DMs and group DMs: per conversation, messages from others newer than my latest.
        if kinds.contains("dm") || kinds.contains("group") {
            var byConv: [String: [[String: Any]]] = [:]
            for m in try await searchAll("is:dm -from:<@\(me)> after:\(after(newSince))") {
                note(m)
                guard let c = (m["channel"] as? [String: Any])?["id"] as? String else { continue }
                // A reply inside a thread belongs to that thread's item, not the DM's: otherwise
                // one reply shows twice, and answering in the thread leaves the DM item behind.
                if let tts = Self.threadParam(m["permalink"] as? String), tts != (m["ts"] as? String) {
                    threads["thread:\(c):\(tts)"] = (c, tts)
                    continue
                }
                byConv[c, default: []].append(m)
            }
            for (c, msgs) in byConv {
                let group = (msgs.first?["channel"] as? [String: Any])?["is_mpim"] as? Bool == true
                let kind = group ? "group" : "dm"
                guard kinds.contains(kind) else { continue }
                let key = "\(kind):\(c)"
                handled.insert(key)
                let mine = myLatest[c] ?? 0
                var waiting: [[String: Any]] = []
                for m in msgs where (Self.ts(m["ts"]) ?? 0) > mine {
                    if await fromOtherHuman(m) { waiting.append(m) }
                }
                waiting.sort { (Self.ts($0["ts"]) ?? 0) < (Self.ts($1["ts"]) ?? 0) }
                guard let first = waiting.first, let newest = waiting.last, let newestTs = newest["ts"] as? String else {
                    if open[key] != nil { answered.insert(key) }
                    continue
                }
                if reactedByMe(await message(c, newestTs)) {
                    if open[key] != nil { answered.insert(key) }
                    continue
                }
                let who = await user(newest["user"] as? String ?? "").name
                states.append(SlackItemState(key: key, title: "\(who): \(await text(newest))",
                                             detail: group ? "group DM" : "DM",
                                             url: (newest["permalink"] as? String).flatMap(URL.init(string:)),
                                             waitingSince: Date(timeIntervalSince1970: Self.ts(first["ts"]) ?? now.timeIntervalSince1970),
                                             marker: newestTs))
            }
        }

        // 4. Threads I'm in (plus thread mentions and threads already in the queue).
        if kinds.contains("thread") {
            for m in try await searchAll("from:<@\(me)> is:thread after:\(after(wideSince))") {
                note(m)
                guard let c = (m["channel"] as? [String: Any])?["id"] as? String, let tsS = m["ts"] as? String else { continue }
                let tts = Self.threadParam(m["permalink"] as? String) ?? tsS
                threads["thread:\(c):\(tts)"] = (c, tts)
            }
            for key in open.keys where key.hasPrefix("thread:") {
                let p = key.split(separator: ":").map(String.init)
                if p.count == 3 { threads[key] = (p[1], p[2]) }
            }
            for (key, th) in threads.prefix(25) {
                handled.insert(key)
                let r: [String: Any]
                do { r = try await call("conversations.replies", ["channel": th.channel, "ts": th.tts, "limit": "200"]) }
                catch let e as SlackError where e.code == "thread_not_found" || e.code == "channel_not_found" {
                    if open[key] != nil { answered.insert(key) }   // gone: stop waiting on it
                    continue
                }
                let msgs = (r["messages"] as? [[String: Any]]) ?? []
                let myLast = msgs.filter { ($0["user"] as? String) == me }.compactMap { Self.ts($0["ts"]) }.max() ?? 0
                var waiting: [[String: Any]] = []
                for m in msgs where (Self.ts(m["ts"]) ?? 0) > myLast {
                    if await fromOtherHuman(m) { waiting.append(m) }
                }
                guard let first = waiting.first, let newest = waiting.last, let newestTs = newest["ts"] as? String,
                      !reactedByMe(newest) else {
                    if open[key] != nil { answered.insert(key) }
                    continue
                }
                // Group DMs have internal names like "mpdm-ann--bob-1"; show them as a group DM.
                let chan = channelNames[th.channel].map { $0.hasPrefix("mpdm-") ? "group DM" : "#\($0)" } ?? "a thread"
                let who = await user(newest["user"] as? String ?? "").name
                let link = "https://\(host)/archives/\(th.channel)/p\(newestTs.replacingOccurrences(of: ".", with: ""))?thread_ts=\(th.tts)&cid=\(th.channel)"
                states.append(SlackItemState(key: key, title: "\(who) in \(chan): \(await text(newest))",
                                             detail: "thread · \(chan)", url: URL(string: link),
                                             waitingSince: Date(timeIntervalSince1970: Self.ts(first["ts"]) ?? now.timeIntervalSince1970),
                                             marker: newestTs))
            }
        }

        // 5. Items already in the queue that search didn't return: answered if I've posted
        //    there since, or reacted to the newest message. Otherwise they stay.
        for (key, marker) in open where !handled.contains(key) {
            let p = key.split(separator: ":").map(String.init)
            guard p.count >= 2, let t = Double(marker) else { continue }
            let c = p[1]
            switch p[0] {
            case "dm", "group":
                if try await repliedOrReacted((myLatest[c] ?? 0) > t, c, marker) { answered.insert(key) }
            case "mention" where p.count == 3:
                if try await repliedOrReacted((myLatest[c] ?? 0) > t || myLatest["\(c):\(p[2])"] != nil, c, p[2]) {
                    answered.insert(key)
                }
            default: break
            }
        }
        return SlackSyncResult(states: states, answered: answered)
    }
}

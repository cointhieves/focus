import Foundation
import FocusCore

// `focus` CLI. Writes the same SQLite database the Focus app reads, so changes
// appear in the panel within about a second. Designed to be easy for an LLM
// agent to drive: plain subcommands, `--json` output, non-zero exit on error.

let usage = """
usage: focus <command> [args]

  add <text...>       add a task; "... by 5pm", "by Friday 3pm" or
                      "in 30 minutes" in the text sets a deadline
      --by <time>     set the deadline explicitly instead
  list [--json]       show the queue in order (--json for scripts and agents)
  skip <id>           send an item to the back of the line
  done <id>           finish a task: deletes it
  snooze <id> [dur]   boomerang: to the bottom, back after dur business hours
                      (2h, 30m, tomorrow; default from Settings), or sooner
                      if something new happens
  unsnooze <id>       bring a snoozed item back now
  dismiss <id>        hide a Jira/Slack item until something new happens;
                      on a "removed" ticket, clears it
  version             print version

Ids are the numbers shown by `focus list`.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("focus: \(message)\n".utf8))
    exit(1)
}

func parseId(_ args: ArraySlice<String>) -> Int64 {
    guard let raw = args.first, let id = Int64(raw) else { fail("expected a numeric id\n\n\(usage)") }
    return id
}

/// Short, stable label for an item's color band, used in both text and JSON output.
func bandName(_ band: AgeScale.Band) -> String {
    switch band {
    case .none: "task"
    case .green: "green"
    case .ramp: "amber"
    case .red: "red"
    case .due: "due"
    }
}

func list(_ store: Store, json: Bool) throws {
    let items = try store.queue()
    let scale = try store.loadSettings().ageScale
    let now = Date()

    if json {
        let rows: [[String: Any]] = items.enumerated().map { position, item in
            var row: [String: Any] = [
                "position": position + 1,
                "id": item.id,
                "source": item.source == .idea ? "task" : item.source.rawValue,
                "title": item.title,
                "detail": item.detail,
                "band": item.snoozedUntil != nil ? "snoozed" : item.removed ? "removed" : bandName(scale.band(for: item, now: now)),
            ]
            if let until = item.snoozedUntil { row["snoozed_until"] = ISO8601DateFormatter().string(from: until) }
            if item.removed { row["removed"] = true }
            row["url"] = item.url?.absoluteString
            row["external_id"] = item.externalId
            if let hours = scale.hours(for: item, now: now) {
                row[item.source == .slack ? "business_hours_waiting" : "weekday_hours_since_response"] = Int(hours)
            }
            if item.source != .idea { row["when"] = AgeLabel.text(for: item, scale: scale, now: now) }
            if let due = item.dueAt {
                row["due_at"] = ISO8601DateFormatter().string(from: due)
                row["due_in_minutes"] = Int(due.timeIntervalSince(now) / 60)
            }
            return row
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        return
    }

    if items.isEmpty { print("Queue is empty."); return }
    // Color the band only when writing to a terminal, so piped output stays clean.
    let tty = isatty(STDOUT_FILENO) != 0
    for (position, item) in items.enumerated() {
        let band = item.snoozedUntil != nil ? "snoozed" : item.removed ? "removed" : bandName(scale.band(for: item, now: now))
        let age = item.snoozedUntil != nil ? AgeLabel.text(for: item, scale: scale, now: now) : item.dueAt.map { "due " + Deadline.countdown(to: $0, now: now) }
            ?? (item.source == .idea ? "-" : AgeLabel.text(for: item, scale: scale, now: now))
        let label = tty ? colored(band) : band
        print("\(position + 1). [\(item.id)] \(label)  \(item.source == .idea ? "task" : item.source.rawValue)  \(age)  \(item.title)")
    }
}

func colored(_ band: String) -> String {
    let code: String
    switch band {
    case "removed", "snoozed": code = "90"   // grey: left your sprint, clear with dismiss
    case "red": code = "31"
    case "due": code = "35"   // magenta: on the clock
    case "amber": code = "33"
    case "green": code = "32"
    default: code = "34"   // tasks: blue, matching the panel
    }
    return "\u{1B}[\(code)m\(band)\u{1B}[0m"
}

let args = CommandLine.arguments.dropFirst()
guard let command = args.first else { print(usage); exit(0) }
let rest = args.dropFirst()

do {
    switch command {
    case "version", "--version", "-v":
        print("focus \(Focus.version) (sqlite \(Focus.sqliteVersion))")
    case "help", "--help", "-h":
        print(usage)
    case "add":
        var words = Array(rest)
        var due: Date?
        if let flag = words.firstIndex(of: "--by") {
            let phrase = words[(flag + 1)...].joined(separator: " ")
            words = Array(words[..<flag])
            // Reuse the text parser so --by accepts the same phrases ("5pm", "Friday 3pm", "in 30 minutes").
            let probe = phrase.lowercased().hasPrefix("in ") ? "x \(phrase)" : "x by \(phrase)"
            guard let parsed = Deadline.parse(probe).due else { fail("could not understand time '\(phrase)'") }
            due = parsed
        }
        let text = words.joined(separator: " ")
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { fail("add needs some text") }
        let item = try Store().addIdea(text, due: due)
        if let d = item.dueAt {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
            print("Added [\(item.id)] \(item.title), due \(f.string(from: d)) (\(Deadline.countdown(to: d)))")
        } else {
            print("Added [\(item.id)] \(item.title)")
        }
    case "list", "ls":
        try list(Store(), json: rest.contains("--json"))
    case "skip":
        try Store().skip(parseId(rest))
        print("Skipped \(parseId(rest)) to the back")
    case "done":
        try Store().deleteIdea(parseId(rest))
        print("Done: deleted \(parseId(rest))")
    case "snooze":
        let store = try Store()
        let id = parseId(rest)
        let s = try store.loadSettings()
        let now = Date()
        var until: Date
        switch rest.dropFirst().first?.lowercased() {
        case nil:
            until = BusinessClock.date(businessHours: s.snoozeHours, after: now, startHour: s.workStartHour, endHour: s.workEndHour)
        case "tomorrow"?:
            // Start of the next working day.
            let cal = Calendar.current
            var day = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
            while cal.isDateInWeekend(day) { day = cal.date(byAdding: .day, value: 1, to: day)! }
            until = day.addingTimeInterval(s.workStartHour * 3600)
        case let d?:
            let unit = d.last
            guard let n = Double(d.dropLast()), n > 0, unit == "h" || unit == "m" else {
                fail("duration must look like 2h, 30m or tomorrow")
            }
            until = BusinessClock.date(businessHours: unit == "h" ? n : n / 60, after: now,
                                       startHour: s.workStartHour, endHour: s.workEndHour)
        }
        try store.snooze(id, until: until)
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        print("Snoozed \(id) until \(f.string(from: until))")
    case "unsnooze":
        try Store().unsnooze(parseId(rest))
        print("Brought back \(parseId(rest))")
    case "dismiss":
        let store = try Store()
        let wasRemoved = try store.item(parseId(rest)).removed
        try store.dismiss(parseId(rest))
        print(wasRemoved ? "Cleared \(parseId(rest))" : "Dismissed \(parseId(rest))")
    default:
        fail("unknown command '\(command)'\n\n\(usage)")
    }
} catch {
    fail(String(describing: error))
}

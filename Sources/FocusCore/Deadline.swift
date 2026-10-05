import Foundation

/// One-shot deadlines on ideas: parsing "by 5pm" style text, and the warning schedule.
public enum Deadline {
    /// Warning level reached at `now`: 0 = none yet, 1 = 10% of the window left,
    /// 2 = 5% left, 3 = due (overdue). Pure percentages, so short tasks still get
    /// both warnings before the due time.
    public static func level(created: Date, due: Date, now: Date) -> Int {
        let window = due.timeIntervalSince(created)
        let remaining = due.timeIntervalSince(now)
        if remaining <= 0 { return 3 }
        if remaining <= window * 0.05 { return 2 }
        if remaining <= window * 0.10 { return 1 }
        return 0
    }

    /// Fraction of the window remaining, clamped to 0...1.
    public static func remainingFraction(created: Date, due: Date, now: Date) -> Double {
        let window = due.timeIntervalSince(created)
        guard window > 0 else { return 0 }
        return min(1, max(0, due.timeIntervalSince(now) / window))
    }

    /// Splits "take out the trash by 5pm" into ("take out the trash", 17:00 today).
    /// Understands "in 30 minutes", "by <date>", and a date at the END of the text after
    /// "on"/"at" or starting with today/tomorrow/a weekday ("call Sam tomorrow at 10am",
    /// "check in on wednesday"). A date with no time means the end of the workday
    /// (`endOfDayHour`). Returns the original text and nil when no deadline is found.
    public static func parse(_ text: String, now: Date = Date(), endOfDayHour: Double = 17,
                             calendar: Calendar = .current) -> (title: String, due: Date?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // "in 30 minutes" / "in 2 hours": the system date detector does not handle these.
        let relative = try! NSRegularExpression(
            pattern: #"\s*\bin\s+(\d+)\s*(m|min|mins|minute|minutes|h|hr|hrs|hour|hours)\b"#,
            options: .caseInsensitive)
        let ns = trimmed as NSString
        if let m = relative.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)),
           let amount = Double(ns.substring(with: m.range(at: 1))) {
            let unit = ns.substring(with: m.range(at: 2)).lowercased()
            let seconds = unit.hasPrefix("h") ? amount * 3600 : amount * 60
            return (clean(ns.replacingCharacters(in: m.range, with: "")), now.addingTimeInterval(seconds))
        }

        // "by <date>" anywhere: the date must directly follow "by".
        if let byRange = trimmed.range(of: #"\bby\s+"#, options: [.regularExpression, .caseInsensitive, .backwards]),
           let r = detect(String(trimmed[byRange.upperBound...]), mustReachEnd: false, now: now,
                          endOfDayHour: endOfDayHour, calendar: calendar) {
            return (clean(String(trimmed[..<byRange.lowerBound]) + " " + r.leftover), r.due)
        }

        // A date at the end of the text, introduced by "on"/"at", or starting with
        // today/tomorrow/a weekday. Not after from/since/last/about/of, so "notes from
        // Monday" stays plain text. The earliest start that reads as a date wins.
        let trigger = try! NSRegularExpression(
            pattern: #"\b(?:(on|at)\s+|(?=(today|tonight|tomorrow|mon|monday|tue|tues|tuesday|wed|weds|wednesday|thu|thur|thurs|thursday|fri|friday|sat|saturday|sun|sunday)\b))"#,
            options: .caseInsensitive)
        let blocked: Set<String> = ["from", "since", "last", "about", "of"]
        for m in trigger.matches(in: trimmed, range: NSRange(location: 0, length: ns.length)) {
            let before = ns.substring(to: m.range.location).split(whereSeparator: \.isWhitespace).last.map { $0.lowercased() }
            if m.range(at: 2).location != NSNotFound, let w = before, blocked.contains(w) { continue }
            let tail = ns.substring(from: m.range.location + m.range.length)
            guard let r = detect(tail, mustReachEnd: true, now: now, endOfDayHour: endOfDayHour, calendar: calendar)
            else { continue }
            return (clean(ns.substring(to: m.range.location)), r.due)
        }
        return (trimmed, nil)
    }

    /// Reads a date at the very start of `tail`. With `mustReachEnd`, the date must also run
    /// to the end (trailing punctuation allowed). A date with no time gets `endOfDayHour`.
    private static func detect(_ raw: String, mustReachEnd: Bool, now: Date, endOfDayHour: Double,
                               calendar: Calendar) -> (due: Date, leftover: String)? {
        // The detector does not understand "noon".
        let tail = raw.replacingOccurrences(of: "noon", with: "12pm", options: .caseInsensitive)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)),
              match.range.location == 0, var due = match.date else { return nil }
        let t = tail as NSString
        let rest = t.substring(from: match.range.location + match.range.length)
        if mustReachEnd, !rest.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty {
            return nil
        }
        let phrase = t.substring(with: match.range)
        let hasTime = phrase.range(of: #"\d\s*(am|pm|a\.m\.|p\.m\.)|\d:\d|\bat\s+\d"#,
                                   options: [.regularExpression, .caseInsensitive]) != nil
        if hasTime {
            // "by 11am" typed at 1pm means tomorrow at 11.
            if due <= now, now.timeIntervalSince(due) < 24 * 3600,
               let next = calendar.date(byAdding: .day, value: 1, to: due) { due = next }
        } else {
            due = calendar.startOfDay(for: due).addingTimeInterval(endOfDayHour * 3600)
            // "on monday" typed on a Monday after close: next week.
            let isWeekday = phrase.range(of: #"^(mon|tue|wed|thu|fri|sat|sun)"#, options: [.regularExpression, .caseInsensitive]) != nil
            if due <= now, isWeekday, let next = calendar.date(byAdding: .day, value: 7, to: due) { due = next }
        }
        return (due, rest)
    }

    /// Short countdown label: "in 42m", "in 3h 5m", "overdue 10m".
    public static func countdown(to due: Date, now: Date = Date()) -> String {
        let seconds = due.timeIntervalSince(now)
        let minutes = Int((abs(seconds) / 60).rounded(.up))
        let text = minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
        return seconds >= 0 ? "in \(text)" : "overdue \(text)"
    }

    private static func clean(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

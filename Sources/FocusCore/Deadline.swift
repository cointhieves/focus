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
    /// Returns the original text and nil when no deadline is found.
    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> (title: String, due: Date?) {
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

        // "by <date>": only dates after the word "by" count, so text like
        // "notes from Monday" does not accidentally become a deadline.
        guard let byRange = trimmed.range(of: #"\bby\s+"#, options: [.regularExpression, .caseInsensitive, .backwards])
        else { return (trimmed, nil) }
        let head = String(trimmed[..<byRange.lowerBound])
        var tail = String(trimmed[byRange.upperBound...])
        // The detector does not understand "noon".
        tail = tail.replacingOccurrences(of: "noon", with: "12pm", options: .caseInsensitive)

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)),
              match.range.location == 0,                 // the date must directly follow "by"
              var due = match.date
        else { return (trimmed, nil) }

        // "by 11am" typed at 1pm means tomorrow at 11.
        if due <= now, now.timeIntervalSince(due) < 24 * 3600,
           let next = calendar.date(byAdding: .day, value: 1, to: due) {
            due = next
        }
        let leftover = (tail as NSString).replacingCharacters(in: match.range, with: "")
        return (clean(head + " " + leftover), due)
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

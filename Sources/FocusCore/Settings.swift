import Foundation

/// User-tunable settings. Stored in the shared database so the app and CLI agree.
public struct FocusSettings: Equatable, Sendable {
    /// Panel opacity while faded (text and background; color strips stay full strength).
    public var idleOpacity: Double = 0.2
    /// How long the panel stays awake after the mouse leaves it.
    public var fadeDelaySeconds: Double = 5
    /// How long a popped/added row stays lit.
    public var highlightSeconds: Double = 7
    /// Jira: business hours since my last comment before a ticket starts turning (1 day).
    public var greenUntilHours: Double = 8
    /// Jira: business hours since my last comment at which a ticket is fully red (2 days).
    public var redAtHours: Double = 16
    /// Multiplier on the panel's text size.
    public var textScale: Double = 1.0
    /// Slack: business hours before an unanswered message starts turning, and when it's red.
    public var slackGreenHours: Double = 1
    public var slackRedHours: Double = 2
    /// Business hours (local time, Mon-Fri) that the Slack clock counts.
    public var workStartHour: Double = 9
    public var workEndHour: Double = 17
    /// Boomerang: business hours an item stays at the bottom before it pops back.
    public var snoozeHours: Double = 2
    /// After opening an item, the panel hides for up to this many minutes (0 = don't hide).
    public var hideAfterOpenMinutes: Double = 5
    /// Show only who/where for Slack items, not the message text (for screen sharing).
    public var hideMessageText = false

    public init() {}

    public var ageScale: AgeScale {
        AgeScale(greenUntilHours: greenUntilHours, redAtHours: redAtHours,
                 slackGreenHours: slackGreenHours, slackRedHours: slackRedHours,
                 workStartHour: workStartHour, workEndHour: workEndHour)
    }

    /// Returns a copy with every value forced into its valid range.
    public func clamped() -> FocusSettings {
        var s = self
        s.idleOpacity = min(max(s.idleOpacity, 0.05), 1)
        s.fadeDelaySeconds = min(max(s.fadeDelaySeconds, 1), 60)
        s.highlightSeconds = min(max(s.highlightSeconds, 1), 60)
        s.greenUntilHours = min(max(s.greenUntilHours, 1), 80)
        s.redAtHours = min(max(s.redAtHours, s.greenUntilHours + 1), 160)
        s.textScale = min(max(s.textScale, 0.8), 1.6)
        s.slackGreenHours = min(max(s.slackGreenHours, 0.25), 40)
        s.slackRedHours = min(max(s.slackRedHours, s.slackGreenHours + 0.25), 80)
        s.workStartHour = min(max(s.workStartHour, 0), 23)
        s.workEndHour = min(max(s.workEndHour, s.workStartHour + 1), 24)
        s.snoozeHours = min(max(s.snoozeHours, 0.25), 40)
        s.hideAfterOpenMinutes = min(max(s.hideAfterOpenMinutes, 0), 60)
        return s
    }

    /// Stable storage keys. Adding a field means adding it here and in `apply`.
    var asPairs: [(String, Double)] {
        [("idle_opacity", idleOpacity), ("fade_delay_seconds", fadeDelaySeconds),
         ("highlight_seconds", highlightSeconds), ("green_until_hours", greenUntilHours),
         ("red_at_hours", redAtHours), ("text_scale", textScale),
         ("slack_green_hours", slackGreenHours), ("slack_red_hours", slackRedHours),
         ("work_start_hour", workStartHour), ("work_end_hour", workEndHour), ("snooze_hours", snoozeHours),
         ("hide_after_open_minutes", hideAfterOpenMinutes), ("hide_message_text", hideMessageText ? 1 : 0)]
    }

    mutating func apply(key: String, value: Double) {
        switch key {
        case "idle_opacity": idleOpacity = value
        case "fade_delay_seconds": fadeDelaySeconds = value
        case "highlight_seconds": highlightSeconds = value
        case "green_until_hours": greenUntilHours = value
        case "red_at_hours": redAtHours = value
        case "text_scale": textScale = value
        case "slack_green_hours": slackGreenHours = value
        case "slack_red_hours": slackRedHours = value
        case "work_start_hour": workStartHour = value
        case "work_end_hour": workEndHour = value
        case "snooze_hours": snoozeHours = value
        case "hide_after_open_minutes": hideAfterOpenMinutes = value
        case "hide_message_text": hideMessageText = value != 0
        default: break   // unknown keys from a newer version are ignored
        }
    }
}

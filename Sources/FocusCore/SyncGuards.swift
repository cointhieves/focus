import Foundation

/// Decisions the app makes around a sync, kept here (not in the app target) so they can be
/// tested. Each one exists because of a real incident.
public enum SyncGuards {
    /// One Jira sync came back with zero sprint tickets while some were showing, and every
    /// row went REMOVED until the next sync restored them. An empty answer is acted on only
    /// when the following sync agrees. Returns (hold this result?, new counter).
    public static func holdEmptySprint(scopeIsEmpty: Bool, items: [Item], emptyBefore: Int) -> (hold: Bool, empty: Int) {
        let showing = items.contains { $0.source == .jira && Store.mentionKey($0.externalId ?? "") == nil
                                       && $0.externalId?.contains("DEMO-") != true && !$0.removed }
        if scopeIsEmpty && showing && emptyBefore == 0 { return (true, 1) }
        return (false, 0)
    }

    /// Saved display names for "Ignore comments from" must go when the person is removed
    /// (a removed person's name was once left behind).
    public static func prunedNames(_ names: [String: String], keeping ids: [String]) -> [String: String] {
        names.filter { ids.contains($0.key) }
    }

    /// What a HIDDEN panel does when something lights up. `needsYou` is true for a new
    /// message, reply, mention, deadline or returning boomerang; false for a farewell only
    /// (CLOSED, RESPONDED, REMOVED). Things that need you always win.
    public enum HiddenAction: Equatable { case stayHidden, showAndStay, showThenHide }
    public static func hiddenPanelAction(needsYou: Bool, setting: WhileHidden) -> HiddenAction {
        switch setting {
        case .never: return .stayHidden
        case .stay: return .showAndStay
        case .farewellsHide: return needsYou ? .showAndStay : .showThenHide
        }
    }
}

import Foundation

/// A normalized sporting event produced by a `SportAdapter` from a raw upstream feed.
/// The adapter turns league-specific JSON into this shape and produces the compact
/// `displayString` shown in the menu bar.
struct SportEvent: Identifiable {
    enum State {
        case pre(startDate: Date?)
        case live
        case final
    }

    let id: String
    /// The league this event belongs to — drives the menu-bar/dropdown icon.
    let league: LeagueID
    let state: State
    /// Compact, menu-bar-ready string, e.g. `NY 102  SA 98 · 4:32 Q4`.
    let displayString: String
    /// Whether the user's favorites are involved (drives ranking).
    let isFavorite: Bool
    /// Higher sorts first. Convention: live-favorite > live > pre-favorite > pre > final.
    let sortPriority: Int
}

extension SportEvent {
    /// Convenience flags over `state`.
    var isLive: Bool { if case .live = state { return true } else { return false } }
    var isFinal: Bool { if case .final = state { return true } else { return false } }
}

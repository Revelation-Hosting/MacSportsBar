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
    /// Scheduled start time (the feed's UTC date), for the ±24h favorites window and for
    /// labeling recent/upcoming games. Defaulted so adapters opt in.
    var date: Date? = nil
    /// Current period/quarter/inning number, when the sport has one. Used to detect boundary
    /// transitions (a new period/inning) for notifications. Defaulted so adapters opt in.
    var period: Int? = nil
    /// Team logo URLs for the matchup, for the optional menu-bar team-logos display. Set by
    /// head-to-head adapters for live games; nil for individual sports (golf/racing).
    var awayLogo: URL? = nil
    var homeLogo: URL? = nil
    /// Per-team breakdown for the menu-bar team-logos layout (head-to-head live games).
    var matchup: Matchup? = nil

    /// Away/home abbreviations + scores and the live detail, so the menu bar can lay out the
    /// logos and scores individually, e.g. `[logo] NY 39 - 42 SA [logo] · 7:01 Q2`.
    struct Matchup {
        let away: String
        let awayScore: String
        let home: String
        let homeScore: String
        let detail: String
    }
}

extension SportEvent {
    /// Convenience flags over `state`.
    var isLive: Bool { if case .live = state { return true } else { return false } }
    var isFinal: Bool { if case .final = state { return true } else { return false } }
}

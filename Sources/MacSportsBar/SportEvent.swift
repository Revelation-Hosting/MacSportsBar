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
    /// State/string/priority are `var` so a richer source can revise a decoded event in place —
    /// e.g. NASCAR's live feed upgrading ESPN's stale "In Progress" to live lap/flag telemetry.
    var state: State
    /// Compact, menu-bar-ready string, e.g. `NY 102  SA 98 · 4:32 Q4`.
    var displayString: String
    /// Whether the user's favorites are involved (drives ranking). Mutable so the model can
    /// promote events from a followed series (golf/NASCAR) after the adapter has decoded them.
    var isFavorite: Bool
    /// Higher sorts first. Convention: live-favorite > live > pre-favorite > pre > final.
    var sortPriority: Int
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
    /// Current racing flag (NASCAR live feed), which drives a colored flag glyph in the menu
    /// bar instead of the league glyph. Nil for non-racing events. Defaulted so adapters opt in.
    var flag: RaceFlag? = nil
    /// A shorter readout used when the full `displayString` won't fit the menu-bar width — it
    /// drops the least-important leading context (e.g. the race/track name, which the flag glyph
    /// already implies) rather than hard-clipping the important tail. Nil = no compact form.
    var menuShort: String? = nil
    /// Accent color for the league glyph as an `RRGGBB` hex string (no leading `#`) — Formula 1
    /// uses the leading/winning driver's constructor colour, so the glyph reads as the team.
    /// Nil = tint with the menu-bar text color like every other sport.
    var accentHex: String? = nil

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

/// A racing flag state, mapped from the NASCAR live feed's `flag_state` integer per the
/// official spec (https://feed.nascar.com/swagger): 1-Green, 2-Yellow, 3-Red, 4-Finish,
/// 6-Stop, 8-Warm Up, 9-Not Active. Drives the menu-bar flag glyph + color.
enum RaceFlag {
    case green            // 1 — racing under green
    case caution          // 2 — yellow / caution
    case safetyCar        // physical safety car on track (F1)
    case virtualSafetyCar // VSC — the field is speed-limited but the car stays in the pits (F1)
    case red              // 3 Red, 6 Stop — session stopped on track
    case checkered        // 4 — Finish
    case warmup           // 8 — pace / formation laps before green

    /// Map the feed's `flag_state`; returns nil for 9-Not Active or anything unknown (no flag).
    init?(flagState: Int?) {
        switch flagState {
        case 1: self = .green
        case 2: self = .caution
        case 3, 6: self = .red
        case 4: self = .checkered
        case 8: self = .warmup
        default: return nil   // 9-Not Active / absent / unknown
        }
    }

    /// Map Formula 1's `TrackStatus.Status` (F1 live timing sends it as a numeric *string*).
    /// F1 distinguishes a physical safety car from a virtual one, which NASCAR's feed does not.
    /// Returns nil for anything unrecognized, so the caller falls back to no flag.
    init?(trackStatus: String?) {
        switch trackStatus {
        case "1": self = .green            // AllClear
        case "2": self = .caution          // Yellow
        case "4": self = .safetyCar        // SCDeployed
        case "5": self = .red              // Red
        case "6", "7": self = .virtualSafetyCar  // VSCDeployed / VSCEnding
        default: return nil
        }
    }

    /// Short label for the menu bar, or nil when the flag needs no words (green racing).
    var shortLabel: String? {
        switch self {
        case .green: return nil
        case .caution: return "Yellow"
        case .safetyCar: return "SC"
        case .virtualSafetyCar: return "VSC"
        case .red: return "RED"
        case .checkered: return nil
        case .warmup: return "Pace"
        }
    }
}

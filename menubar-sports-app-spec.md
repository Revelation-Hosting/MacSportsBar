# MenuBar Sports — Build Spec (MVP)

A macOS menu bar app that displays live scores for a fixed set of sports as compact
text in the system menu bar, with a click-through settings window for configuration.
No dock icon, no main window. Built for personal use first; distribution is a
later concern.

---

## 1. Goal & shape

- A single `NSStatusItem` (via SwiftUI `MenuBarExtra`) shows a short live-score string
  in the menu bar, updating on a polling interval.
- Clicking the item opens a small popover/menu; a "Settings…" action opens a full
  settings window for configuration (favorite teams, which sports are enabled,
  refresh cadence, display strategy).
- The displayed string is intentionally short to survive menu-bar width limits and
  notch crowding on MacBooks. Target ~20–30 characters per active event.

**Non-goals (explicitly out of scope for MVP):** play-by-play, notifications on score
change, historical data, standings, betting lines, multi-window dashboards, any sport
not listed in §5.

---

## 2. Platform & tech

- **Language/UI:** Swift + SwiftUI, `MenuBarExtra` scene (macOS 13+). Target the
  developer's current macOS (Tahoe 26) but keep deployment target at 14.0 to be safe.
- **Agent app:** set `LSUIElement` / "Application is agent (UIElement)" = YES in
  Info.plist so there is no dock icon and no default window.
- **Networking:** `URLSession` async/await. No third-party networking deps.
- **JSON:** `Codable`. One decoder per adapter; do not share a giant monolithic model.
- **Persistence:** `UserDefaults` via `@AppStorage` for settings. No database.
- **No secrets:** all data sources used here are keyless (see §4). Nothing to store.

---

## 3. Architecture

A shared protocol with one adapter per data shape. There are **four adapters** but
**two underlying shapes** (head-to-head vs. field/leaderboard).

```
SportAdapter (protocol)
  - var league: LeagueID
  - func fetch() async throws -> [SportEvent]
  - func format(_ event: SportEvent) -> String   // the menu-bar string

SportEvent (model)
  - id: String
  - state: .pre(startDate:) | .live | .final
  - displayString: String        // produced by the adapter's format()
  - isFavorite: Bool             // matched against user's favorite teams/drivers
  - sortPriority: Int            // live > favorite > soon > final
```

Adapters:

| Adapter      | Shape           | Leagues served                    |
|--------------|-----------------|-----------------------------------|
| Basketball   | head-to-head    | NBA, NCAA Men's (two league slugs)|
| Baseball     | head-to-head    | MLB                               |
| Golf         | leaderboard     | PGA                               |
| Racing       | field           | NASCAR Cup (`nascar-premier`)     |

Keep each adapter's fetch+decode+format isolated so a breaking upstream change is a
localized fix. Put the raw HTTP fetch behind a thin `ESPNClient` so caching, timeouts,
and a future base-URL swap (e.g. self-hosted proxy) happen in one place.

---

## 4. Data source

**Primary: ESPN's undocumented JSON API.** Keyless, no auth, returns JSON to a plain
GET. Base: `https://site.api.espn.com/apis/site/v2/sports/{sport}/{league}/scoreboard`.

> ⚠️ **Reliability caveat — design around this.** These endpoints are reverse-engineered
> and unofficial. ESPN can change field shapes or remove endpoints without notice.
> Every adapter MUST: (a) decode defensively (optional fields, never force-unwrap),
> (b) degrade to "no data" rather than crash, (c) isolate decoding so one sport breaking
> doesn't take down the others.

### Confirmed-working endpoints (verified live against 2026 season data)

| Sport            | Endpoint                                                                              |
|------------------|---------------------------------------------------------------------------------------|
| NBA              | `.../sports/basketball/nba/scoreboard`                                                 |
| NCAA Men's BB    | `.../sports/basketball/mens-college-basketball/scoreboard`                             |
| MLB              | `.../sports/baseball/mlb/scoreboard`                                                    |
| NASCAR Cup       | `.../sports/racing/nascar-premier/scoreboard`                                           |

### Needs verification at build time

| Sport | Likely endpoint                                  | Note                                                        |
|-------|--------------------------------------------------|-------------------------------------------------------------|
| PGA   | `.../sports/golf/pga/scoreboard` or `/leaderboard` | Confirm slug and which path returns live leaderboard data. |

### Important structural note (racing especially)

The `scoreboard` **root** returns the season *calendar* plus, when events are live, an
`events[]` array. Deep live telemetry — for racing this means **current lap, total lap
count, stage, and current leader** — lives in the **event-detail** endpoint referenced by
each event's `$ref`, under `sports.core.api.espn.com/v2/sports/racing/leagues/nascar-premier/events/{id}/...`.

> The lap/stage/leader fields were **not** verifiable against a live race during spec
> authoring (no Cup race was green-flag). **First racing task at build time: fetch a live
> Cup event-detail payload and confirm the exact field paths before finalizing the racing
> format string.** If the fields aren't reliably present, racing degrades to
> "event name + leader" or "next race + start time."

---

## 5. Per-sport display spec

Each adapter produces ONE short string per event. Examples assume a favorite is involved.

### Basketball (NBA + NCAA Men's)
Same adapter, swap league slug. Fields from each competitor: `score`; game `displayClock`
and `period`; status type for pre/in/final.
- **Period label differs by league:** NBA → quarters (Q1–Q4, then OT). NCAA → halves (1H/2H, then OT).
- **Live format:** `GONZ 72  UCLA 68 · 4:32 2H`
- **Final format:** `GONZ 81  UCLA 77 · Final`
- **Pre format:** `GONZ vs UCLA · 7:00p`

### MLB (head-to-head + base/out state)
Fields: each side's `score`; inning number + half (top/bottom); and the situation object
(`balls`, `strikes`, `outs`, and runners `onFirst`/`onSecond`/`onThird`). ESPN's status
detail often pre-formats "Top 5th" / "Bot 7th" — prefer it if present, else assemble from
inning + half.
- **Bases:** render as a compact diamond glyph or a 3-bit indicator, e.g. `[1_3]` for
  runners on first and third, `[___]` for empty. Pick whichever reads cleanly at menu-bar size.
- **Live format:** `SEA 3  TEX 2 · Bot 7th · 2 out · [1_3]`
- If width is tight, drop bases first, then outs, keeping score + inning as the floor.
- **Final format:** `SEA 5  TEX 2 · Final`

### PGA golf (leaderboard, intermittent)
Fields: event/tournament name; leader name + score-to-par; leader's current hole (`thru`).
Live only a few days a month — most days this shows next event or nothing.
- **Live format:** `Genesis Inv · Scheffler −12 thru 14`
- **Between rounds / pre:** `Genesis Inv · Round 2 · 7:10a`

### NASCAR Cup (field, pending live-field verification — see §4)
Target fields: current lap / total laps; current stage; current leader (driver name or #).
- **Live format (target):** `Coca-Cola 600 · L245/400 · St3 · #5 Larson`
- **Degraded format (if telemetry fields unreliable):** `Coca-Cola 600 · Larson leading`
- **Pre format:** `Michigan · Cup · Sun 2:00p`

---

## 6. Display strategy (decide before coding the model)

The menu bar shows limited width and hides items behind the notch when crowded. So the app
must choose WHAT to show when multiple things are relevant. MVP approach:

1. Build a ranked list of relevant events across enabled sports:
   live-and-favorite > live > favorite-starting-soon > final-today.
2. Show the single top-ranked event by default.
3. If more than one live favorite event exists, **cycle** through them on a timer
   (e.g. rotate every 8s), or let the user pin a "primary sport" in settings. Implement
   cycling for MVP; pinning is a nice-to-have.
4. Hard-truncate the string to a configurable max length; never let it grow tall.

---

## 7. Polling policy

Be a good citizen of an unofficial API. Adaptive cadence:

- **No relevant live events:** poll slowly — every 5–10 min — just to catch state changes
  (game starting, race going green).
- **A relevant event is live:** poll every 20–30s. Tighten to ~10s only for a live favorite.
- **Golf/NASCAR live:** same live cadence; these are sparse so most of the time they sit
  in the slow tier.
- Cache final results with a long TTL (they don't change). Cache in-progress briefly.
- Stagger adapter polls so they don't all fire on the same tick.

---

## 8. Settings window

Opened from the menu's "Settings…" item. Plain SwiftUI window scene.

- Per-sport enable/disable toggles (NBA, NCAA MBB, MLB, PGA, NASCAR Cup).
- Favorite teams/drivers per sport (free-text or picklist; matched case-insensitively
  against abbreviations/names from the feed). Gonzaga is the obvious first NCAA favorite.
- Refresh cadence override (optional; sensible defaults from §7).
- Display strategy: cycle vs. pinned primary sport; max string length.
- All persisted via `@AppStorage`.

---

## 9. Build order (milestones)

Ship a vertical slice first; prove the whole pipeline before breadth.

1. **M1 — Basketball vertical slice.** `MenuBarExtra` skeleton + agent app + `ESPNClient`
   + Basketball adapter + format + fixed 30s poll. Goal: a real live/next score in the
   menu bar. This proves fetch → decode → format → display end to end.
   - **POC note:** the slice targets **NBA** (the `nba` slug) rather than NCAA Men's,
     because NCAA basketball is off-season in June while the NBA is live. Same adapter; only
     the league slug and period labels (quarters vs halves) differ. Swapping back to NCAA —
     or adding a hardcoded favorite like Gonzaga — is a one-line change.
2. **M2 — Settings + ranking.** Add the settings window, favorites, enable toggles, and
   the ranked-event selection + truncation from §6.
3. **M3 — Baseball + NBA.** Add MLB (incl. bases/outs) and NBA (same basketball adapter,
   second slug). Adaptive polling from §7.
4. **M4 — Golf.** Verify the PGA endpoint, add the leaderboard adapter and intermittent
   handling.
5. **M5 — NASCAR Cup.** Fetch a LIVE Cup event-detail payload first, confirm lap/stage/
   leader field paths, then implement the racing adapter (with the degraded fallback).
6. **M6 — Polish.** Cycling display, edge cases (postponed, OT, rain delay), error/no-data
   states.

---

## 10. Distribution (later, not MVP)

- Personal use: sideload. macOS Gatekeeper will warn on first launch — open
  System Settings → Privacy & Security → "Open Anyway."
- If ever shared: requires an Apple Developer account ($99/yr) to sign + notarize so
  recipients don't hit the unverified-developer wall. Out of scope for now.

---

## 11. Open items to resolve during build

- [ ] Confirm PGA golf endpoint slug + correct path (scoreboard vs leaderboard).
- [ ] Capture a live NASCAR Cup event-detail payload; confirm lap/stage/leader field paths.
- [ ] Decide bases rendering (diamond glyph vs `[1_3]` text) at actual menu-bar size.
- [ ] Confirm NBA period/OT labeling against a live game.
- [ ] Optional future: self-host an ESPN proxy (caching + rate limiting + base-URL swap)
      to insulate against upstream changes and remove per-IP rate-limit risk.

---

## Appendix — known dead ends

- **ARCA Menards Series:** no ESPN API slug exists; ARCA is a Fox-broadcast feeder series
  ESPN doesn't track. Not feasible via this data source. Out of scope.
- **Sportradar NASCAR API:** official, real-time, lap-by-lap for Cup/Xfinity/Truck — but
  enterprise-priced. Not used.

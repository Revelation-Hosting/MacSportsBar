# Architecture

MacSportsBar is a small, deliberately-layered SwiftUI menu-bar app. The guiding principle is
**adapter isolation**: each sport's data quirks live in exactly one file, so a breaking upstream
change — or a whole new league — is a localized edit rather than a refactor.

For the *what* and *why* (per-sport display formats, polling policy, product intent) see
[`menubar-sports-app-spec.md`](menubar-sports-app-spec.md). This document is the *how the code is
organized*.

## Data flow

```
            ┌─────────────────────────────  AppModel (@MainActor)  ─────────────────────────────┐
            │  poll loop ──▶ for each enabled league: adapter.fetch(using: client)               │
            │                       │                                                            │
   ESPN /   │                       ▼                                                            │
 NASCAR ───▶│   fetch + decode (defensive) + format  ──▶  [SportEvent]  ──▶ rank / filter /      │
  feeds     │                                                              cycle / window (±24h)  │
            │                                                                     │               │
            │                                                                     ▼               │
            │   render one composited NSImage  ──▶  MenuBarPresenter  ──▶  MenuBarExtra label     │
            └────────────────────────────────────────────────────────────────────────────────────┘
                                                                          │
                                            NotificationManager ◀─────────┘ (boundary diffs)
```

One poll cycle: the model asks every enabled league's adapter to fetch; each adapter owns its own
networking, JSON decoding, and string formatting, returning a normalized `SportEvent`. The model
ranks them, applies the favorites filter, picks what to show (with cycling and a ±24h favorites
window), and renders a single menu-bar image.

## Module map

| File | Responsibility |
|------|----------------|
| `SportAdapter.swift` | The `SportAdapter` protocol + `LeagueID` (sport/league slug + glyph). |
| `Adapters/*.swift` | One adapter per data **shape**: `BasketballAdapter`, `BaseballAdapter` (base/out), `GolfAdapter` (leaderboard), `RacingAdapter` (field), `FormulaOneAdapter` (multi-session weekend), and the generic `HeadToHeadAdapter` (`PeriodStyle` = quarters / hockey / soccer). |
| `SportEvent.swift` | The normalized model — `pre`/`live`/`final` state, `displayString`, optional `matchup`, team-logo URLs, and a `RaceFlag`. |
| `ESPNClient.swift` / `NASCARClient.swift` / `OpenF1Client.swift` / `F1LiveTimingClient.swift` | Thin HTTP/WS chokepoints (timeouts, headers, decoding) so adapters don't reinvent networking. |
| `LeagueCatalog.swift` | The league registry. Adding a league = one `SupportedLeague` entry here. |
| `AppModel.swift` | `@MainActor` brain: the poll loop, adaptive cadence, ranking, cycling, the favorites window, and the menu-bar render. Also defines `MenuBarPresenter`. |
| `MacSportsBarApp.swift` | App entry, `MenuBarExtra` scene, the `--smoke-test` path, the accessory (agent) activation policy. |
| `MenuContent.swift` | The dropdown shown on click (favorites digest, pin toggles, Settings/Quit). |
| `Settings.swift` / `SettingsView.swift` | `UserDefaults`-backed settings + the configuration window (sport toggles, team picker, notifications). |
| `NotificationManager.swift` | Favorite-team boundary notifications (start / period / final), each independently toggleable. |
| `LogoCache.swift` / `TeamDirectory.swift` | Async team-logo loading for the menu bar, and the per-league team list for the favorites picker. |

## Core abstractions

### `SportAdapter`
```swift
protocol SportAdapter {
    var league: LeagueID { get }
    func fetch(using client: ESPNClient, dates: String?) async throws -> [SportEvent]
}
```
Each adapter **owns its raw JSON types** (nested `Decodable` structs, every field optional) and a
pure `map(_:)` (or `liveReadout(_:)`) that turns one decoded event into a `SportEvent`. Decoding is
**defensive by rule**: a missing field degrades the string, it never crashes or drops the event.

### `SportEvent`
The single normalized shape the UI consumes. Adapters differ wildly upstream; everything downstream
(ranking, filtering, cycling, rendering, notifications) speaks only `SportEvent`. `state` carries
`pre`/`live`/`final`; `displayString` is the pre-formatted menu-bar text; `matchup`, logo URLs, and
`flag` drive the richer renders.

### Clients
`ESPNClient` wraps the public ESPN scoreboard API. `NASCARClient` is a second chokepoint for
NASCAR's own live timing feed, and `OpenF1Client` a third for Formula 1 constructors (see *Data
sources*). All are intentionally thin — the seam where a caching proxy or base-URL swap would live.

Two sports blend sources, and they do it differently. NASCAR *enriches* an ESPN event in place —
ESPN owns the schedule and final, NASCAR's feed overwrites a live race with real lap/stage/flag
telemetry. Formula 1 instead *fans out*: one ESPN event carries five sibling session competitions,
so `FormulaOneAdapter` emits one `SportEvent` per notable session (qualifying, sprint, race —
practice is skipped) and uses OpenF1 only to attach the constructor. Because adapters are rebuilt
on every poll tick (`AppModel.adapters` is computed), that constructor map cannot be cached on the
adapter — it lives in the process-wide `OpenF1ConstructorDirectory` actor with a multi-hour TTL.

### `LeagueCatalog`
A flat list of `SupportedLeague { id, league, makeAdapter }`. The poll loop, the Settings toggles,
and the favorites picker all derive from this list, so registering a league wires it everywhere.

## Extending

### Add a league to an existing sport
One entry in `LeagueCatalog`. Example — the FIFA World Cup is the generic soccer adapter pointed at
a new slug, with **no adapter changes**:
```swift
let worldcup = LeagueID(sport: "soccer", league: "fifa.world", displayName: "World Cup")
SupportedLeague(id: worldcup.league, league: worldcup,
                makeAdapter: { HeadToHeadAdapter(league: worldcup, favorites: $0, style: .soccer) })
```
Returning users auto-enable new leagues via the `Settings.seenLeagues` migration.

### Add a new sport (a new data *shape*)
Write a `SportAdapter`: own the raw `Decodable` types, write a pure `map(_:)` that produces a
`SportEvent`, then register it in `LeagueCatalog`. Land tests alongside it (below). If the feed is a
head-to-head match with periods, you may be able to reuse `HeadToHeadAdapter` instead.

## The menu bar render

A status item shows *either* text or an image — never both — so the label is rendered as **one
composited `NSImage`** (`ImageRenderer` over a SwiftUI `HStack`). Two subtleties earn their keep:

- **Dark-mode tint.** The image is non-template; its glyph + text are tinted to `menuBarColorScheme`,
  which is read from the status item's *own* appearance (the only source that tracks the real,
  wallpaper-driven menu-bar tint — the app's appearance and the global Dark Mode setting both miss it).
  Color logos/flags keep their own hue.
- **Flicker avoidance.** The composited image lives in a dedicated `MenuBarPresenter` observable that
  the label observes *instead of* `AppModel`. The poll loop reassigns `AppModel.events` every few
  seconds; if the label observed that, macOS would re-push (and intermittently drop) the status item.
  The render is also signature-skipped — identical readouts don't re-render.

## Adaptive polling

Cadence scales to relevance: tight (5–10s) while a favorite is live, moderate for any live game, and
slow (5 min) when nothing is on — but **ramping up as a favorite's scheduled start nears** (we already
know the kickoff time), so the live switch and its notification land promptly rather than on the idle
tick.

## Notifications

`NotificationManager` diffs each favorite event between polls and posts on *boundaries* only — game
**start** (pre→live), **period/inning/half** change, and **final** — never per score. Each kind toggles
independently; period/inning defaults off (it's the noisy one). The boundary classifier is a pure,
tested function. Requires the bundled `.app` (a bundle identifier + the user's permission); it's a
no-op under `swift run`.

## Testing

Coverage targets the **pure logic**, not the SwiftUI scenes. Adapters expose their `map`/`liveReadout`
and formatting helpers as pure, synchronously-callable seams, so tests exercise decode → format with
**no network**. Fixtures are either inline JSON or real captured payloads under
`Tests/MacSportsBarTests/Fixtures/`. The convention: **tests land with each feature**, and the suite
stays green and fully hermetic (it runs identically locally and in CI).

## Data sources & caveats

- **ESPN** `site.api.espn.com/apis/site/v2/sports/{sport}/{league}/scoreboard` — keyless but
  **undocumented and unofficial**; it can change shape without notice, which is exactly why every
  adapter decodes defensively.
- **NASCAR** has its own feed because ESPN holds no NASCAR rights (its NASCAR data is `basic/manual`,
  with no live laps/stages/flags). Live telemetry comes from `cf.nascar.com/live/feeds/live-feed.json`
  — and unlike ESPN, NASCAR publishes a [Swagger spec](https://feed.nascar.com/swagger). `RacingAdapter`
  blends ESPN (schedule/final) with NASCAR's feed (live lap/stage/flag/leader).
- **Formula 1** blends three sources. ESPN (`liveAvailable: false`, `gameSource: "scrubbed"`, and
  no team data at all) supplies the weekend schedule and post-session classifications;
  **Formula 1's own live timing feed** supplies live state; [OpenF1](https://openf1.org) is a
  keyless fallback for the constructor map when the live feed is unreachable (its data is
  CC BY-NC-SA 4.0 — see the README disclaimer — and its own live tier is a paid re-packaging of the
  same F1 feed, so it is deliberately not used for live).
  - `livetiming.formula1.com` speaks **SignalR Core** and accepts *unauthenticated* connections for
    timing topics. `F1LiveTimingClient` connects per poll — negotiate → WebSocket upgrade →
    handshake → `Subscribe` → read the one completion frame carrying full state → close — rather
    than holding a socket open. Only `CarData.z` / `Position.z` need a paid F1 TV token, and they
    are never requested.
  - **The snapshot lies between sessions**, serving the last session's frozen state indefinitely,
    so `F1LiveSnapshot.isLive` requires a fresh heartbeat *and* a running session status before
    anything renders as live.
  - F1 fronts the feed with an AWS WAF that 403s hosting/VPN egress ranges, so live is strictly an
    enhancement: any failure degrades silently to the ESPN view.
  - Two ESPN traps `FormulaOneAdapter` guards, both with fixture tests: on a live weekend the
    **event-level status lies** (`STATUS_FINAL` while the race is still scheduled — only the
    per-competition status is trustworthy), and a **cancelled GP reports `state: "post"`** with
    `completed: false`, which a naive `post → final` rule renders as a finished race.

Keyless by design means there are no secrets to leak — safe for a public repo. That constraint is
also why F1 has no live readout: the live tier would require stored credentials.

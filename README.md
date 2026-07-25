# MacSportsBar

[![CI](https://github.com/Revelation-Hosting/MacSportsBar/actions/workflows/ci.yml/badge.svg)](https://github.com/Revelation-Hosting/MacSportsBar/actions/workflows/ci.yml)

A native macOS **menu bar app** that shows live sports scores as a compact, glanceable
string in the system menu bar — a tiny always-there scoreboard, no dock icon and no
window in the way.

## Screenshots
<b>MLB Baseball</b><br/>
<img width="306" height="36" alt="Screenshot 2026-06-07 at 1 30 28 PM" src="https://github.com/user-attachments/assets/100a190a-bb1b-4c80-b5d1-75c857bb7c41" /><br/>
<img width="240" height="35" alt="Screenshot 2026-06-07 at 3 21 48 PM" src="https://github.com/user-attachments/assets/591f3a4d-99c4-4c85-b9b1-34452d1c3445" />
<br/>
<b>NASCAR</b><br/>
<img width="415" height="33" alt="Screenshot 2026-06-07 at 1 30 20 PM" src="https://github.com/user-attachments/assets/af4cb952-8506-4cd3-b6e8-8ccd05162b08" /><br/>
<img width="378" height="33" alt="Screenshot 2026-06-07 at 3 14 11 PM" src="https://github.com/user-attachments/assets/6f949945-dcf2-429f-951b-7445cbc3a6e0" /><br/>
<img width="384" height="30" alt="image" src="https://github.com/user-attachments/assets/08ea939f-1760-4b3c-99fe-d570b29fded1" />
<br/>
<b>PGA Golf</b><br/>
<img width="344" height="32" alt="Screenshot 2026-06-07 at 3 19 51 PM" src="https://github.com/user-attachments/assets/168b81fe-3fe3-42ce-af92-f5c9d32acade" />





## Text Examples
```
GONZ 72  UCLA 68 · 4:32 2H          ← live NCAA basketball
SEA 3  TEX 2 · Bot 7th · 2 out · [1_3]   ← live MLB with base/out state
Genesis Inv · Scheffler −12 thru 14      ← live PGA leaderboard
Coca-Cola 600 · L245/400 · St3 · #5 Larson   ← live NASCAR Cup
```

> **Status: pre-alpha proof-of-concept.** Under active development, built milestone by
> milestone (see [Roadmap](#roadmap)). **Twelve leagues across seven sports** — NBA, MLB, NFL,
> NHL, NCAA football, soccer (Premier League / Champions League / MLS / **World Cup**), PGA golf,
> NASCAR, and **Formula 1** — render in the menu bar today, each tagged with a league glyph, on an
> adaptive poll cadence. (NASCAR shows **live lap/stage/flag telemetry** with a colored flag glyph,
> sourced from NASCAR's own timing feed — ESPN holds no NASCAR rights, so its feed has none.
> Formula 1 is live too — track status, Safety Car/VSC, and the qualifying phase, from F1's own
> timing feed — see [Formula 1](#formula-1).)

---

## What it does

- Lives entirely in the menu bar via SwiftUI's `MenuBarExtra` (an *agent* app — no dock
  icon, no main window).
- Prefixes each score with a **league glyph** (an SF Symbol — 🏀 / ⚾) so you can tell NBA
  from MLB at a glance — or **opt into the playing teams' color logos** for live games.
- Polls live scores on an adaptive cadence and renders **one short string** (~20–30
  characters) so it survives menu-bar width limits and notch crowding on MacBooks.
- Ranks what's relevant (live favorite > live > starting soon > final today) and shows
  the top event, cycling through multiples on a timer.
- A click-through **Settings** window lets you pick favorite teams/drivers, enable/disable
  sports, and tune refresh cadence and display strategy.
- **Optional favorites notifications** — when a favorite team's game starts, at the end of each
  period/inning/half, and when it goes final — each **toggleable on its own** (per-inning alerts
  are off by default), never on every score. Requires the installed `.app`.
- A **±24h favorites view** — your teams' recent finals, live games, and upcoming matchups,
  surfaced both in the dropdown digest and the ticker.
- **Keyless and secret-free** — it uses public, no-auth data endpoints, so there's nothing
  to configure and nothing sensitive to store.

### Planned sports

| Sport            | Leagues                         | Shape          | Status   |
|------------------|---------------------------------|----------------|----------|
| Basketball       | NBA                             | head-to-head   | **live (M1)** |
| Baseball         | MLB (base/out state)            | head-to-head   | **live (M3)** |
| Football         | NFL, NCAA football              | head-to-head   | **live (M6)** |
| Hockey           | NHL                             | head-to-head   | **live (M6)** |
| Soccer           | Premier League, UCL, MLS, World Cup | head-to-head | **live (M6 + M13)** |
| Golf             | PGA                             | leaderboard    | **live (M4)** |
| Auto racing      | NASCAR Cup                      | field          | **live (M5 + M12: laps/stage/flags)** |
| Auto racing      | Formula 1                       | sessions       | **live (M14 + M15: flags/SC/VSC/quali)** |

See the full design in **[menubar-sports-app-spec.md](menubar-sports-app-spec.md)**.

### Formula 1

F1 blends two sources: **ESPN** for the weekend schedule and post-session classifications, and
**Formula 1's own live timing feed** for what's happening on track right now.

```
🏁 Hungary GP · Qualifying · Sat 7:00a          ← upcoming session
🟠 Hungary GP · Q2 · NOR (McLaren)              ← live qualifying, glyph in McLaren papaya
🟡 Hungary GP · L32/70 · SC · VER (Red Bull)    ← live race under Safety Car
🩵 Belgium GP · Antonelli won (Mercedes)        ← result
```

Live state comes from `livetiming.formula1.com` over SignalR, which — usefully — accepts
**unauthenticated** connections for timing topics: track status (green / yellow / **Safety Car** /
**VSC** / red), running order, lap count, and the qualifying phase. A safety car — physical or
virtual — flies the same yellow flag as any caution, with `SC` / `VSC` in the readout saying which.
The leading driver's **constructor logo** is hotlinked from F1's own CDN and drawn next to the flag,
so you can see at a glance who's in front.

Only car telemetry and track position (`CarData.z` / `Position.z`) sit behind a paid F1 TV token,
and the app never requests them. Practice sessions are skipped deliberately — they'd triple the
rotation for results nobody glances at a menu bar for.

Two honest caveats:

- **Some networks can't reach the feed.** F1 fronts it with an AWS WAF that rejects hosting and
  VPN egress ranges with a 403. If you're on a VPN, corporate network, or iCloud Private Relay,
  live F1 will silently degrade to the ESPN schedule + results view — which is why the live path is
  strictly an enhancement and never a hard dependency. (Excluding `livetiming.formula1.com` from
  your VPN's tunnel fixes it.)
- **The feed serves stale state between sessions**, returning the last session's frozen snapshot
  indefinitely, so the app refuses to render it as live unless the feed's own heartbeat is fresh
  *and* the session reports as running.

The connect-per-poll approach (negotiate → subscribe → read one snapshot → close, well under a
second) keeps this a low-volume, well-behaved client on an undocumented endpoint.

---

## Requirements

- **macOS 14 (Sonoma) or later** — deployment target is 14.0; developed on macOS 26.
- **A Swift 6 toolchain** — install [Xcode](https://developer.apple.com/xcode/) 15+ or the
  Command Line Tools (`xcode-select --install`). Developed on Xcode 26 / Swift 6.
- No API keys, accounts, or third-party dependencies.

---

## Build & run from source

Building from source is currently the only way to run MacSportsBar.

```bash
git clone https://github.com/Revelation-Hosting/MacSportsBar.git
cd MacSportsBar
swift run            # compiles and launches the menu-bar app
```

The app runs as a menu-bar *agent* — no dock icon, no window. Quit it from the menu-bar
item's **Quit** action. Prefer Xcode? Run `open Package.swift` and use the `MacSportsBar`
scheme.

Want to sanity-check the live data path without the GUI?

```bash
swift run MacSportsBar --smoke-test   # fetches once, prints the menu-bar strings, exits
```

### Install as a real app (no terminal)

`swift run` is great for development but ties up your terminal. To run MacSportsBar like a
normal menu-bar app — launched from Finder/Spotlight, surviving terminal sessions — build a
`.app` bundle:

```bash
./scripts/build-app.sh            # builds MacSportsBar.app in the repo root
./scripts/build-app.sh --install  # …and also copies it to /Applications
open MacSportsBar.app             # launch it (runs in the background; no dock icon)
```

**First launch — Gatekeeper:** the app is ad-hoc signed (not Developer-ID signed), so macOS
blocks it the first time. Right-click the app ▸ **Open** (or **System Settings ▸ Privacy &
Security ▸ Open Anyway**). After that it launches normally — add it to **System Settings ▸
General ▸ Login Items** to start it at login.

> Distributing the `.app` to *other* people's machines still trips Gatekeeper on their end;
> for a seamless install you'd sign + notarize with an Apple Developer account ($99/yr). That
> remains out of scope for the POC.

---

## Tests

The deterministic model and formatting logic is covered by **171 hermetic XCTest cases** —
every adapter's decode → format path (basketball; baseball with base/out state; the generic
head-to-head adapter for football, hockey, and soccer; the golf leaderboard; NASCAR's ESPN
baseline; and the NASCAR live-feed mapping with its flag-state enum), period/inning labels,
menu-bar truncation and cycle selection, favorites matching, the followed-series logic, and the
league auto-enable migration. Fixtures are inline JSON or captured real ESPN/NASCAR payloads.

```bash
swift test
```

The suite is **fully hermetic** — fixtures are bundled or inline, so no network is touched
and the tests run identically locally and in [CI](.github/workflows/ci.yml) (`swift build`
+ `swift test` on macOS for every push and pull request). UI scenes (`MenuBarExtra`, the
settings `Window`) are intentionally **not** tested headlessly; coverage targets the pure
logic.

---

## Usage

Once running, MacSportsBar appears as a short score string in the menu bar with no dock
icon. Click it to open the popover, then choose **Settings…** to:

- Toggle which sports are shown.
- **Pick favorite teams** from a per-league list (with team logos), or type players/drivers
  for golf/NASCAR. Favorite games sort to the front, can restrict the ticker, and drive
  notifications.
- Override the refresh cadence and toggle favorites-only notifications.
- Choose whether recent finals and upcoming favorites join the rotation (live always rotates),
  **pin a game** from the menu to keep one fixed, and set the maximum string length.

Settings persist automatically.

---

## How it works

A small, isolated-adapter architecture so a breaking upstream change is a one-file fix:

- `SportAdapter` (protocol) — one adapter per data shape, each owning its own
  fetch + decode + format.
- `SportEvent` (model) — normalized event with `pre` / `live` / `final` state and the
  pre-formatted menu-bar string.
- `ESPNClient` — a thin HTTP chokepoint where caching, timeouts, and a future base-URL
  swap live in one place.
- `NASCARClient` — a second chokepoint for NASCAR's own live timing feed, which carries the
  lap/stage/flag telemetry ESPN lacks (ESPN holds no NASCAR rights). It's the one sport that
  blends two sources: ESPN for the schedule/final, NASCAR's feed to enrich a live race. Handy
  bonus — NASCAR publishes a [Swagger spec](https://feed.nascar.com/swagger), so its field
  names and enums are documented rather than reverse-engineered.
- `OpenF1Client` — a third chokepoint, a keyless fallback for the F1 driver → constructor mapping
  when the live feed is unreachable (ESPN carries no F1 team data). Reads only OpenF1's free
  historical tier and caches for hours.
- `F1LiveTimingClient` — a fourth, speaking SignalR Core over a WebSocket to Formula 1's own live
  timing feed for track status, running order, lap count and the qualifying phase; see
  [Formula 1](#formula-1).

Polling is adaptive and deliberately gentle: slow (every 5 min) when nothing is live, fast
(5–10s) when a relevant event is in progress — and it **ramps up as a favorite's scheduled
start nears** (every minute within 15 min, every 20s in the final stretch) so tip-off is caught
promptly rather than on the slow idle tick.

How the code is organized — the adapter pattern, the data flow, and how to add a league or a new
sport — is in **[ARCHITECTURE.md](ARCHITECTURE.md)**. The product design, per-sport display formats,
and polling policy are in [menubar-sports-app-spec.md](menubar-sports-app-spec.md).

---

## Roadmap

- **M1** — Basketball vertical slice (**NBA** for the POC; NCAA is off-season in June):
  prove fetch → decode → format → display. ✅ **done**
- **M2** — Settings window, favorites, ranking, cycling display, truncation. ✅ **done**
- **M3** — MLB with live base/out state + adaptive polling (NBA landed early in M1). ✅ **done**
- **M4** — PGA golf leaderboard (intermittent handling). ✅ **done** (endpoint confirmed:
  `golf/pga/scoreboard`)
- **M5** — NASCAR Cup. ✅ **done** — started degraded (ESPN leader/winner only), now upgraded
  in **M12**.
- **M6** — League expansion: NFL, NHL, NCAA football, and soccer (Premier League / Champions
  League / MLS) on a shared head-to-head adapter, each with its own glyph. ✅ **done**
- **M7** — Favorites notifications, scoped to boundaries (end of period/inning/half + final),
  never per-score. ✅ **done** — requires the installed `.app` for notification permission.
- **M8** — Favorites team picker (per-league list with team logos) + structured exact-match
  favorites (no fuzzy collisions). ✅ **done**
- **M9** — Menu-bar team-logos toggle (opt-in; shows the live matchup's color logos instead
  of the league glyph). ✅ **done**
- **M10** — ±24h favorites window: recent finals + live + upcoming for your teams, in the
  dropdown digest and the ticker (adjacent days fetched only for leagues with favorites). ✅ **done**
- **M11** — Polish: an app icon and edge cases (postponed/OT/rain delay).
- **M12** — Real NASCAR live telemetry from NASCAR's own timing feed (`cf.nascar.com`, with a
  documented [Swagger spec](https://feed.nascar.com/swagger)): live lap/stage, running order with
  car number, and a colored flag glyph (green/yellow/red/checkered). ESPN — which holds no NASCAR
  rights — can't provide this, so the live race blends ESPN (schedule/final) with NASCAR's
  feed. ✅ **done**
- **M13** — FIFA **World Cup** (`soccer/fifa.world`), reusing the generic soccer head-to-head
  adapter untouched — a pure league registration. Lands in time for the 2026 tournament. ✅ **done**
- **M14** — **Formula 1** (`racing/f1`): one entry per notable session (qualifying, sprint, race)
  with the winner's constructor and a livery-tinted glyph. Guards two ESPN traps — the event-level
  status lies on a live weekend, and a cancelled GP reports `state: "post"`. ✅ **done**
- **M15** — **Live F1 timing** from Formula 1's own feed (`livetiming.formula1.com`, SignalR Core,
  unauthenticated): track status with distinct **Safety Car** and **VSC** glyphs, live running
  order with constructor livery, lap count, and the Q1/Q2/Q3 phase. Gated on a fresh heartbeat so
  the feed's between-sessions stale snapshot never renders as live, and degrades silently to the
  ESPN view on WAF-blocked networks. ✅ **done**

---

## Disclaimer

This project pulls scores from **public sports data endpoints that are not officially
supported for third-party use** (ESPN's, NASCAR's and Formula 1's own timing feeds, and OpenF1).
Those endpoints can
change shape or disappear without notice, and this project is **not affiliated with, endorsed
by, or sponsored by** any data provider, league, team, or broadcaster.

Formula 1 constructor data comes from **[OpenF1](https://openf1.org)**, an unofficial,
community-operated project that is likewise not associated with Formula 1. OpenF1's data is
licensed **[CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/)** — note that
those NonCommercial and ShareAlike terms attach to *that data*, and are not granted by this
project's MIT license. If you fork this and plan anything commercial, that's yours to resolve.

All league names, team names, driver names, and logos (e.g. NBA, MLB, PGA TOUR, NASCAR, Formula 1
and its constructors, and the relevant universities) are trademarks of their respective owners and
are used here only for identification — which is why F1 constructors are shown as a name plus a
livery colour rather than bundled logo artwork. The software is provided "as is," without warranty
of any kind — see [LICENSE](LICENSE). Use it responsibly and at your own risk.

---

## Contributing

Issues and pull requests are welcome. Because this is an early POC, the architecture and
milestones may shift — opening an issue to discuss before a large change is appreciated.

---

## License

[MIT](LICENSE) © 2026 Revelation Hosting

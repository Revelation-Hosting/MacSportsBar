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
> milestone (see [Roadmap](#roadmap)). **Eleven leagues across seven sports** — NBA, MLB, NFL,
> NHL, NCAA football, soccer (Premier League / Champions League / MLS / **World Cup**), PGA golf, and NASCAR
> — render in the menu bar today, each tagged with a league glyph, on an adaptive poll
> cadence. (NASCAR shows **live lap/stage/flag telemetry** with a colored flag glyph, sourced
> from NASCAR's own timing feed — ESPN holds no NASCAR rights, so its feed has none.)

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

See the full design in **[menubar-sports-app-spec.md](menubar-sports-app-spec.md)**.

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

The deterministic model and formatting logic is covered by **118 hermetic XCTest cases** —
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

---

## Disclaimer

This project pulls scores from **public sports data endpoints that are not officially
supported for third-party use** (ESPN's, and NASCAR's own timing feed). Those endpoints can
change shape or disappear without notice, and this project is **not affiliated with, endorsed
by, or sponsored by** any data provider, league, team, or broadcaster.

All league names, team names, driver names, and logos (e.g. NBA, MLB, PGA TOUR, NASCAR,
and the relevant universities) are trademarks of their respective owners and are used here
only for identification. The software is provided "as is," without warranty of any kind —
see [LICENSE](LICENSE). Use it responsibly and at your own risk.

---

## Contributing

Issues and pull requests are welcome. Because this is an early POC, the architecture and
milestones may shift — opening an issue to discuss before a large change is appreciated.

---

## License

[MIT](LICENSE) © 2026 Revelation Hosting

# MacSportsBar

[![CI](https://github.com/Revelation-Hosting/MacSportsBar/actions/workflows/ci.yml/badge.svg)](https://github.com/Revelation-Hosting/MacSportsBar/actions/workflows/ci.yml)

A native macOS **menu bar app** that shows live sports scores as a compact, glanceable
string in the system menu bar — a tiny always-there scoreboard, no dock icon and no
window in the way.

```
GONZ 72  UCLA 68 · 4:32 2H          ← live NCAA basketball
SEA 3  TEX 2 · Bot 7th · 2 out · [1_3]   ← live MLB with base/out state
Genesis Inv · Scheffler −12 thru 14      ← live PGA leaderboard
Coca-Cola 600 · L245/400 · St3 · #5 Larson   ← live NASCAR Cup
```

> **Status: pre-alpha proof-of-concept.** Under active development, built milestone by
> milestone (see [Roadmap](#roadmap)). **Ten leagues across seven sports** — NBA, MLB, NFL,
> NHL, NCAA football, soccer (Premier League / Champions League / MLS), PGA golf, and NASCAR
> — render in the menu bar today, each tagged with a league glyph, on an adaptive poll
> cadence. (NASCAR currently shows the leader/winner; live lap/stage telemetry is a planned
> upgrade — see the roadmap.)

---

## What it does

- Lives entirely in the menu bar via SwiftUI's `MenuBarExtra` (an *agent* app — no dock
  icon, no main window).
- Prefixes each score with a **league glyph** (an SF Symbol — 🏀 / ⚾) so you can tell NBA
  from MLB at a glance. (Team logos are a planned opt-in; they're illegible at menu-bar size
  by default, hence the monochrome league glyph.)
- Polls live scores on an adaptive cadence and renders **one short string** (~20–30
  characters) so it survives menu-bar width limits and notch crowding on MacBooks.
- Ranks what's relevant (live favorite > live > starting soon > final today) and shows
  the top event, cycling through multiples on a timer.
- A click-through **Settings** window lets you pick favorite teams/drivers, enable/disable
  sports, and tune refresh cadence and display strategy.
- **Optional favorites notifications** — at the end of each period/inning/half and when a
  favorite team's game goes final (never on every score). Requires the installed `.app`.
- **Keyless and secret-free** — it uses public, no-auth data endpoints, so there's nothing
  to configure and nothing sensitive to store.

### Planned sports

| Sport            | Leagues                         | Shape          | Status   |
|------------------|---------------------------------|----------------|----------|
| Basketball       | NBA                             | head-to-head   | **live (M1)** |
| Baseball         | MLB (base/out state)            | head-to-head   | **live (M3)** |
| Football         | NFL, NCAA football              | head-to-head   | **live (M6)** |
| Hockey           | NHL                             | head-to-head   | **live (M6)** |
| Soccer           | Premier League, UCL, MLS        | head-to-head   | **live (M6)** |
| Golf             | PGA                             | leaderboard    | **live (M4)** |
| Auto racing      | NASCAR Cup                      | field          | **live (M5, degraded)** |

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

The deterministic model and formatting logic is covered by **60 hermetic XCTest cases** —
every adapter's decode → format path (basketball; baseball with base/out state; the generic
head-to-head adapter for football, hockey, and soccer; the golf leaderboard; and NASCAR),
period/inning labels, menu-bar truncation and cycle selection, favorites matching, and the
league auto-enable migration. Fixtures are inline JSON or a captured real ESPN payload.

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
- Set favorite teams (comma-separated, matched case-insensitively against the feed).
  Favorite games sort to the front.
- Override the refresh cadence.
- Toggle cycling through multiple live games, and set the maximum string length.

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

Polling is adaptive and deliberately gentle: slow (every 5–10 min) when nothing is live,
fast (10–30s) when a relevant event is in progress, with finals cached on a long TTL.

Full architecture, per-sport display formats, and polling policy are documented in
[menubar-sports-app-spec.md](menubar-sports-app-spec.md).

---

## Roadmap

- **M1** — Basketball vertical slice (**NBA** for the POC; NCAA is off-season in June):
  prove fetch → decode → format → display. ✅ **done**
- **M2** — Settings window, favorites, ranking, cycling display, truncation. ✅ **done**
- **M3** — MLB with live base/out state + adaptive polling (NBA landed early in M1). ✅ **done**
- **M4** — PGA golf leaderboard (intermittent handling). ✅ **done** (endpoint confirmed:
  `golf/pga/scoreboard`)
- **M5** — NASCAR Cup. ✅ **done (degraded)** — shows the leader/winner + race time. Live
  lap/stage/leader telemetry (from the per-event detail endpoint) needs a green-flag Cup race
  to verify the field paths; that upgrade is pending.
- **M6** — League expansion: NFL, NHL, NCAA football, and soccer (Premier League / Champions
  League / MLS) on a shared head-to-head adapter, each with its own glyph. ✅ **done**
- **M7** — Favorites notifications, scoped to boundaries (end of period/inning/half + final),
  never per-score. ✅ **done** — requires the installed `.app` for notification permission.
- **M8** — Polish: team-logos opt-in toggle, an app icon, live NASCAR lap/stage telemetry,
  and edge cases (postponed/OT/rain delay).

---

## Disclaimer

This project pulls scores from **public, undocumented sports data endpoints that are not
officially supported**. Those endpoints can change shape or disappear without notice, and
this project is **not affiliated with, endorsed by, or sponsored by** any data provider,
league, team, or broadcaster.

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

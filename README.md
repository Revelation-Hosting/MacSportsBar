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
> milestone (see [Roadmap](#roadmap)). The **M1 slice works today**: it fetches live
> **NBA** scores and renders them in the menu bar. Other sports aren't implemented yet, and
> there's no packaged release — you run it by building from source.

---

## What it does

- Lives entirely in the menu bar via SwiftUI's `MenuBarExtra` (an *agent* app — no dock
  icon, no main window).
- Polls live scores on an adaptive cadence and renders **one short string** (~20–30
  characters) so it survives menu-bar width limits and notch crowding on MacBooks.
- Ranks what's relevant (live favorite > live > starting soon > final today) and shows
  the top event, cycling through multiples on a timer.
- A click-through **Settings** window lets you pick favorite teams/drivers, enable/disable
  sports, and tune refresh cadence and display strategy.
- **Keyless and secret-free** — it uses public, no-auth data endpoints, so there's nothing
  to configure and nothing sensitive to store.

### Planned sports

| Sport            | Leagues                         | Shape          | Status   |
|------------------|---------------------------------|----------------|----------|
| Basketball       | NBA, NCAA Men's                 | head-to-head   | **NBA live (M1)** |
| Baseball         | MLB                             | head-to-head   | planned  |
| Golf             | PGA                             | leaderboard    | planned  |
| Auto racing      | NASCAR Cup                      | field          | planned  |

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

> **Distributing a built `.app`** to other machines trips Gatekeeper (unidentified
> developer): the recipient allows it via **System Settings → Privacy & Security → Open
> Anyway**, or you sign/notarize with an Apple Developer account. That packaging is out of
> scope for the POC — running it yourself via `swift run` does not hit Gatekeeper.

---

## Tests

The deterministic model and formatting logic is covered by an XCTest suite — period labels
(NBA quarters vs NCAA halves, including OT), menu-bar truncation, favorites parsing,
cycle-candidate selection, and decode-and-format checks against both hand-crafted JSON and
a captured real ESPN scoreboard payload.

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
- **M3** — Add MLB (bases/outs) and NBA; adaptive polling.
- **M4** — PGA golf leaderboard (intermittent handling).
- **M5** — NASCAR Cup (live telemetry, with a degraded fallback).
- **M6** — Polish: cycling display, edge cases (postponed/OT/rain delay), error states.

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

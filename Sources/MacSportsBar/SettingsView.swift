import SwiftUI

/// The configuration window opened from the menu's "Settings…" item.
struct SettingsView: View {
    @ObservedObject private var settings = Settings.shared
    @StateObject private var directory = TeamDirectory()

    /// Enabled leagues that have a team list to pick from (everything but golf/racing).
    private var teamLeagues: [SupportedLeague] {
        LeagueCatalog.all.filter {
            settings.enabledLeagues.contains($0.id) && !Self.isIndividual($0.league)
        }
    }

    /// Enabled individual sports (golf/racing) — no team to pick, so you follow the whole series.
    private var individualLeagues: [SupportedLeague] {
        LeagueCatalog.all.filter {
            settings.enabledLeagues.contains($0.id) && Self.isIndividual($0.league)
        }
    }

    private static func isIndividual(_ league: LeagueID) -> Bool {
        league.sport == "golf" || league.sport == "racing"
    }

    var body: some View {
        Form {
            Section("Sports") {
                ForEach(LeagueCatalog.all) { league in
                    // Name … [☐ Favorites only] [switch] — the switch stays flush right like
                    // every other row; a bare `Toggle(name)` in an HStack would hug its label.
                    HStack(spacing: 12) {
                        Text(league.league.displayName)
                        Spacer()
                        Toggle("Favorites only", isOn: favoritesOnly(league.id))
                            .toggleStyle(.checkbox)
                            .disabled(!settings.enabledLeagues.contains(league.id))
                        Toggle(league.league.displayName, isOn: enabled(league.id))
                            .labelsHidden()
                    }
                }
                Text("Favorites only hides that league's other games once you've picked favorites in it — so you can keep every NCAAF game but only your club's matches in soccer.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Favorite teams") {
                if teamLeagues.isEmpty {
                    Text("Enable a team sport above to pick favorites.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(teamLeagues) { league in
                    TeamPickerGroup(league: league, settings: settings, directory: directory)
                }
                if !individualLeagues.isEmpty {
                    ForEach(individualLeagues) { league in
                        Toggle("Follow \(league.league.displayName)", isOn: following(league.id))
                    }
                    Text("Golf and NASCAR have no team to pick — follow the whole series so its events count as favorites. Add specific drivers/players below.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Other favorites") {
                TextField(
                    "Players, drivers, or teams by name",
                    text: $settings.favorites,
                    prompt: Text("e.g. Scheffler, Larson")
                )
                .textFieldStyle(.roundedBorder)
                Text("Comma-separated free text — used for golf/NASCAR (which have no team list) and as a fallback for teams.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Display") {
                Toggle("Show finished games in rotation", isOn: $settings.cycleFinished)
                Toggle("Show upcoming games in rotation", isOn: $settings.cycleUpcoming)
                Text("Live games always rotate. These add your favorites' recent finals and upcoming games to the cycle — pin a game from the menu to keep one fixed instead.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("Max length: \(settings.maxLength) characters",
                        value: $settings.maxLength, in: 12...80)
                Stepper("Live refresh every \(settings.refreshSeconds)s",
                        value: $settings.refreshSeconds, in: 10...600, step: 5)
                Text("Applies while games are live. When nothing is live, polling slows to every 5 minutes automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show team logos in the menu bar", isOn: $settings.showTeamLogos)
                Text("Replaces the league glyph with the playing teams' logos (in color) during live games.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("Notify me about my favorites", isOn: $settings.notifyFavorites)
                Group {
                    Toggle("When a game starts", isOn: $settings.notifyStart)
                    Toggle("At the end of each period / inning / half", isOn: $settings.notifyPeriod)
                    Toggle("When a game goes final", isOn: $settings.notifyFinal)
                }
                .padding(.leading)
                .disabled(!settings.notifyFavorites)
                Text("Favorites only — never on every score. Period/inning alerts are off by default (a notification per inning is a lot). Requires the installed app (see scripts/build-app.sh), not `swift run`.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 540)
    }

    /// Binding that adds/removes a league slug from the enabled set.
    private func enabled(_ id: String) -> Binding<Bool> {
        Binding(
            get: { settings.enabledLeagues.contains(id) },
            set: { isOn in
                if isOn { settings.enabledLeagues.insert(id) }
                else { settings.enabledLeagues.remove(id) }
            }
        )
    }

    /// Binding for restricting a league to favorite games.
    private func favoritesOnly(_ id: String) -> Binding<Bool> {
        Binding(
            get: { settings.isFavoritesOnly(id) },
            set: { settings.setFavoritesOnly(id, on: $0) }
        )
    }

    /// Binding for following an entire series (golf/NASCAR) by league slug.
    private func following(_ id: String) -> Binding<Bool> {
        Binding(
            get: { settings.isFollowingLeague(id) },
            set: { settings.setFollowingLeague(id, on: $0) }
        )
    }
}

/// Expandable per-league picker. Its team list (name + logo) loads lazily on first expand
/// and is cached by the shared `TeamDirectory`.
private struct TeamPickerGroup: View {
    let league: SupportedLeague
    @ObservedObject var settings: Settings
    let directory: TeamDirectory

    @State private var teams: [TeamInfo] = []
    @State private var didLoad = false
    @State private var query = ""

    /// Rows listed at once. Lists longer than this (college football has 700+ teams) get a
    /// search field, and the blank-query list is capped here so expanding the group doesn't
    /// mount hundreds of logo-loading rows.
    private static let rowCap = 50

    var body: some View {
        DisclosureGroup {
            teamList.task { await loadIfNeeded() }
        } label: {
            let count = settings.teamFavorites[league.id]?.count ?? 0
            Text(count > 0 ? "\(league.league.displayName) · \(count)" : league.league.displayName)
        }
    }

    @ViewBuilder private var teamList: some View {
        if teams.isEmpty {
            if didLoad {
                Text("No teams available.").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        } else {
            if teams.count > Self.rowCap {
                TextField("Search teams", text: $query, prompt: Text("Search \(teams.count) teams"))
                    .textFieldStyle(.roundedBorder)
            }
            let visible = TeamDirectory.visible(
                teams, query: query, selected: settings.teamFavorites[league.id] ?? [],
                cap: Self.rowCap)
            if visible.shown.isEmpty {
                Text("No teams match “\(query)”.").font(.caption).foregroundStyle(.secondary)
            } else if visible.hidden > 0 {
                Text("Showing \(visible.shown.count) of \(visible.shown.count + visible.hidden) — search to narrow.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(visible.shown) { team in
                Toggle(isOn: binding(team)) {
                    HStack(spacing: 8) {
                        AsyncImage(url: team.logoURL) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            Image(systemName: league.league.symbolName).foregroundStyle(.secondary)
                        }
                        .frame(width: 18, height: 18)
                        Text(team.name)
                    }
                }
            }
        }
    }

    private func loadIfNeeded() async {
        guard !didLoad else { return }
        teams = await directory.teams(for: league.league)
        didLoad = true
    }

    private func binding(_ team: TeamInfo) -> Binding<Bool> {
        Binding(
            get: { settings.isFavoriteTeam(team.id, in: league.id) },
            set: { settings.setFavoriteTeam(team.id, in: league.id, on: $0) }
        )
    }
}

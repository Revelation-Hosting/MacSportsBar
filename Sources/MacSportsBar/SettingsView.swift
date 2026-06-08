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
                    Toggle(league.league.displayName, isOn: enabled(league.id))
                }
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
                Toggle("Show favorites only", isOn: $settings.favoritesOnly)
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
                Text("Sends a notification when a favorite team's game starts, at the end of each period/inning/half, and when it goes final — not on every score. Requires the installed app (see scripts/build-app.sh), not `swift run`.")
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
            ForEach(teams) { team in
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

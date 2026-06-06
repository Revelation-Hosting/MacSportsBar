import SwiftUI

/// The configuration window opened from the menu's "Settings…" item.
struct SettingsView: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Form {
            Section("Sports") {
                ForEach(LeagueCatalog.all) { league in
                    Toggle(league.league.displayName, isOn: enabled(league.id))
                }
            }

            Section("Favorites") {
                TextField(
                    "Teams",
                    text: $settings.favorites,
                    prompt: Text("e.g. Knicks, NY, Spurs")
                )
                .textFieldStyle(.roundedBorder)
                Text("Comma-separated. Matched case-insensitively against team names and abbreviations; favorite games sort to the front.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show favorite teams only", isOn: $settings.favoritesOnly)
                Text("When on, the menu bar shows only your favorite teams' games.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Display") {
                Toggle("Cycle through multiple live games", isOn: $settings.cycleEnabled)
                Stepper("Max length: \(settings.maxLength) characters",
                        value: $settings.maxLength, in: 12...80)
                Stepper("Live refresh every \(settings.refreshSeconds)s",
                        value: $settings.refreshSeconds, in: 10...600, step: 5)
                Text("Applies while games are live. When nothing is live, polling slows to every 5 minutes automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("Notify me about my favorites", isOn: $settings.notifyFavorites)
                Text("Sends a notification at the end of each period/inning/half and when a favorite team's game goes final — not on every score. Requires the installed app (see scripts/build-app.sh), not `swift run`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 460)
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
}

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
            }

            Section("Display") {
                Toggle("Cycle through multiple live games", isOn: $settings.cycleEnabled)
                Stepper("Max length: \(settings.maxLength) characters",
                        value: $settings.maxLength, in: 12...80)
                Stepper("Refresh every \(settings.refreshSeconds)s",
                        value: $settings.refreshSeconds, in: 10...600, step: 5)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 380)
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

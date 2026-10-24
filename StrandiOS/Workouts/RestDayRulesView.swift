import SwiftUI
import StrandDesign
import WhoopStore

/// Which workouts count as training. Anything that doesn't leaves the day a rest day.
struct RestDayRulesView: View {
    /// Sports seen in the user's own history, so the list starts with what they actually do.
    let historySports: [String]

    @State private var light: Set<String> = RestDayRules.lightSports()
    @AppStorage(RestDayRules.minMinutesKey) private var minMinutes = RestDayRules.defaultMinMinutes

    private var sports: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in historySports + WorkoutCatalog.all.map(\.name) {
            let key = RestDayRules.sportKey(name)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(WorkoutSource.displaySport(name))
        }
        return out
    }

    var body: some View {
        List {
            Section {
                Stepper(value: $minMinutes, in: 0...120, step: 5) {
                    HStack {
                        Text("Shortest workout that counts")
                        Spacer()
                        Text(minMinutes == 0 ? String(localized: "Any") : String(localized: "\(minMinutes) min"))
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            } footer: {
                Text("A day is a rest day when none of its workouts count. Shorter ones don't count either.")
            }

            Section {
                ForEach(sports, id: \.self) { sport in
                    let key = RestDayRules.sportKey(sport)
                    Toggle(isOn: Binding(
                        get: { !light.contains(key) },
                        set: { counts in
                            if counts { light.remove(key) } else { light.insert(key) }
                            RestDayRules.setLightSports(light)
                        })) {
                        Label {
                            Text(sport)
                        } icon: {
                            WorkoutTypeIcon(workoutType: sport, size: 16, color: StrandPalette.textSecondary)
                        }
                    }
                }
            } header: {
                Text("Counts as training")
            } footer: {
                Text("Turn off anything you do on rest days, like walks or stretching. Your own sports are at the top.")
            }

            Section {
                Button("Reset to defaults") {
                    light = RestDayRules.defaultLightSports
                    RestDayRules.setLightSports(light)
                    minMinutes = RestDayRules.defaultMinMinutes
                }
            }
        }
        .navigationTitle("Rest days")
        .navigationBarTitleDisplayMode(.inline)
    }
}

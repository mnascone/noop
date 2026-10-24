import SwiftUI
import StrandDesign
import WhoopStore

/// Which sports get their logo on a Workouts calendar day, and how many logos a day shows.
enum WorkoutCalendarPrefs {
    static let priorityKey = "noop.workoutCalendar.priority"
    static let iconCountKey = "noop.workoutCalendar.iconCount"
    static let defaultIconCount = 1

    /// Prioritised sport keys (lowercased display names), most important first.
    static func priority(_ raw: String) -> [String] {
        raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    static func encode(_ keys: [String]) -> String { keys.joined(separator: "\n") }

    /// The sports to draw for a day: prioritised ones first (in the user's order), then by Effort, one per
    /// sport, up to `count`.
    static func logoSports(_ rows: [WorkoutRow], priority: [String], count: Int) -> [String] {
        let rank = Dictionary(priority.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let sorted = rows.sorted { a, b in
            let ra = rank[RestDayRules.sportKey(a.sport)] ?? Int.max
            let rb = rank[RestDayRules.sportKey(b.sport)] ?? Int.max
            if ra != rb { return ra < rb }
            return (a.strain ?? 0) > (b.strain ?? 0)
        }
        var seen = Set<String>()
        var out: [String] = []
        for r in sorted where seen.insert(RestDayRules.sportKey(r.sport)).inserted {
            out.append(r.sport)
            if out.count == count { break }
        }
        return out
    }
}

struct WorkoutCalendarSettingsView: View {
    let historySports: [String]

    @AppStorage(WorkoutCalendarPrefs.iconCountKey) private var iconCount = WorkoutCalendarPrefs.defaultIconCount
    @AppStorage(WorkoutCalendarPrefs.priorityKey) private var priorityRaw = ""

    private var priority: [String] { WorkoutCalendarPrefs.priority(priorityRaw) }

    /// Every sport worth offering, the user's own first, by display name.
    private var allSports: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in historySports + WorkoutCatalog.all.map(\.name) {
            let display = WorkoutSource.displaySport(name)
            if seen.insert(display.lowercased()).inserted { out.append(display) }
        }
        return out
    }

    private func display(_ key: String) -> String {
        allSports.first { $0.lowercased() == key } ?? key.capitalized
    }

    var body: some View {
        List {
            Section {
                Picker("Logos per day", selection: $iconCount) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("3").tag(3)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Logos per day")
            } footer: {
                Text("A day with more sports than this shows the ones that rank highest below, then the hardest.")
            }

            Section {
                if priority.isEmpty {
                    Text("None yet. The hardest workout of the day shows first.")
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                ForEach(priority, id: \.self) { key in
                    Label {
                        Text(display(key))
                    } icon: {
                        WorkoutTypeIcon(workoutType: display(key), size: 16, color: StrandPalette.accent)
                    }
                }
                .onMove { from, to in
                    var p = priority
                    p.move(fromOffsets: from, toOffset: to)
                    priorityRaw = WorkoutCalendarPrefs.encode(p)
                }
                .onDelete { idx in
                    var p = priority
                    p.remove(atOffsets: idx)
                    priorityRaw = WorkoutCalendarPrefs.encode(p)
                }
                Menu {
                    ForEach(allSports.filter { !priority.contains($0.lowercased()) }, id: \.self) { sport in
                        Button(sport) {
                            priorityRaw = WorkoutCalendarPrefs.encode(priority + [sport.lowercased()])
                        }
                    }
                } label: {
                    Label("Add a sport", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("Show first")
            } footer: {
                Text("Drag to set the order. These sports' logos always win a spot on the calendar.")
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Calendar logos")
        .navigationBarTitleDisplayMode(.inline)
    }
}

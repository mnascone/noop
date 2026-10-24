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

/// Workouts calendar settings: what counts as a rest day and which sports' logos show.
struct WorkoutCalendarSettingsView: View {
    @State private var addingSport = false
    @EnvironmentObject private var repo: Repository
    /// Sports from the user's own log, most frequent first. Loaded here so Settings can open this too.
    @State private var historySports: [String] = []

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
                NavigationLink {
                    RestDayRulesView(historySports: historySports)
                } label: {
                    Label("What counts as a rest day", systemImage: "bed.double")
                }
            } footer: {
                Text("Sports and the shortest workout that count as training.")
            }

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
                // A scrolling, searchable sheet: the full sport list overflowed a pop-up menu.
                Button { addingSport = true } label: {
                    Label("Add a sport", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("Show first")
            } footer: {
                Text("Drag to set the order. These sports' logos always win a spot on the calendar.")
            }
        }
        .environment(\.editMode, .constant(.active))
        .sheet(isPresented: $addingSport) {
            SportAddSheet(options: allSports.filter { !priority.contains($0.lowercased()) }) { sport in
                priorityRaw = WorkoutCalendarPrefs.encode(priority + [sport.lowercased()])
            }
        }
        .navigationTitle("Calendar settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let rows = await repo.workoutRows(days: 400)
            var counts: [String: Int] = [:]
            for r in rows { counts[WorkoutSource.displaySport(r.sport), default: 0] += 1 }
            historySports = counts.sorted { $0.value > $1.value }.map(\.key)
        }
    }
}

/// The sports to choose from, searchable, in a scrolling list. Tapping one adds it and closes the sheet.
private struct SportAddSheet: View {
    let options: [String]
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var shown: [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? options : options.filter { $0.range(of: q, options: .caseInsensitive) != nil }
    }

    var body: some View {
        NavigationStack {
            List(shown, id: \.self) { sport in
                Button {
                    onPick(sport)
                    dismiss()
                } label: {
                    Text(sport).foregroundStyle(StrandPalette.textPrimary)
                }
            }
            .environment(\.editMode, .constant(.inactive))
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search sports")
            .navigationTitle("Add a sport")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

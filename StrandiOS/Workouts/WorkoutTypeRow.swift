import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// A strength workout's types, right under its name: tap a type to add or take it off, + for a new one.
/// Types worked out from its sets or logged exercises show lightly until you choose; tapping one keeps it.
struct WorkoutTypeRow: View {
    let row: WorkoutRow
    @EnvironmentObject private var repo: Repository
    @ObservedObject private var workoutTypes = WorkoutCategoryStore.shared
    @State private var suggested: Set<StrengthCategory> = []
    @State private var notesTask: Task<Void, Never>?

    var body: some View {
        let chosen = workoutTypes.categories(startTs: row.startTs)
        StrengthTypeChips(chosen: chosen, suggested: chosen.isEmpty ? suggested : [],
                          onTap: { c in
                              var s = chosen
                              if s.contains(c) { s.remove(c) } else { s.insert(c) }
                              save(s)
                          },
                          onAdd: { c in save(chosen.union([c])) })
            .task(id: repo.refreshSeq) {
                suggested = Set(await LiftDays.build(rows: [row], repo: repo).first?.types ?? [])
            }
    }

    private func save(_ s: Set<StrengthCategory>) {
        workoutTypes.set(s, startTs: row.startTs)
        // The workout's notes name its types: bring them along once the taps settle.
        notesTask?.cancel()
        notesTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await WorkoutSetsStore.typesChanged(row: row, repo: repo)
        }
    }
}

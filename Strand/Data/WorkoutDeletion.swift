import Foundation
import WhoopStore

/// What goes with a workout when you delete it: its types, its sets, and (iOS) the auto tracker's memory
/// that it was offered, so the strap's data never brings it back.
@MainActor
enum WorkoutDeletion {
    static func forget(_ row: WorkoutRow) {
        WorkoutCategoryStore.shared.set([], startTs: row.startTs)
        #if os(iOS)
        WorkoutSetsStore.remove(startTs: row.startTs, sport: row.sport)
        AutoWorkoutTracker.rememberOffered(row.startTs...max(row.startTs, row.endTs))
        #endif
    }
}

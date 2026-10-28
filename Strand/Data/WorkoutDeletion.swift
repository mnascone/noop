import Foundation
import WhoopStore

/// What goes with a workout when you delete it: its types and (iOS) its sets.
@MainActor
enum WorkoutDeletion {
    static func forget(_ row: WorkoutRow) {
        WorkoutCategoryStore.shared.set([], startTs: row.startTs)
        #if os(iOS)
        WorkoutSetsStore.remove(startTs: row.startTs, sport: row.sport)
        #endif
    }
}

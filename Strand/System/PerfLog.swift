import Foundation

// MARK: - Slow-path evidence
//
// "The app is slow" cannot be debugged from a report alone: nothing in the strap log said which screen
// waited, on what, or for how long. These lines are written only when a measured step runs past its
// threshold, so an ordinary session's log is unchanged and a slow one names the step. Always on, like the
// other rare-event lines: a report from someone without Test Centre enabled still carries them.

enum PerfLog {
    /// Where the lines go: the shareable strap log, wired once by `AppModel`.
    @MainActor static var sink: ((String) -> Void)?

    /// A monotonic start mark for `report`.
    static func mark() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Seconds since `start`.
    static func seconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000_000
    }

    /// One `perf:` line when the step since `start` took at least `threshold` seconds.
    @MainActor static func report(_ label: String, since start: UInt64, over threshold: Double = 0.25,
                                  detail: String = "") {
        let s = seconds(since: start)
        guard s >= threshold else { return }
        let extra = detail.isEmpty ? "" : " (\(detail))"
        sink?("perf: \(label) took \(String(format: "%.2f", s)) s\(extra)")
    }
}

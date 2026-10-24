import Foundation
import WhoopStore

/// What counts as a training day. A day with no counted workout is a rest day.
///
/// The user picks which sports don't break a rest day (a walk, stretching, yoga by default) and how long a
/// workout has to be before it counts. The Workouts calendar, the "rest days" count and the Today
/// recommendation all read these rules through `isTraining`, so they always agree.
enum RestDayRules {
    static let lightSportsKey = "noop.restDay.lightSports"
    static let minMinutesKey = "noop.restDay.minMinutes"

    /// Sports that don't count as training out of the box. Stored lowercased.
    static let defaultLightSports: Set<String> = [
        "walking", "treadmill walk", "stretching", "yoga", "meditation", "golf", "bowling", "activity",
    ]
    static let defaultMinMinutes = 20

    static func lightSports(_ d: UserDefaults = .standard) -> Set<String> {
        guard let raw = d.array(forKey: lightSportsKey) as? [String] else { return defaultLightSports }
        return Set(raw.map { $0.lowercased() })
    }

    static func setLightSports(_ s: Set<String>, _ d: UserDefaults = .standard) {
        d.set(s.sorted(), forKey: lightSportsKey)
    }

    static func minMinutes(_ d: UserDefaults = .standard) -> Int {
        d.object(forKey: minMinutesKey) == nil ? defaultMinMinutes : max(0, d.integer(forKey: minMinutesKey))
    }

    /// The label a sport is matched on, the same one the workout list shows.
    static func sportKey(_ sport: String) -> String {
        WorkoutSource.displaySport(sport).lowercased()
    }

    /// One frozen copy of the rules, so a calendar month is judged against one set of settings.
    struct Snapshot: Equatable {
        var light: Set<String>
        var minMinutes: Int

        static func current(_ d: UserDefaults = .standard) -> Snapshot {
            Snapshot(light: RestDayRules.lightSports(d), minMinutes: RestDayRules.minMinutes(d))
        }

        func isTraining(_ row: WorkoutRow) -> Bool {
            let seconds = row.durationS ?? Double(max(0, row.endTs - row.startTs))
            guard seconds >= Double(minMinutes * 60) else { return false }
            return !light.contains(RestDayRules.sportKey(row.sport))
        }
    }

    /// Puts each workout on the day it belongs to: the day you last woke up before it. A workout late at
    /// night before bed stays on that day instead of rolling onto the next date.
    struct WakeDays: Equatable {
        /// Ends of the main sleeps (3 h or longer), ascending.
        let wakes: [Int]
        /// A wake older than this before the workout (a night with no data) falls back to the date.
        static let maxGapS = 30 * 3600
        static let calendar = WakeDays(wakes: [])

        init(wakes: [Int]) { self.wakes = wakes.sorted() }

        func dayKey(_ ts: Int) -> String {
            var lo = 0, hi = wakes.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if wakes[mid] <= ts { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0, ts - wakes[lo - 1] < Self.maxGapS {
                return Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(wakes[lo - 1])))
            }
            return Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(ts)))
        }

        /// The day you're in now: since your last sleep.
        func currentDayKey(now: Date = Date()) -> String { dayKey(Int(now.timeIntervalSince1970)) }
    }

    /// Day key → that day's counted workouts. Days missing from the result are rest days.
    static func trainingDays(_ rows: [WorkoutRow], rules: Snapshot,
                             days: WakeDays = .calendar) -> [String: [WorkoutRow]] {
        var out: [String: [WorkoutRow]] = [:]
        for r in rows where rules.isTraining(r) {
            out[days.dayKey(r.startTs), default: []].append(r)
        }
        return out
    }

    /// The `count` days before `todayKey`, newest first. The current day isn't over, so it never counts as
    /// a rest day yet.
    static func pastDayKeys(count: Int, todayKey: String) -> [String] {
        let cal = Calendar.current
        let parts = todayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let today = cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
        else { return [] }
        return (1...max(1, count)).compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
            .map(Repository.localDayKey)
    }

    struct Week: Equatable {
        /// Rest days in the last 7 finished days.
        var restDays: Int
        /// Days in a row with training, ending yesterday (or today, if today already has one).
        var trainingStreak: Int
        var trainedToday: Bool
    }

    static func week(_ rows: [WorkoutRow], rules: Snapshot, days: WakeDays = .calendar,
                     now: Date = Date()) -> Week {
        let trained = trainingDays(rows, rules: rules, days: days)
        let todayKey = days.currentDayKey(now: now)
        let rest = pastDayKeys(count: 7, todayKey: todayKey).filter { trained[$0] == nil }.count
        let trainedToday = trained[todayKey] != nil
        var streak = trainedToday ? 1 : 0
        for key in pastDayKeys(count: 60, todayKey: todayKey) {
            guard trained[key] != nil else { break }
            streak += 1
        }
        return Week(restDays: rest, trainingStreak: streak, trainedToday: trainedToday)
    }

    /// The plain rule-based advice that factors Charge against recent rest. Used on its own when the AI
    /// coach isn't set up, and passed to the coach as context when it is. nil = nothing to add.
    static func advice(charge: Double?, week: Week) -> String? {
        let c = charge ?? 50
        if week.trainingStreak >= 6 && !week.trainedToday {
            return String(localized: "You've trained \(week.trainingStreak) days straight. Make today a rest day.")
        }
        if week.restDays == 0 {
            return c < 50
                ? String(localized: "No rest days in the last week and Charge is low. Take today off.")
                : String(localized: "No rest days in the last week. Plan one in the next day or two.")
        }
        if c < 34 && week.restDays <= 1 {
            return String(localized: "Low Charge and only one rest day this week. Keep today easy or skip it.")
        }
        if c >= 67 && week.restDays >= 3 {
            return String(localized: "\(week.restDays) rest days this week and Charge is good. A hard session fits today.")
        }
        return nil
    }
}

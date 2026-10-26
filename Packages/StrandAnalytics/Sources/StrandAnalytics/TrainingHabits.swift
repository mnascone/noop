import Foundation

/// Your own training rhythm, for the coach: which weekdays you usually do each sport, and how long since
/// you last did it. So a brief can say "it's Wednesday, you usually lift" instead of guessing a plan.
///
/// A weekday is "usual" for a sport when it happened on that weekday in at least `usualShare` of the
/// weeks observed (at most `weeks`, counted back from today), and at least `minTimes` times. Days are
/// local "yyyy-MM-dd" keys. Pure.
public enum TrainingHabits {
    public struct Habit: Equatable {
        public let sport: String
        /// Weekdays, 1 = Sunday ... 7 = Saturday (Gregorian), in week order from Monday.
        public let weekdays: [Int]
        public let sessions: Int
        public let daysSinceLast: Int?
    }

    public static let weeks = 8
    public static let usualShare = 0.5
    public static let minTimes = 3

    /// Habits for every sport with at least `minTimes` sessions in the window, most frequent first.
    public static func habits(_ sessions: [(day: String, sport: String)], todayKey: String) -> [Habit] {
        guard let today = date(todayKey) else { return [] }
        let cal = calendar
        let windowStart = cal.date(byAdding: .day, value: -weeks * 7 + 1, to: today) ?? today
        var bySport: [String: [Date]] = [:]
        for s in sessions {
            guard let d = date(s.day), d <= today else { continue }
            bySport[s.sport, default: []].append(d)
        }
        var out: [Habit] = []
        for (sport, all) in bySport {
            let inWindow = Set(all.filter { $0 >= windowStart })
            guard inWindow.count >= minTimes else { continue }
            let first = inWindow.min() ?? today
            let observedWeeks = max(1, min(weeks, (cal.dateComponents([.day], from: first, to: today).day ?? 0) / 7 + 1))
            var counts: [Int: Int] = [:]
            for d in inWindow { counts[cal.component(.weekday, from: d), default: 0] += 1 }
            let usual = counts.filter { $0.value >= minTimes && Double($0.value) / Double(observedWeeks) >= usualShare }
                .map(\.key)
                .sorted { order($0) < order($1) }
            let last = all.max()
            let since = last.flatMap { cal.dateComponents([.day], from: $0, to: today).day }
            out.append(Habit(sport: sport, weekdays: usual, sessions: inWindow.count, daysSinceLast: since))
        }
        return out.sorted { $0.sessions != $1.sessions ? $0.sessions > $1.sessions : $0.sport < $1.sport }
    }

    /// The sports you usually do on today's weekday.
    public static func usualToday(_ habits: [Habit], todayKey: String) -> [String] {
        guard let today = date(todayKey) else { return [] }
        let wd = calendar.component(.weekday, from: today)
        return habits.filter { $0.weekdays.contains(wd) }.map(\.sport)
    }

    /// Monday first.
    static func order(_ weekday: Int) -> Int { (weekday + 5) % 7 }

    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func date(_ key: String) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
}

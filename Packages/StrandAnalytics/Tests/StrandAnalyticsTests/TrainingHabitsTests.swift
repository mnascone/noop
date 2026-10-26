import XCTest
@testable import StrandAnalytics

final class TrainingHabitsTests: XCTestCase {
    /// Eight weeks of lifting Mon/Wed/Fri and hockey most Tuesdays, plus one odd Saturday swim.
    private func sessions() -> [(day: String, sport: String)] {
        var out: [(String, String)] = []
        // 2026-08-31 is a Monday.
        let cal = TrainingHabits.calendar
        let start = TrainingHabits.date("2026-08-31")!
        for week in 0..<8 {
            for (offset, sport) in [(0, "Strength"), (2, "Strength"), (4, "Strength")] {
                let d = cal.date(byAdding: .day, value: week * 7 + offset, to: start)!
                out.append((key(d), sport))
            }
            if week != 3 {
                out.append((key(cal.date(byAdding: .day, value: week * 7 + 1, to: start)!), "Hockey"))
            }
        }
        out.append(("2026-09-12", "Swimming"))
        return out
    }

    private func key(_ d: Date) -> String {
        let c = TrainingHabits.calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    func testFindsUsualDaysPerSport() {
        // 2026-10-21 is a Wednesday, the day after the last week's Tuesday.
        let h = TrainingHabits.habits(sessions(), todayKey: "2026-10-21")
        XCTAssertEqual(h.first?.sport, "Strength")
        XCTAssertEqual(h.first?.weekdays, [2, 4, 6])   // Mon, Wed, Fri
        XCTAssertEqual(h.first { $0.sport == "Hockey" }?.weekdays, [3])
        XCTAssertNil(h.first { $0.sport == "Swimming" }, "one swim is not a habit")
        XCTAssertEqual(TrainingHabits.usualToday(h, todayKey: "2026-10-21"), ["Strength"])
        XCTAssertEqual(h.first { $0.sport == "Hockey" }?.daysSinceLast, 1)
    }

    func testNothingFromTooFewSessions() {
        XCTAssertTrue(TrainingHabits.habits([("2026-10-01", "Running"), ("2026-10-08", "Running")],
                                            todayKey: "2026-10-20").isEmpty)
    }
}

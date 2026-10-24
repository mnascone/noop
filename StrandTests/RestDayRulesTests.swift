import XCTest
import WhoopStore
@testable import Strand

/// What counts as a training day, the rest-day count and the rule-based advice built on them.
final class RestDayRulesTests: XCTestCase {
    private let rules = RestDayRules.Snapshot(light: ["walking", "stretching"], minMinutes: 20)

    private func row(_ sport: String, daysAgo: Int, minutes: Double, now: Date) -> WorkoutRow {
        let start = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!
        let ts = Int(start.timeIntervalSince1970)
        return WorkoutRow(startTs: ts, endTs: ts + Int(minutes * 60), sport: sport, source: "manual",
                          durationS: minutes * 60, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                          distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
    }

    private var noon: Date {
        Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
    }

    func testLightSportsAndShortWorkoutsDoNotCount() {
        let now = noon
        XCTAssertFalse(rules.isTraining(row("Walking", daysAgo: 0, minutes: 90, now: now)))
        XCTAssertFalse(rules.isTraining(row("Ice Hockey", daysAgo: 0, minutes: 10, now: now)))
        XCTAssertTrue(rules.isTraining(row("Ice Hockey", daysAgo: 0, minutes: 60, now: now)))
        // Stored camelCase WHOOP names match on their display form.
        XCTAssertTrue(rules.isTraining(row("TraditionalStrengthTraining", daysAgo: 0, minutes: 45, now: now)))
    }

    func testWeekCountsRestDaysAndStreak() {
        let now = noon
        // Trained yesterday, 2 and 3 days ago; walked 4 days ago (still rest); nothing else.
        let rows = [
            row("Strength", daysAgo: 1, minutes: 50, now: now),
            row("Ice Hockey", daysAgo: 2, minutes: 70, now: now),
            row("Running", daysAgo: 3, minutes: 30, now: now),
            row("Walking", daysAgo: 4, minutes: 60, now: now),
        ]
        let week = RestDayRules.week(rows, rules: rules, now: now)
        XCTAssertEqual(week.restDays, 4)
        XCTAssertEqual(week.trainingStreak, 3)
        XCTAssertFalse(week.trainedToday)
    }

    func testAdviceFlagsNoRestAndLongStreaks() {
        let none = RestDayRules.Week(restDays: 0, trainingStreak: 3, trainedToday: false)
        XCTAssertNotNil(RestDayRules.advice(charge: 80, week: none))
        let streak = RestDayRules.Week(restDays: 1, trainingStreak: 7, trainedToday: false)
        XCTAssertNotNil(RestDayRules.advice(charge: 90, week: streak))
        let rested = RestDayRules.Week(restDays: 3, trainingStreak: 0, trainedToday: false)
        XCTAssertNotNil(RestDayRules.advice(charge: 80, week: rested))
        let ordinary = RestDayRules.Week(restDays: 2, trainingStreak: 2, trainedToday: false)
        XCTAssertNil(RestDayRules.advice(charge: 55, week: ordinary))
    }
}

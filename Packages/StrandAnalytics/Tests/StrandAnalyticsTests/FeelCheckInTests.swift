import XCTest
@testable import StrandAnalytics

final class FeelCheckInTests: XCTestCase {
    typealias F = FeelCheckIn

    func testAgreeingWithTheScoreLeavesAdviceAlone() {
        XCTAssertNil(F.advice(charge: 80, feel: .asScored, reasons: []))
    }

    func testSoreOnAGreenDaySteersToAnEasierSession() {
        let a = F.advice(charge: 82, feel: .off, reasons: [.sore])
        XCTAssertTrue(a?.contains("easier") == true)
    }

    func testUnwellAlwaysRests() {
        for charge in [10.0, 50, 90] {
            XCTAssertTrue(F.advice(charge: charge, feel: .off, reasons: [.unwell, .sore])?.contains("rest") == true)
        }
    }

    /// Feeling good on a red day allows a light session, never a hard one.
    func testFeelingGoodOnARedDayAllowsLightOnly() {
        let a = F.advice(charge: 25, feel: .better, reasons: [.fresh]) ?? ""
        XCTAssertTrue(a.contains("light session"))
        XCTAssertFalse(a.contains("push"))
    }

    func testPatternNeedsRepeatsAndMostOfTheChances() {
        // Hockey on 4 days; sore the next day 3 times; a check-in the next day every time.
        let sports = ["2026-10-01": ["Hockey"], "2026-10-05": ["Hockey"], "2026-10-09": ["Hockey"],
                      "2026-10-13": ["Hockey"], "2026-10-20": ["Strength"]]
        let entries = [
            F.Entry(day: "2026-10-02", feel: .off, reasons: [.sore], ts: 0),
            F.Entry(day: "2026-10-06", feel: .off, reasons: [.sore], ts: 0),
            F.Entry(day: "2026-10-10", feel: .off, reasons: [.sore, .lowEnergy], ts: 0),
            F.Entry(day: "2026-10-14", feel: .asScored, ts: 0),
            F.Entry(day: "2026-10-21", feel: .off, reasons: [.sore], ts: 0),
        ]
        let p = F.patterns(entries, sportsByDay: sports)
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p.first?.sport, "Hockey")
        XCTAssertEqual(p.first?.reason, .sore)
        XCTAssertEqual(p.first?.times, 3)
        XCTAssertEqual(p.first?.outOf, 4)
        // Two coincidences are not a pattern.
        XCTAssertTrue(F.patterns(Array(entries.prefix(2)), sportsByDay: sports).isEmpty)
    }

    func testPreviousDayCrossesMonthAndYear() {
        XCTAssertEqual(F.previousDay("2026-03-01"), "2026-02-28")
        XCTAssertEqual(F.previousDay("2027-01-01"), "2026-12-31")
    }
}

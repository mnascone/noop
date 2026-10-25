import XCTest
@testable import StrandAnalytics

final class ChargeChangeTests: XCTestCase {
    private func night(_ i: Int, charge: Double? = 70, hrv: Double? = 50, rhr: Double? = 55,
                       sleep: Double? = 450, resp: Double? = 15, skin: Double? = 0) -> ChargeChange.Night {
        ChargeChange.Night(day: String(format: "2026-10-%02d", i), charge: charge, hrv: hrv, restingHR: rhr,
                           sleepMin: sleep, respRate: resp, skinTempDev: skin)
    }

    /// A low-HRV, high-resting-HR night after a good one: both named, HRV first, Charge down.
    func testLowHRVNightExplainsTheDrop() {
        var n = (1...10).map { night($0) }
        n.append(night(11, charge: 80, hrv: 58))
        n.append(night(12, charge: 48, hrv: 38, rhr: 60))
        let e = ChargeChange.explain(n)!
        XCTAssertEqual(e.delta, -32)
        XCTAssertEqual(e.drivers.first?.factor, .hrv)
        XCTAssertTrue(e.drivers.first!.pull < 0)
        XCTAssertEqual(e.drivers.first?.yesterday, 58)
        XCTAssertTrue(e.drivers.contains { $0.factor == .restingHR && $0.pull < 0 })
        // Sleep and breathing were usual, so they aren't listed.
        XCTAssertFalse(e.drivers.contains { $0.factor == .sleep || $0.factor == .respiration })
    }

    func testUsualNightListsNothing() {
        let n = (1...10).map { night($0) }
        XCTAssertEqual(ChargeChange.explain(n)?.drivers, [])
    }

    func testNeedsThreeEarlierNights() {
        XCTAssertNil(ChargeChange.explain([night(1), night(2), night(3)]))
        XCTAssertNotNil(ChargeChange.explain([night(1), night(2), night(3), night(4)]))
    }

    /// Today's row with no overnight inputs yet: explain the last night that has them.
    func testSkipsAnEmptyTodayRow() {
        var n = (1...6).map { night($0) }
        n.append(night(7, charge: nil, hrv: nil, rhr: nil, sleep: nil, resp: nil, skin: nil))
        XCTAssertEqual(ChargeChange.explain(n)?.day, "2026-10-06")
    }

    func testWarmSkinCountsAgainst() {
        var n = (1...6).map { night($0) }
        n.append(night(7, skin: 0.8))
        XCTAssertEqual(ChargeChange.explain(n)?.drivers.first?.factor, .skinTemp)
    }
}

import XCTest
@testable import StrandAnalytics

final class FuelingCheckTests: XCTestCase {
    private func day(_ d: String, kcal: Double?, p: Double?, c: Double?, f: Double? = 70,
                     burned: Double? = 2600, effort: Double?) -> FuelingCheck.Day {
        FuelingCheck.Day(day: d, kcal: kcal, proteinG: p, carbsG: c, fatG: f, burnedKcal: burned, effort: effort)
    }

    /// A hard day (Effort 70) for an 80 kg athlete wants 7 g/kg carbs (560 g) and 1.6 g/kg protein (128 g).
    func testHardDayUnderfuelledCarbsButProteinFine() throws {
        let r = try XCTUnwrap(FuelingCheck.evaluate([
            day("2026-10-21", kcal: 2400, p: 140, c: 300, effort: 70),
            day("2026-10-22", kcal: 800, p: 40, c: 90, effort: 10),
        ], weightKg: 80))
        // Today (still eating) is skipped; yesterday is judged.
        XCTAssertEqual(r.day, "2026-10-21")
        XCTAssertEqual(r.carbsPerKgTarget, 7)
        XCTAssertEqual(r.glycogen?.status, .low)
        XCTAssertEqual(r.glycogen?.target ?? 0, 560, accuracy: 0.01)
        XCTAssertEqual(r.protein?.status, .good)
        XCTAssertEqual(r.energyBalanceKcal ?? 0, -200, accuracy: 0.01)
    }

    func testRestDayTargetsAreLower() throws {
        let r = try XCTUnwrap(FuelingCheck.evaluate([
            day("2026-10-22", kcal: 2000, p: 100, c: 240, effort: 5),
        ], weightKg: 80, skipLast: false))
        XCTAssertEqual(r.carbsPerKgTarget, 3)
        XCTAssertEqual(r.glycogen?.status, .good)       // 240 vs 240
        XCTAssertEqual(r.protein?.status, .good)        // 100 vs 96
    }

    func testNothingLoggedIsNil() {
        XCTAssertNil(FuelingCheck.evaluate([day("2026-10-22", kcal: nil, p: nil, c: nil, effort: 40)], weightKg: 80))
    }
}

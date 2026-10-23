import XCTest
@testable import StrandAnalytics

/// The v2 sleep score: ordinary and poor nights score clearly lower than v1, a genuinely good night
/// still reaches the high 90s, and the breakdown always sums to the score.
final class RestScoreV2Tests: XCTestCase {

    typealias R = AnalyticsEngine.Rest

    private func score(hours: Double, need: Double = 8, eff: Double, restorative: Double,
                       deep: Double = 0.16, consistency: Double? = 0.7) -> Double {
        let tst = hours * 3600
        return R.composite(tstSeconds: tst, inBedSeconds: tst / eff, efficiency: eff,
                           restorativeSeconds: tst * restorative, needHours: need,
                           consistency: consistency, deepSeconds: tst * deep)
    }

    func testGoodNightCanScoreHigh() {
        let s = score(hours: 8.2, eff: 0.94, restorative: 0.47, deep: 0.18, consistency: 0.95)
        XCTAssertGreaterThanOrEqual(s, 97)
        XCTAssertLessThanOrEqual(s, 100)
    }

    func testPerfectInputsScoreExactly100() {
        XCTAssertEqual(score(hours: 9, eff: 1, restorative: 0.5, deep: 0.2, consistency: 1), 100)
    }

    func testShortBrokenNightScoresLow() {
        // 6 h of an 8 h need, 85% efficiency, 35% restorative: v1 put this around 73.
        let s = score(hours: 6, eff: 0.85, restorative: 0.35, consistency: 0.5)
        XCTAssertLessThan(s, 55)
        XCTAssertGreaterThan(s, 35)
    }

    func testOkayNightLandsInTheMiddle() {
        // 7 h, 88%, 40%: decent but not great. v1 put this around 83.
        let s = score(hours: 7, eff: 0.88, restorative: 0.40, consistency: 0.6)
        XCTAssertGreaterThan(s, 60)
        XCTAssertLessThan(s, 78)
    }

    func testScoreIsMonotonicInEachFactor() {
        let base = score(hours: 7, eff: 0.88, restorative: 0.40)
        XCTAssertGreaterThan(score(hours: 7.5, eff: 0.88, restorative: 0.40), base)
        XCTAssertGreaterThan(score(hours: 7, eff: 0.91, restorative: 0.40), base)
        XCTAssertGreaterThan(score(hours: 7, eff: 0.88, restorative: 0.44), base)
        XCTAssertGreaterThan(score(hours: 7, eff: 0.88, restorative: 0.40, consistency: 0.9), base)
    }

    func testCurveFloors() {
        XCTAssertEqual(R.durationSubScore(tstSeconds: 4 * 3600, needHours: 8), 0)
        XCTAssertEqual(R.durationSubScore(tstSeconds: 8 * 3600, needHours: 8), 1)
        XCTAssertEqual(R.efficiencySubScore(0.75), 0)
        XCTAssertEqual(R.efficiencySubScore(0.92), 1, accuracy: 1e-9)
        XCTAssertEqual(R.restorativeSubScore(tstSeconds: 3600, restorativeSeconds: 720, deepSeconds: nil), 0,
                       accuracy: 1e-9)
    }

    func testBreakdownSumsToScore() {
        let tst = 6.8 * 3600
        let b = R.breakdown(tstSeconds: tst, efficiency: 0.87, restorativeSeconds: tst * 0.38,
                            needHours: 8.2, consistency: 0.55, deepSeconds: tst * 0.11)
        let sum = b.factors.reduce(0) { $0 + $1.points }
        XCTAssertEqual(sum, b.total, accuracy: 0.01)
        XCTAssertEqual(b.factors.map(\.maxPoints).reduce(0, +), 100, accuracy: 1e-9)
        XCTAssertEqual(b.total, R.composite(tstSeconds: tst, inBedSeconds: tst / 0.87, efficiency: 0.87,
                                            restorativeSeconds: tst * 0.38, needHours: 8.2,
                                            consistency: 0.55, deepSeconds: tst * 0.11))
        XCTAssertEqual(b.factors.map(\.kind), R.Factor.Kind.allCases)
    }

    func testLowDeepCostsRestorativePoints() {
        let withDeep = score(hours: 8, eff: 0.92, restorative: 0.45, deep: 0.15)
        let noDeep = score(hours: 8, eff: 0.92, restorative: 0.45, deep: 0.01)
        XCTAssertGreaterThan(withDeep - noDeep, 8)
    }
}

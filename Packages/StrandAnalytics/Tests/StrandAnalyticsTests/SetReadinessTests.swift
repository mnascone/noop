import XCTest
@testable import StrandAnalytics

final class SetReadinessTests: XCTestCase {
    func testAutoThresholdsFollowSetPeakAndHrv() {
        let c = SetReadiness.Config()
        // Rise of 100 above resting 60. Baseline HRV leaves 45% of it: ready at 105, almost at 125.
        let base = SetReadiness.thresholds(config: c, restingBpm: 60, setPeakBpm: 160, age: 30, hrvRatio: 1)
        XCTAssertEqual(base.greenBpm, 105)
        XCTAssertEqual(base.yellowBpm, 125)
        // Suppressed HRV asks for more recovery: a lower ready heart rate.
        let low = SetReadiness.thresholds(config: c, restingBpm: 60, setPeakBpm: 160, age: 30, hrvRatio: 0.6)
        XCTAssertEqual(low.greenBpm, 92)
        let high = SetReadiness.thresholds(config: c, restingBpm: 60, setPeakBpm: 160, age: 30, hrvRatio: 1.4)
        XCTAssertEqual(high.greenBpm, 115)
        XCTAssertLessThan(low.greenBpm, base.greenBpm)
        XCTAssertGreaterThan(high.greenBpm, base.greenBpm)
    }

    func testMinimumRestCapsAtYellow() {
        let c = SetReadiness.Config(minRestS: 60, targetRestS: 120)
        let early = SetReadiness.read(config: c, currentBpm: 95, restS: 30, restingBpm: 60, setPeakBpm: 160,
                                      age: 30, hrvRatio: 1)
        XCTAssertEqual(early.light, .yellow)
        XCTAssertEqual(early.restLeftS, 90)
        let later = SetReadiness.read(config: c, currentBpm: 95, restS: 70, restingBpm: 60, setPeakBpm: 160,
                                      age: 30, hrvRatio: 1)
        XCTAssertEqual(later.light, .green)
        XCTAssertEqual(later.recovered ?? 0, 0.65, accuracy: 0.001)
        let hot = SetReadiness.read(config: c, currentBpm: 140, restS: 70, restingBpm: 60, setPeakBpm: 160,
                                    age: 30, hrvRatio: 1)
        XCTAssertEqual(hot.light, .red)
    }

    func testCustomModeUsesFixedHeartRates() {
        let c = SetReadiness.Config(auto: false, greenBpm: 100, yellowBpm: 115, minRestS: 0)
        XCTAssertEqual(SetReadiness.read(config: c, currentBpm: 100, restS: 90, restingBpm: 55, setPeakBpm: nil,
                                         age: nil, hrvRatio: nil).light, .green)
        XCTAssertEqual(SetReadiness.read(config: c, currentBpm: 110, restS: 90, restingBpm: 55, setPeakBpm: nil,
                                         age: nil, hrvRatio: nil).light, .yellow)
        XCTAssertEqual(SetReadiness.read(config: c, currentBpm: 116, restS: 90, restingBpm: 55, setPeakBpm: nil,
                                         age: nil, hrvRatio: nil).light, .red)
    }

    func testAssumedPeakWithoutASetPeak() {
        // Age 30: max 187, resting 60, 75% of reserve = 155.
        XCTAssertEqual(SetReadiness.assumedPeak(restingBpm: 60, age: 30), 155)
    }
}

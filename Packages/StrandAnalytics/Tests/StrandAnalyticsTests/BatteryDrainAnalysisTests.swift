import XCTest
@testable import StrandAnalytics

final class BatteryDrainAnalysisTests: XCTestCase {
    typealias S = BatteryDrainAnalysis.Sample

    private func day(_ ts: Double) -> String { "d\(Int(ts / 86_400))" }

    func testFeatureCostIsRateOnMinusRateOff() {
        let live = BatteryDrainAnalysis.Feature.liveHeartRate.rawValue
        var samples: [S] = []
        var pct = 100.0
        // 4 hours at 1%/h with nothing on, then 4 hours at 3%/h with live heart rate on.
        for h in 0..<4 { samples.append(S(ts: Double(h) * 3600, pct: pct, charging: false, features: 0)); pct -= 1 }
        for h in 4..<9 { samples.append(S(ts: Double(h) * 3600, pct: pct, charging: false, features: live)); pct -= 3 }
        let r = BatteryDrainAnalysis.analyze(samples, dayOf: day)
        let c = try! XCTUnwrap(r.costs.first { $0.feature == .liveHeartRate })
        XCTAssertEqual(c.rateOff, 1, accuracy: 1e-9)
        XCTAssertEqual(c.rateOn, 3, accuracy: 1e-9)
        XCTAssertEqual(c.extraPerHour, 2, accuracy: 1e-9)
        XCTAssertEqual(r.hoursMeasured, 8, accuracy: 1e-9)
        XCTAssertEqual(r.ratePerHour ?? 0, 2, accuracy: 1e-9)
        // A feature never on has no comparison.
        XCTAssertNil(r.costs.first { $0.feature == .rawCapture })
    }

    func testChargingRisesAndLongGapsAreSkipped() {
        let samples = [
            S(ts: 0, pct: 50, charging: false, features: 0),
            S(ts: 3600, pct: 49, charging: false, features: 0),
            S(ts: 7200, pct: 70, charging: true, features: 0),
            S(ts: 10_800, pct: 90, charging: false, features: 0),
            S(ts: 10_800 + 7 * 3600, pct: 80, charging: false, features: 0),
            S(ts: 10_800 + 8 * 3600, pct: 79, charging: false, features: 0),
        ]
        let r = BatteryDrainAnalysis.analyze(samples, dayOf: day)
        XCTAssertEqual(r.hoursMeasured, 2, accuracy: 1e-9)
        XCTAssertEqual(r.ratePerHour ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(r.dailyUse.map(\.pct).reduce(0, +), 2, accuracy: 1e-9)
    }
}

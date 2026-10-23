import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class BandWakePromotionTests: XCTestCase {

    typealias P = BandWakePromotion
    let start = 1_700_000_000
    let hours = 8

    private var end: Int { start + hours * 3600 }

    /// A whole night staged as light sleep.
    private var allLight: [StageSegment] { [StageSegment(start: start, end: end, stage: "light")] }

    /// Band samples every 10 s: `state(t)` for each.
    private func band(_ state: (Int) -> Int, from: Int? = nil, to: Int? = nil) -> [(ts: Int, state: Int)] {
        stride(from: from ?? start, to: to ?? end, by: 10).map { ($0, state($0)) }
    }

    private func hr(_ bpm: (Int) -> Int) -> [HRSample] {
        stride(from: start, to: end, by: 5).map { HRSample(ts: $0, bpm: bpm($0)) }
    }

    private func wakeSeconds(_ s: [StageSegment]) -> Int {
        s.filter { SleepStageVocabulary.isWake($0.stage) }.reduce(0) { $0 + ($1.end - $1.start) }
    }

    func testLongBandWakeRunBecomesWake() {
        // Strap says awake 02:00-02:20 into the night (1h..1h20m).
        let b = band { t in (t - self.start) >= 3600 && (t - self.start) < 4800 ? P.bandWake : P.bandAsleep }
        let r = P.apply(allLight, start: start, end: end, band: b, hr: [], includeQuiet: false)
        XCTAssertEqual(r.strongSeconds, 1200, accuracy: 30)
        XCTAssertEqual(wakeSeconds(r.stages), 1200, accuracy: 30)
        XCTAssertFalse(r.declined)
    }

    func testBandUpCountsLikeWake() {
        let b = band { t in (t - self.start) >= 7200 && (t - self.start) < 7500 ? P.bandUp : P.bandAsleep }
        let r = P.apply(allLight, start: start, end: end, band: b, hr: [], includeQuiet: false)
        XCTAssertEqual(r.strongSeconds, 300, accuracy: 30)
    }

    func testShortBlipIsIgnored() {
        // 2 minutes of band wake: a turn-over, under the 3 minute rule.
        let b = band { t in (t - self.start) >= 3600 && (t - self.start) < 3720 ? P.bandWake : P.bandAsleep }
        let r = P.apply(allLight, start: start, end: end, band: b, hr: [], includeQuiet: false)
        XCTAssertEqual(r.strongSeconds, 0)
        XCTAssertEqual(r.stages, allLight)
    }

    func testNeverTurnsWakeIntoSleep() {
        let staged = [StageSegment(start: start, end: start + 1800, stage: "wake"),
                      StageSegment(start: start + 1800, end: end, stage: "light")]
        let b = band { _ in P.bandAsleep }
        let r = P.apply(staged, start: start, end: end, band: b, hr: [], includeQuiet: true)
        XCTAssertEqual(r.stages, staged)
    }

    func testStaleBandIsNotCarriedAcrossAGap() {
        // One wake sample, then silence for the rest of the night: must not paint the night awake.
        let b: [(ts: Int, state: Int)] = [(start + 3600, P.bandWake)]
        let r = P.apply(allLight, start: start, end: end, band: b, hr: [], includeQuiet: false)
        XCTAssertEqual(r.strongSeconds, 0)
    }

    func testSafetyCapDeclinesAMostlyAwakeBand() {
        let b = band { _ in P.bandWake }
        let r = P.apply(allLight, start: start, end: end, band: b, hr: [], includeQuiet: false)
        XCTAssertTrue(r.declined)
        XCTAssertEqual(r.stages, allLight)
    }

    func testQuietRuleNeedsRaisedHeartRateAndIsOptIn() {
        // 15 min the strap calls "still" with HR 64 against a sleeping 55.
        let inRun: (Int) -> Bool = { t in (t - self.start) >= 10_800 && (t - self.start) < 11_700 }
        let b = band { t in inRun(t) ? P.bandStill : P.bandAsleep }
        let h = hr { t in inRun(t) ? 64 : 55 }
        let off = P.apply(allLight, start: start, end: end, band: b, hr: h, includeQuiet: false)
        XCTAssertEqual(off.quietSeconds, 0)
        XCTAssertEqual(off.quietCandidateSeconds, 900, accuracy: 30, "traced even when off")
        XCTAssertEqual(off.stages, allLight)
        let on = P.apply(allLight, start: start, end: end, band: b, hr: h, includeQuiet: true)
        XCTAssertEqual(on.quietSeconds, 900, accuracy: 30)
        XCTAssertEqual(wakeSeconds(on.stages), 900, accuracy: 30)
    }

    func testQuietRuleIgnoresStillWithSleepingHeartRate() {
        let inRun: (Int) -> Bool = { t in (t - self.start) >= 10_800 && (t - self.start) < 11_700 }
        let b = band { t in inRun(t) ? P.bandStill : P.bandAsleep }
        let h = hr { _ in 55 }
        let r = P.apply(allLight, start: start, end: end, band: b, hr: h, includeQuiet: true)
        XCTAssertEqual(r.quietCandidateSeconds, 0)
    }

    func testRecoversSeveralDifferentAwakenings() {
        // 5, 12 and 25 minutes awake at different points: each comes back at its own length.
        let spans = [(3600, 300), (10_000, 720), (20_000, 1500)]
        let b = band { t in
            let o = t - self.start
            return spans.contains { o >= $0.0 && o < $0.0 + $0.1 } ? P.bandWake : P.bandAsleep
        }
        let r = P.apply(allLight, start: start, end: end, band: b, hr: [], includeQuiet: false)
        XCTAssertEqual(r.strongSeconds, 2520, accuracy: 90)
        let wakeSegs = r.stages.filter { $0.stage == "wake" }.map { $0.end - $0.start }
        XCTAssertEqual(wakeSegs.count, 3)
        for (got, want) in zip(wakeSegs, spans.map(\.1)) { XCTAssertEqual(got, want, accuracy: 30) }
    }

    func testStagesStillTileTheNight() {
        let b = band { t in (t - self.start) >= 3600 && (t - self.start) < 4800 ? P.bandWake : P.bandAsleep }
        let r = P.apply(allLight, start: start, end: end, band: b, hr: [], includeQuiet: false)
        XCTAssertEqual(r.stages.first?.start, start)
        XCTAssertEqual(r.stages.last?.end, end)
        for (a, b) in zip(r.stages, r.stages.dropFirst()) { XCTAssertEqual(a.end, b.start) }
    }

    func testNoBandIsANoOp() {
        let r = P.apply(allLight, start: start, end: end, band: [], hr: [], includeQuiet: true)
        XCTAssertEqual(r.stages, allLight)
    }
}

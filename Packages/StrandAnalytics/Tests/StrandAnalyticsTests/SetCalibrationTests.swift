import XCTest
@testable import StrandAnalytics

final class SetCalibrationTests: XCTestCase {
    typealias C = SetCalibration

    private struct Noise {
        var state: UInt64 = 0x2545F4914F6CDD1D
        mutating func next(_ amp: Double) -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Double(state >> 11) / Double(1 << 53) * 2 - 1) * amp
        }
    }

    /// A session: rest at 95 bpm, each set climbs 30 bpm and decays after. `bumps` are stretches where
    /// heart rate rises without effort (talking, walking to the rack): no HRV drop. Real sets pull the
    /// beat-to-beat jitter down from 45 ms to 12 ms.
    private func session(works: [Int], rests: [Int], bumps: [(at: Int, len: Int)] = [],
                         t0: Int = 10_000) -> (hr: [C.HRSampleTS], beats: [C.Beat], truth: [C.Span]) {
        var noise = Noise()
        var hr: [C.HRSampleTS] = [], beats: [C.Beat] = [], truth: [C.Span] = []
        var level = 95.0
        var t = t0
        var working = Set<Int>()
        func add(_ v: Double, work: Bool) {
            let bpm = Int((v + noise.next(2)).rounded())
            hr.append(.init(ts: t, bpm: bpm))
            let jitter = work ? 12.0 : 45.0
            beats.append(.init(ts: t, ms: Int(60_000 / v + (t % 2 == 0 ? jitter : -jitter))))
            t += 1
        }
        for _ in 0..<120 { add(95, work: false) }
        for (i, w) in works.enumerated() {
            let start = t, from = level
            for k in 0..<w { level = from + 30 * Double(k) / Double(w + 8); add(level, work: true); working.insert(t) }
            truth.append(.init(start: start, end: t))
            for k in 0..<8 { level = from + 30 * Double(w + k) / Double(w + 8); add(level, work: true) }
            let peak = level
            let rest = i < rests.count ? rests[i] : 150
            for k in 0..<max(0, rest - 8) {
                level = 95 + (peak - 95) * exp(-Double(k) / 25)
                let offset = t - t0
                let bump = bumps.first { offset >= $0.at && offset < $0.at + $0.len } != nil
                add(level + (bump ? 16 : 0), work: false)
            }
        }
        return (hr, beats, truth)
    }

    private func spans(_ v: [WorkRestSegmenter.Interval]) -> [C.Span] { v.map { .init(start: $0.startTs, end: $0.endTs) } }

    func testErrorsPairSetsByOverlap() {
        let truth = [C.Span(start: 0, end: 40), C.Span(start: 100, end: 140)]
        XCTAssertEqual(C.errors(truth, truth).count, 0)
        XCTAssertEqual(C.errors([C.Span(start: 0, end: 140)], truth).count, 1, "two sets read as one")
        XCTAssertEqual(C.errors(truth + [C.Span(start: 200, end: 230)], truth).count, 1, "one extra")
    }

    /// You do short rests the defaults read as one long set: the fit learns a shorter rest.
    func testLearnsShortRestsFromCorrections() {
        let a = session(works: [30, 30, 30, 30], rests: [30, 30, 30])
        let b = session(works: [35, 30, 35], rests: [28, 32], t0: 50_000)
        let examples = [a, b].map { C.Example(hr: $0.hr, beats: $0.beats, truth: $0.truth) }
        let fit = C.fit(examples, mode: .lifting)!
        XCTAssertLessThan(fit.tuning.minRestS, C.Tuning.defaults(.lifting).minRestS)
        XCTAssertLessThan(fit.errorsAfter, fit.errorsBefore)
        XCTAssertEqual(fit.exactAfter, 2)
    }

    /// Heart rate bumps between sets with no HRV drop read as extra sets; the fit turns the HRV check on.
    func testHRVCheckDropsBumpsThatAreNotEffort() {
        let bumps = [(at: 230, len: 40), (at: 450, len: 40)]
        let a = session(works: [40, 40, 40], rests: [180, 180], bumps: bumps)
        let ex = C.Example(hr: a.hr, beats: a.beats, truth: a.truth)
        let fit = C.fit([ex], mode: .lifting)!
        XCTAssertGreaterThan(fit.errorsBefore, 0, "the bumps fool the defaults")
        XCTAssertEqual(fit.errorsAfter, 0)
        XCTAssertGreaterThan(fit.tuning.hrvDrop, 0)
        let det = spans(C.detect(hr: a.hr, beats: a.beats, mode: .lifting, tuning: fit.tuning))
        XCTAssertEqual(det.count, 3)
    }

    func testNothingToFitWithoutCorrections() {
        XCTAssertNil(C.fit([], mode: .lifting))
    }
}

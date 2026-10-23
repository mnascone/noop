import XCTest
@testable import StrandAnalytics

final class WorkRestSegmenterTests: XCTestCase {

    /// Deterministic noise in [-amp, amp].
    private struct Noise {
        var state: UInt64 = 0x9E3779B97F4A7C15
        mutating func next(_ amp: Double) -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let u = Double(state >> 11) / Double(1 << 53)
            return (u * 2 - 1) * amp
        }
    }

    /// Synthetic session: HR climbs linearly during each work bout and for `lagS` after it, then decays
    /// exponentially toward `restBpm`. Returns per-second samples plus the true bout spans.
    private func session(restBpm: Double, riseBpm: Double, works: [Int], rests: [Int],
                         lagS: Int = 8, tau: Double = 30, noise amp: Double = 2,
                         t0: Int = 1_000) -> (samples: [(Int, Int)], truth: [(Int, Int)]) {
        var noise = Noise()
        var out: [(Int, Int)] = []
        var truth: [(Int, Int)] = []
        var t = t0
        // 2 min warm-up at rest.
        for _ in 0..<120 { out.append((t, Int((restBpm + noise.next(amp)).rounded()))); t += 1 }
        var level = restBpm
        for (i, w) in works.enumerated() {
            let start = t
            let startLevel = level
            let climbS = w + lagS
            for k in 0..<w {
                level = startLevel + riseBpm * Double(k) / Double(climbS)
                out.append((t, Int((level + noise.next(amp)).rounded()))); t += 1
            }
            truth.append((start, t))
            for k in 0..<lagS {
                level = startLevel + riseBpm * Double(w + k) / Double(climbS)
                out.append((t, Int((level + noise.next(amp)).rounded()))); t += 1
            }
            let peakLevel = level
            let rest = i < rests.count ? rests[i] : 180
            for k in 0..<max(0, rest - lagS) {
                level = restBpm + (peakLevel - restBpm) * exp(-Double(k) / tau)
                out.append((t, Int((level + noise.next(amp)).rounded()))); t += 1
            }
        }
        return (out, truth)
    }

    private func run(_ mode: WorkRestSegmenter.Mode, _ samples: [(Int, Int)]) -> WorkRestSegmenter {
        var s = WorkRestSegmenter(mode: mode)
        for (ts, bpm) in samples { s.ingest(ts: ts, bpm: bpm) }
        return s
    }

    func testLiftingRecoversEachSetAndVaryingRests() {
        let rests = [60, 90, 120, 75, 150]
        let (samples, truth) = session(restBpm: 95, riseBpm: 30, works: [40, 35, 45, 40, 30, 40], rests: rests)
        let seg = run(.lifting, samples)
        XCTAssertEqual(seg.intervals.count, 6)
        // Recovered rests track the injected ones (several different values, not one lucky match).
        let detected = seg.rests
        XCTAssertEqual(detected.count, rests.count)
        for (d, r) in zip(detected, rests) {
            XCTAssertEqual(Double(d), Double(r), accuracy: 22, "detected \(d) vs true \(r)")
        }
        // Ordering of rest lengths is preserved.
        XCTAssertEqual(detected.firstIndex(of: detected.max()!), rests.firstIndex(of: 150))
        // Set starts land near the true starts.
        for (iv, t) in zip(seg.intervals, truth) {
            XCTAssertEqual(Double(iv.startTs), Double(t.0), accuracy: 15)
        }
    }

    func testShortRestMergesTwoSets() {
        // 12 s between sets: HR has no time to fall, so the two count as one.
        let (samples, _) = session(restBpm: 95, riseBpm: 30, works: [40, 40], rests: [20], lagS: 8)
        let seg = run(.lifting, samples)
        XCTAssertEqual(seg.intervals.count, 1)
    }

    func testFlatHeartRateCountsNothing() {
        var noise = Noise()
        let samples = (0..<1200).map { (1_000 + $0, Int((100 + noise.next(3)).rounded())) }
        let seg = run(.lifting, samples)
        XCTAssertEqual(seg.intervals.count, 0)
        XCTAssertEqual(seg.phase, .warmingUp)
    }

    func testAssaultBikeIntervals() {
        let works = Array(repeating: 20, count: 8)
        let rests = Array(repeating: 40, count: 7)
        let (samples, _) = session(restBpm: 135, riseBpm: 30, works: works, rests: rests,
                                   lagS: 5, tau: 18, noise: 2)
        let seg = run(.assaultBike, samples)
        XCTAssertEqual(seg.intervals.count, 8)
        let avg = seg.summary(now: samples.last!.0).avgRestS ?? 0
        XCTAssertEqual(Double(avg), 40, accuracy: 12)
    }

    func testSprintsWithLongRecoveries() {
        let (samples, _) = session(restBpm: 110, riseBpm: 45, works: [12, 12, 12, 12, 12],
                                   rests: [120, 150, 180, 120], lagS: 10, tau: 35)
        let seg = run(.sprints, samples)
        XCTAssertEqual(seg.intervals.count, 5)
        XCTAssertEqual(seg.rests.count, 4)
    }

    func testLiveSummaryWhileResting() {
        let (samples, _) = session(restBpm: 95, riseBpm: 30, works: [40, 40], rests: [90])
        var seg = WorkRestSegmenter(mode: .lifting)
        for (ts, bpm) in samples { seg.ingest(ts: ts, bpm: bpm) }
        guard case .resting(let since) = seg.phase else { return XCTFail("expected resting") }
        let sum = seg.summary(now: since + 45)
        XCTAssertEqual(sum.currentRestS, 45)
        XCTAssertNil(sum.currentWorkS)
        XCTAssertEqual(sum.count, 2)
        XCTAssertNotNil(sum.lastRestS)
    }

    func testSensitivityScalesThresholds() {
        let base = WorkRestSegmenter.params(for: .lifting)
        let high = WorkRestSegmenter.params(for: .lifting, sensitivity: 2)
        XCTAssertEqual(high.riseBPM, base.riseBPM / 2, accuracy: 0.001)
        let clamped = WorkRestSegmenter.params(for: .lifting, sensitivity: 10)
        XCTAssertEqual(clamped, high)
    }

    func testIgnoresOutOfOrderAndImplausibleSamples() {
        var seg = WorkRestSegmenter(mode: .lifting)
        seg.ingest(ts: 10, bpm: 100)
        seg.ingest(ts: 9, bpm: 180)
        seg.ingest(ts: 11, bpm: 0)
        seg.ingest(ts: 12, bpm: 300)
        XCTAssertEqual(seg.phase, .warmingUp)
        XCTAssertEqual(seg.intervals.count, 0)
    }
}

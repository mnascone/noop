import XCTest
@testable import StrandAnalytics

final class RepCounterTests: XCTestCase {
    /// A deterministic pseudo-random source so the noise is the same every run.
    private struct LCG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53) - 0.5
        }
    }

    /// One set: `reps` sinusoidal swings of `period` seconds and `amp` g along a tilted axis, the wrist
    /// rotating while it moves. Then `rest` seconds of near-stillness.
    private func session(_ sets: [(reps: Int, period: Double, amp: Double, axis: (Double, Double, Double))],
                         rest: Double = 60) -> [RepCounter.Sample] {
        var out: [RepCounter.Sample] = []
        var t = 0.0
        var rng = LCG(state: 42)
        let dt = 0.01
        func still(_ secs: Double) {
            for _ in 0..<Int(secs / dt) {
                out.append(.init(t: t, ax: 0.02 * rng.next(), ay: 0.02 * rng.next(), az: 1 + 0.02 * rng.next(),
                                 gx: 3 * rng.next(), gy: 3 * rng.next(), gz: 3 * rng.next()))
                t += dt
            }
        }
        still(20)
        for s in sets {
            let n = sqrt(s.axis.0 * s.axis.0 + s.axis.1 * s.axis.1 + s.axis.2 * s.axis.2)
            let ax = (s.axis.0 / n, s.axis.1 / n, s.axis.2 / n)
            let dur = Double(s.reps) * s.period
            var u = 0.0
            while u < dur {
                let w = 2 * Double.pi / s.period
                let m = s.amp * sin(w * u)
                let rot = 120 * abs(cos(w * u)) + 20
                out.append(.init(t: t, ax: ax.0 * m + 0.03 * rng.next(), ay: ax.1 * m + 0.03 * rng.next(),
                                 az: 1 + ax.2 * m + 0.03 * rng.next(),
                                 gx: rot * 0.6 + 5 * rng.next(), gy: rot * 0.6 + 5 * rng.next(), gz: rot * 0.5))
                t += dt
                u += dt
            }
            still(rest)
        }
        return out
    }

    private func run(_ samples: [RepCounter.Sample]) -> [RepCounter.RepSet] {
        var c = RepCounter()
        // Feed one second at a time, as the strap sends it.
        var i = 0
        while i < samples.count {
            c.feed(Array(samples[i..<min(samples.count, i + 100)]))
            i += 100
        }
        c.finish()
        return c.sets
    }

    /// Three sets with different rep counts, tempos, loads and strap orientations: every count is
    /// recovered, not just one.
    func testRecoversEachSetsRepCount() {
        let sets = run(session([
            (reps: 10, period: 2.0, amp: 0.35, axis: (0, 0, 1)),
            (reps: 8, period: 3.0, amp: 0.6, axis: (1, 0.3, 0.2)),
            (reps: 12, period: 1.5, amp: 0.25, axis: (0.2, 1, 0.5)),
        ]))
        XCTAssertEqual(sets.count, 3)
        let reps = sets.map(\.reps)
        for (got, want) in zip(reps, [10, 8, 12]) {
            XCTAssertLessThanOrEqual(abs(got - want), 1, "got \(reps)")
        }
        XCTAssertEqual(sets[1].tempoS ?? 0, 3.0, accuracy: 0.4)
    }

    func testStillnessMakesNoSets() {
        let sets = run(session([], rest: 0))
        XCTAssertTrue(sets.isEmpty)
    }

    /// A short fidget (a couple of seconds of wrist rotation) is not a set.
    func testShortFidgetIsIgnored() {
        let sets = run(session([(reps: 1, period: 2.0, amp: 0.3, axis: (0, 0, 1))]))
        XCTAssertTrue(sets.isEmpty)
    }

    /// Irregular motion (racking weights, walking between machines, adjusting a seat): swings of mixed
    /// lengths and sizes with the wrist rotating. Not a set.
    func testIrregularMotionIsNotASet() {
        var out: [RepCounter.Sample] = []
        var t = 0.0
        var rng = LCG(state: 7)
        let dt = 0.01
        for _ in 0..<2000 {
            out.append(.init(t: t, ax: 0.02 * rng.next(), ay: 0.02 * rng.next(), az: 1, gx: 2, gy: 2, gz: 2))
            t += dt
        }
        // Single swings with uneven pauses between them (the wrist still turning a little), at mixed sizes.
        let pauses = [0.2, 4.5, 0.4, 5.0, 1.8, 0.3, 4.8, 0.5, 3.9, 0.2]
        let amps = [0.5, 0.15, 0.6, 0.2, 0.45, 0.1, 0.55, 0.25, 0.4, 0.12]
        for (pause, a) in zip(pauses, amps) {
            var u = 0.0
            while u < 1.0 {
                let m = a * sin(2 * Double.pi * u)
                out.append(.init(t: t, ax: m + 0.03 * rng.next(), ay: 0.5 * m, az: 1 + 0.03 * rng.next(),
                                 gx: 80 + 10 * rng.next(), gy: 60, gz: 40))
                t += dt
                u += dt
            }
            var q = 0.0
            while q < pause {
                out.append(.init(t: t, ax: 0.02 * rng.next(), ay: 0.02 * rng.next(), az: 1,
                                 gx: 30 + 5 * rng.next(), gy: 20, gz: 10))
                t += dt
                q += dt
            }
        }
        for _ in 0..<3000 {
            out.append(.init(t: t, ax: 0.02 * rng.next(), ay: 0.02 * rng.next(), az: 1, gx: 2, gy: 2, gz: 2))
            t += dt
        }
        let sets = run(out)
        XCTAssertTrue(sets.allSatisfy { $0.reps < RepCounter.minReps }, "got \(sets.map(\.reps))")
        XCTAssertTrue(sets.isEmpty)
    }

    /// The rhythm filter keeps the steady run and drops the odd swings around it.
    func testRhythmicRunIgnoresOddSwings() {
        // Fidget, fidget, then 8 reps at 2 s, then a racking swing 5 s later.
        var reps: [(t: Double, amp: Double)] = [(0, 0.3), (0.9, 0.1)]
        for i in 0..<8 { reps.append((5 + Double(i) * 2.0, 0.5)) }
        reps.append((24, 0.2))
        let r = RepCounter.rhythmicRun(reps)
        XCTAssertEqual(r.reps, 8)
        XCTAssertEqual(r.tempo ?? 0, 2.0, accuracy: 0.01)
        XCTAssertEqual(r.end ?? 0, 19, accuracy: 0.01)
    }

    /// A press straight up and down reads as vertical; a row across the body as horizontal.
    func testMovementLabelFollowsGravity() {
        let up = run(session([(reps: 8, period: 2.0, amp: 0.4, axis: (0, 0, 1))]))
        XCTAssertEqual(up.first?.movement, .vertical)
        let across = run(session([(reps: 8, period: 2.0, amp: 0.4, axis: (1, 0, 0))]))
        XCTAssertEqual(across.first?.movement, .horizontal)
    }

    /// The analysis behind a set: counted swings match the set's reps, and odd ones are listed apart.
    func testAnalysisSeparatesCountedFromRejected() {
        var c = RepCounter()
        let samples = session([(reps: 10, period: 2.0, amp: 0.35, axis: (0, 0, 1))])
        var i = 0
        while i < samples.count { c.feed(Array(samples[i..<min(samples.count, i + 100)])); i += 100 }
        c.finish()
        let a = try! XCTUnwrap(c.currentAnalysis)
        XCTAssertEqual(a.counted.count, c.sets.first?.reps)
        XCTAssertFalse(a.trace.isEmpty)
    }
}

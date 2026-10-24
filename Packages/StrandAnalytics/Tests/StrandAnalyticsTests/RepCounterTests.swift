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
}

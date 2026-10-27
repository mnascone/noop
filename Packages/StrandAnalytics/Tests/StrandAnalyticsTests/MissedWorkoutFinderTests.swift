import XCTest
@testable import StrandAnalytics

final class MissedWorkoutFinderTests: XCTestCase {
    private typealias F = MissedWorkoutFinder

    private func minutes(_ spec: [(from: Int, to: Int, steps: Int, run: Int)]) -> [F.StepMinute] {
        var out: [F.StepMinute] = []
        for s in spec {
            for m in stride(from: s.from, to: s.to, by: 60) { out.append(.init(start: m, steps: s.steps, runSteps: s.run)) }
        }
        return out
    }

    private func flatHR(_ from: Int, _ to: Int, _ bpm: Int) -> [F.HRPoint] {
        stride(from: from, to: to, by: 5).map { F.HRPoint(ts: $0, bpm: bpm) }
    }

    /// A 20-minute walk with no phone: found from the strap's steps, start and end on the walking minutes.
    func testWalkFromStrapSteps() {
        let steps = minutes([(0, 600, 10, 0), (600, 1800, 105, 0), (1800, 3600, 5, 0)])
        let f = F.find(steps: steps, hr: flatHR(0, 3600, 85), motion: [], restingBpm: 58, exclude: [], dataEnd: 3600)
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f.first?.kind, .walk)
        XCTAssertEqual(f.first?.start, 600)
        XCTAssertEqual(f.first?.end, 1800)
    }

    /// Short walks around the office, and pottering, aren't workouts. Pottering doesn't join two walks.
    func testShortWalksAndPotteringAreNot() {
        let steps = minutes([(0, 180, 100, 0), (180, 3000, 35, 0), (3000, 3180, 100, 0), (3180, 4000, 0, 0)])
        XCTAssertTrue(F.find(steps: steps, hr: [], motion: [], restingBpm: 58, exclude: [], dataEnd: 4000).isEmpty)
    }

    /// A walk under 15 minutes isn't added afterwards.
    func testWalkUnderFifteenMinutesIsNot() {
        let steps = minutes([(0, 840, 110, 0), (840, 1500, 0, 0)])
        XCTAssertTrue(F.find(steps: steps, hr: [], motion: [], restingBpm: 58, exclude: [], dataEnd: 1500).isEmpty)
        let long = minutes([(0, 900, 110, 0), (900, 1500, 0, 0)])
        XCTAssertEqual(F.find(steps: long, hr: [], motion: [], restingBpm: 58, exclude: [], dataEnd: 1500).count, 1)
    }

    /// A walk still going where the data stops isn't over yet.
    func testOpenWalkWaits() {
        let steps = minutes([(0, 1200, 100, 0)])
        XCTAssertTrue(F.find(steps: steps, hr: [], motion: [], restingBpm: 58, exclude: [], dataEnd: 1200).isEmpty)
        XCTAssertEqual(F.find(steps: steps + minutes([(1200, 1500, 0, 0)]), hr: [], motion: [], restingBpm: 58,
                              exclude: [], dataEnd: 1500).count, 1)
    }

    /// The strap's gait class calling it running makes it a run, and a run counts from 3 minutes.
    func testRun() {
        let steps = minutes([(0, 1500, 160, 150), (1500, 2000, 0, 0)])
        XCTAssertEqual(F.find(steps: steps, hr: [], motion: [], restingBpm: 58, exclude: [], dataEnd: 2000).first?.kind, .run)
        let short = minutes([(0, 240, 165, 160), (240, 800, 0, 0)])
        XCTAssertEqual(F.find(steps: short, hr: [], motion: [], restingBpm: 58, exclude: [], dataEnd: 800).first?.kind, .run)
    }

    /// A lift: sets lifting heart rate 25-40 over resting, rests between them, the wrist moving.
    func testLiftFromHeartRateAndMotion() {
        var hr: [F.HRPoint] = []
        var motion: [F.MotionPoint] = []
        for t in stride(from: 0, to: 7200, by: 5) {
            let inLift = (1800..<5400).contains(t)
            let inSet = inLift && (t - 1800) % 240 < 150
            hr.append(.init(ts: t, bpm: inLift ? (inSet ? 100 : 75) : 62))
            motion.append(.init(ts: t, intensity: inSet ? 0.3 : 0.02))
        }
        let f = F.find(steps: [], hr: hr, motion: motion, restingBpm: 60, exclude: [], dataEnd: 7200)
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f.first?.kind, .effort)
        XCTAssertEqual(Double(f.first?.start ?? 0), 1800, accuracy: 10)
        XCTAssertEqual(Double(f.first?.end ?? 0), 5400, accuracy: 120)
    }

    /// A game with an intermission is one workout.
    func testGameWithIntermissionIsOne() {
        var hr = flatHR(0, 600, 65)
        hr += flatHR(600, 2400, 140)      // first period
        hr += flatHR(2400, 3300, 75)      // 15-minute intermission
        hr += flatHR(3300, 5100, 140)     // second period
        hr += flatHR(5100, 7000, 65)
        let motion = stride(from: 0, to: 7000, by: 5).map { F.MotionPoint(ts: $0, intensity: 0.2) }
        let f = F.find(steps: [], hr: hr, motion: motion, restingBpm: 60, exclude: [], dataEnd: 7000)
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f.first.map { $0.end - $0.start } ?? 0, 4495, accuracy: 10)
    }

    /// Sitting still with a fast heart rate is stress, not a workout.
    func testStillHighHeartRateIsNot() {
        let hr = flatHR(0, 600, 65) + flatHR(600, 2400, 95) + flatHR(2400, 4000, 65)
        let motion = stride(from: 0, to: 4000, by: 5).map { F.MotionPoint(ts: $0, intensity: 0.01) }
        XCTAssertTrue(F.find(steps: [], hr: hr, motion: motion, restingBpm: 60, exclude: [], dataEnd: 4000).isEmpty)
    }

    /// A brisk walk lifts heart rate too: it's the walk, not a second workout.
    func testBriskWalkIsAWalkOnly() {
        let steps = minutes([(0, 300, 0, 0), (300, 2100, 115, 0), (2100, 4000, 0, 0)])
        let hr = flatHR(0, 300, 65) + flatHR(300, 2100, 100) + flatHR(2100, 4000, 65)
        let motion = stride(from: 0, to: 4000, by: 5).map { F.MotionPoint(ts: $0, intensity: 0.2) }
        let f = F.find(steps: steps, hr: hr, motion: motion, restingBpm: 60, exclude: [], dataEnd: 4000)
        XCTAssertEqual(f.map(\.kind), [.walk])
    }

    /// Anything already logged, offered, or slept through is left alone.
    func testExcluded() {
        let steps = minutes([(600, 1800, 105, 0), (1800, 3000, 0, 0)])
        XCTAssertTrue(F.find(steps: steps, hr: [], motion: [], restingBpm: 58, exclude: [1000...1200], dataEnd: 3000).isEmpty)
    }
}

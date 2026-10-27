import XCTest
@testable import StrandAnalytics

/// The all-day stress level on simulated days: calm desk time, a tense stretch, a walk and its
/// aftermath, sleep, gaps, and stored readings that must read back unchanged.
final class StressLevelTests: XCTestCase {
    typealias L = StressLevel

    private let base = L.Baseline(calmHR: 62, typicalRMSSD: 40, morning: nil, source: "history")

    func testBandsAreGarmins() {
        XCTAssertEqual(L.Band(level: 0), .rest)
        XCTAssertEqual(L.Band(level: 25), .rest)
        XCTAssertEqual(L.Band(level: 26), .low)
        XCTAssertEqual(L.Band(level: 50), .low)
        XCTAssertEqual(L.Band(level: 51), .medium)
        XCTAssertEqual(L.Band(level: 75), .medium)
        XCTAssertEqual(L.Band(level: 76), .high)
        XCTAssertEqual(L.Band(level: 100), .high)
    }

    /// Calm floor reads rest; the validated margin over it reads High; below the floor reads lower.
    func testHeartRateAnchorsTheCurve() {
        XCTAssertEqual(L.level(meanHR: 62, rmssd: nil, baseline: base), 15)
        XCTAssertEqual(L.level(meanHR: 77, rmssd: nil, baseline: base), 66)
        XCTAssertEqual(L.Band(level: L.level(meanHR: 82, rmssd: nil, baseline: base)), .high, "about 20 over reads High")
        XCTAssertEqual(L.Band(level: L.level(meanHR: 72, rmssd: nil, baseline: base)), .low, "10 over is still Low")
        XCTAssertLessThan(L.level(meanHR: 55, rmssd: nil, baseline: base), 10)
        let typicalDesk = L.level(meanHR: 68, rmssd: nil, baseline: base)
        XCTAssertEqual(L.Band(level: typicalDesk), .low, "a few bpm over the floor is low stress, \(typicalDesk)")
    }

    /// Clean HRV adjusts the level, never overrides heart rate.
    func testHRVAdjustsWithinACap() {
        let plain = L.level(meanHR: 68, rmssd: nil, baseline: base)
        let suppressed = L.level(meanHR: 68, rmssd: 20, baseline: base)     // half of typical
        let high = L.level(meanHR: 68, rmssd: 80, baseline: base)           // double
        XCTAssertGreaterThan(suppressed, plain)
        XCTAssertLessThan(high, plain)
        // An implausibly low RMSSD (artifact) can't swing it past the cap.
        let artifact = L.level(meanHR: 68, rmssd: 1, baseline: base)
        let capped = 100 / (1 + exp(-(L.curveA * ((68 - 62) / 15 + L.maxHRVTerm) + L.curveB)))
        XCTAssertEqual(Double(artifact), capped.rounded(), accuracy: 1)
    }

    /// The morning factors tilt the day: a stressed morning reads a little higher, a recovered one lower.
    func testMorningFactorsShiftTheDay() {
        let stressed = L.Baseline(calmHR: 62, typicalRMSSD: 40, morning: 3, source: "history")
        let recovered = L.Baseline(calmHR: 62, typicalRMSSD: 40, morning: 0, source: "history")
        let n = L.level(meanHR: 68, rmssd: nil, baseline: base)
        XCTAssertGreaterThan(L.level(meanHR: 68, rmssd: nil, baseline: stressed), n)
        XCTAssertLessThan(L.level(meanHR: 68, rmssd: nil, baseline: recovered), n)
        XCTAssertLessThan(L.level(meanHR: 68, rmssd: nil, baseline: stressed) - n, 12, "a tilt, not a takeover")
    }

    func testNoisyBeatsGiveNoRMSSD() {
        let clean = (0..<80).map { 900 + ($0 % 2 == 0 ? 20 : -20) }
        XCTAssertNotNil(L.cleanRMSSD(clean))
        XCTAssertEqual(L.cleanRMSSD(clean)!, 40, accuracy: 0.5)
        let noisy = (0..<80).map { 900 + ($0 % 3 == 0 ? 450 : -300) }
        XCTAssertNil(L.cleanRMSSD(noisy))
        XCTAssertNil(L.cleanRMSSD(Array(clean.prefix(30))), "too few beats")
    }

    /// A day: sleep 0-2h, calm desk 2-4h, a tense stretch 4:00-4:30, a walk 5:00-5:30 with motion and
    /// heart rate up, its aftermath, a gap with no heart rate, then calm.
    private func day() -> L.Inputs {
        var hr: [L.HRPoint] = [], motion: [L.Motion] = []
        for t in 0..<(8 * 3600) {
            let bpm: Int
            switch t {
            case 0..<7200: bpm = 52                       // asleep
            case 14_400..<16_200: bpm = 84                // tense, still
            case 18_000..<19_800: bpm = 105               // walking
            case 19_800..<20_400: bpm = 88                // coming down after
            case 23_400..<25_200: continue                // off wrist
            default: bpm = 64                             // calm desk
            }
            hr.append(.init(ts: t, bpm: bpm))
            motion.append(.init(ts: t, intensity: (18_000..<19_800).contains(t) ? 0.35 : 0.05))
        }
        return L.Inputs(hr: hr, motion: motion, sleeps: [0...7200])
    }

    func testADayIsScoredLikeGarmin() {
        let raws = L.raw(from: 0, to: 8 * 3600, day())
        XCTAssertEqual(raws.count, 8 * 3600 / L.epochSeconds)
        let floor = L.calmFloor(raws)
        XCTAssertEqual(floor.hr ?? 0, 64, accuracy: 0.5, "the floor comes from awake, still epochs only")
        let e = L.score(raws, baseline: base)
        func at(_ t: Int) -> L.Epoch { e.first { $0.start == (t / 180) * 180 }! }
        XCTAssertEqual(at(3600).state, .measured)
        XCTAssertTrue(at(3600).asleep)
        XCTAssertEqual(at(3600).band, .rest)
        XCTAssertEqual(at(10_000).band, .rest, "calm desk time at the floor rests")
        XCTAssertEqual(at(15_000).band, .high, "20 bpm over the floor while still")
        XCTAssertEqual(at(18_500).state, .active, "walking isn't stress")
        XCTAssertNil(at(18_500).level)
        XCTAssertEqual(at(19_900).state, .afterActivity, "heart rate still up after the walk")
        XCTAssertEqual(at(24_000).state, .noData)
        XCTAssertEqual(at(27_000).band, .rest)

        let sum = L.summary(e)
        XCTAssertNotNil(sum.average)
        XCTAssertGreaterThan(sum.awakeAverage!, sum.average!, "sleep pulls the overall average down")
        XCTAssertEqual(sum.highest?.band, .high)
        XCTAssertEqual(sum.seconds[.high], 1800)
        XCTAssertEqual(sum.activeSeconds, 1800 + 3 * 180)
        XCTAssertEqual(sum.unmeasuredSeconds, 1800)
    }

    /// After a workout heart rate stays up for a long while: that isn't stress. A long session earns a long
    /// recovery window, and scoring resumes as soon as heart rate is back near calm.
    func testRecoveryAfterAWorkoutIsNotStress() {
        // 45 minutes lifting (logged), then heart rate easing from 95 to 64 over 40 minutes, then calm.
        var hr: [L.HRPoint] = []
        for t in 0..<(2 * 3600) {
            let bpm: Int
            switch t {
            case 0..<2700: bpm = 125
            case 2700..<5100: bpm = 95 - (t - 2700) * 31 / 2400
            default: bpm = 64
            }
            hr.append(.init(ts: t, bpm: bpm))
        }
        let e = L.score(L.raw(from: 0, to: 7200, L.Inputs(hr: hr, workouts: [0...2699])), baseline: base)
        let after = e.filter { $0.start >= 2700 && $0.start < 5100 }
        let scoredHigh = after.filter { ($0.level ?? 0) >= 51 }
        XCTAssertTrue(scoredHigh.isEmpty, "the cool-down never reads medium or high: \(scoredHigh.map(\.level))")
        XCTAssertTrue(after.prefix(10).allSatisfy { $0.state != .measured }, "the first half hour isn't scored")
        XCTAssertEqual(e.last?.band, .rest, "back to calm")
    }

    /// Walking the phone saw is activity, like a logged workout.
    func testPhoneWalkingIsActivity() {
        let hr = (0..<900).map { L.HRPoint(ts: $0, bpm: 88) }
        let e = L.score(L.raw(from: 0, to: 900, L.Inputs(hr: hr, workouts: [0...899])), baseline: base)
        XCTAssertTrue(e.allSatisfy { $0.state == .active })
    }

    /// Heart rate alone never makes a stretch activity: sitting still with a high heart rate is stress.
    func testHighHeartRateWhileStillIsStress() {
        let hr = (0..<600).map { L.HRPoint(ts: $0, bpm: 100) }
        let still = (0..<600).map { L.Motion(ts: $0, intensity: 0.02) }
        for inputs in [L.Inputs(hr: hr), L.Inputs(hr: hr, motion: still)] {
            let e = L.score(L.raw(from: 0, to: 600, inputs), baseline: base)
            XCTAssertTrue(e.allSatisfy { $0.state == .measured && $0.band == .high }, "\(e.map(\.state))")
        }
    }

    /// Hard exertion with some movement, short of walking (an unlogged lift), is activity.
    func testExertionWithSomeMovement() {
        let hr = (0..<600).map { L.HRPoint(ts: $0, bpm: 120) }
        let motion = (0..<600).map { L.Motion(ts: $0, intensity: $0 % 6 == 0 ? 0.4 : 0.02) }
        let e = L.score(L.raw(from: 0, to: 600, L.Inputs(hr: hr, motion: motion)), baseline: base)
        XCTAssertTrue(e.allSatisfy { $0.state == .active })
    }

    /// Fidgeting at a desk isn't activity, and after a short walk scoring resumes within minutes.
    func testDeskFidgetAndShortWalk() {
        // 15 minutes at 70, a 3-minute walk, then 75 (13 over calm) for good.
        let hr = (0..<1800).map { L.HRPoint(ts: $0, bpm: $0 < 900 ? 70 : $0 < 1080 ? 95 : 75) }
        let motion = (0..<1800).map { t in
            L.Motion(ts: t, intensity: (900..<1080).contains(t) ? 0.4 : (t % 30 == 0 ? 0.3 : 0.02))
        }
        let e = L.score(L.raw(from: 0, to: 1800, L.Inputs(hr: hr, motion: motion)), baseline: base)
        XCTAssertTrue(e.filter { $0.start < 900 }.allSatisfy { $0.state == .measured })
        XCTAssertEqual(e.first { $0.start == 900 }?.state, .active)
        let after = e.filter { $0.start >= 1080 }
        XCTAssertEqual(after.prefix(3).map(\.state), [.afterActivity, .afterActivity, .afterActivity])
        XCTAssertTrue(after.dropFirst(3).allSatisfy { $0.state == .measured }, "\(after.map(\.state))")
    }

    /// The calm floor never sits under resting heart rate plus a margin.
    func testCalmFloorAboveResting() {
        XCTAssertEqual(L.calmHR(floor: 52, restingHR: 55), 59)
        XCTAssertEqual(L.calmHR(floor: 64, restingHR: 55), 64)
        XCTAssertEqual(L.calmHR(floor: 64, restingHR: nil), 64)
    }

    /// A logged workout is activity whatever the heart rate does.
    func testLoggedWorkoutIsActivity() {
        let hr = (0..<600).map { L.HRPoint(ts: $0, bpm: 70) }
        let e = L.score(L.raw(from: 0, to: 600, L.Inputs(hr: hr, workouts: [0...599])), baseline: base)
        XCTAssertTrue(e.allSatisfy { $0.state == .active })
    }

    /// Stored readings stay as shown; gaps fill in when late data arrives; activity learned later wins.
    func testStoredReadingsStay() {
        let shown = [L.Epoch(start: 0, state: .measured, level: 40, meanHR: 66, rmssd: nil, asleep: false),
                     L.Epoch(start: 180, state: .noData, level: nil, meanHR: nil, rmssd: nil, asleep: false),
                     L.Epoch(start: 360, state: .measured, level: 70, meanHR: 74, rmssd: nil, asleep: false)]
        let fresh = [L.Epoch(start: 0, state: .measured, level: 44, meanHR: 67, rmssd: nil, asleep: false),
                     L.Epoch(start: 180, state: .measured, level: 30, meanHR: 64, rmssd: nil, asleep: false),
                     L.Epoch(start: 360, state: .active, level: nil, meanHR: 74, rmssd: nil, asleep: false),
                     L.Epoch(start: 540, state: .measured, level: 25, meanHR: 63, rmssd: nil, asleep: false)]
        let m = L.merge(stored: shown, fresh: fresh)
        XCTAssertEqual(m.map(\.level), [40, 30, nil, 25])
        XCTAssertEqual(m[2].state, .active)
        XCTAssertEqual(L.merge(stored: shown, fresh: fresh, rescoreAll: true), fresh)
    }

    /// Same samples, same baseline, same epochs: what was shown reads back exactly.
    func testDeterministicAndCodable() throws {
        let raws = L.raw(from: 0, to: 4 * 3600, day())
        let a = L.score(raws, baseline: base), b = L.score(raws, baseline: base)
        XCTAssertEqual(a, b)
        let back = try JSONDecoder().decode([L.Epoch].self, from: JSONEncoder().encode(a))
        XCTAssertEqual(back, a)
        let bb = try JSONDecoder().decode(L.Baseline.self, from: JSONEncoder().encode(base))
        XCTAssertEqual(bb, base)
    }
}

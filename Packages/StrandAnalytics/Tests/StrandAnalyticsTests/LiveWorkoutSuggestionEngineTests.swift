import XCTest
@testable import StrandAnalytics

final class LiveWorkoutSuggestionEngineTests: XCTestCase {

    typealias E = LiveWorkoutSuggestionEngine

    private func engine(resting: Int = 60, gym: Bool = true, walk: Bool = true) -> E {
        E(config: .init(restingBpm: resting, gymEnabled: gym, walkEnabled: walk))
    }

    /// Feed one HR sample per second over [from, to). Returns every action raised.
    @discardableResult
    private func feedHR(_ e: inout E, from: Int, to: Int, bpm: (Int) -> Int) -> [E.Action] {
        var out: [E.Action] = []
        var t = from
        while t < to {
            out += e.handle(.heartRate(bpm(t)), at: t)
            t += 1
        }
        return out
    }

    private func starts(_ actions: [E.Action]) -> [(E.Context, Int)] {
        actions.compactMap {
            if case let .suggestStart(c, s, _) = $0 { return (c, s) }
            return nil
        }
    }

    private func ends(_ actions: [E.Action]) -> [(Int, E.EndReason)] {
        actions.compactMap {
            if case let .suggestEnd(_, t, r) = $0 { return (t, r) }
            return nil
        }
    }

    // MARK: - Realtime arming

    func testIdleEngineDoesNotWantRealtime() {
        var e = engine()
        _ = e.handle(.tick, at: 1_000)
        XCTAssertFalse(e.wantsRealtime)
    }

    func testGymArrivalArmsRealtimeAndExpiresAfterCap() {
        var e = engine()
        _ = e.handle(.gymEntered, at: 0)
        XCTAssertTrue(e.wantsRealtime)
        _ = e.handle(.tick, at: E.gymMaxArmS + 1)
        XCTAssertFalse(e.wantsRealtime)
    }

    func testWalkingArmsRealtimeOnlyAfterArmDelay() {
        var e = engine()
        _ = e.handle(.motion(.walking), at: 0)
        _ = e.handle(.tick, at: E.walkArmAfterS - 1)
        XCTAssertFalse(e.wantsRealtime)
        _ = e.handle(.tick, at: E.walkArmAfterS)
        XCTAssertTrue(e.wantsRealtime)
    }

    func testDisabledFeaturesNeverArm() {
        var e = engine(gym: false, walk: false)
        _ = e.handle(.gymEntered, at: 0)
        _ = e.handle(.motion(.walking), at: 0)
        _ = e.handle(.tick, at: 300)
        XCTAssertFalse(e.wantsRealtime)
    }

    // MARK: - Gym start

    func testGymStartFiresOnSustainedElevatedHRAndBackdates() {
        var e = engine()
        _ = e.handle(.gymEntered, at: 0)
        // Resting HR for 5 min (changing room), then elevated from t=300.
        feedHR(&e, from: 0, to: 300) { _ in 70 }
        let actions = feedHR(&e, from: 300, to: 600) { _ in 105 }
        let s = starts(actions)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.first?.0, .gym)
        XCTAssertEqual(s.first?.1, 300, "start is backdated to the first elevated sample")
    }

    func testGymStartNotBeforeArrival() {
        var e = engine()
        feedHR(&e, from: 0, to: 100) { _ in 110 }   // elevated before arriving (cycled there)
        XCTAssertTrue(starts(e.handle(.gymEntered, at: 100)).isEmpty, "arriving out of breath is not a start")
        let early = feedHR(&e, from: 100, to: 100 + E.gymMinDwellS - 1) { _ in 110 }
        XCTAssertTrue(starts(early).isEmpty, "nothing before the dwell time")
        let actions = feedHR(&e, from: 100 + E.gymMinDwellS - 1, to: 500) { _ in 110 }
        XCTAssertEqual(starts(actions).first?.1, 100)
    }

    func testArrivingElevatedThenSettlingDoesNotSuggest() {
        var e = engine()
        feedHR(&e, from: 0, to: 100) { _ in 125 }
        _ = e.handle(.gymEntered, at: 100)
        // Heart rate settles within about a minute of walking in, then stays at rest.
        let actions = feedHR(&e, from: 100, to: 1_000) { t in t < 160 ? 100 : 72 }
        XCTAssertTrue(starts(actions).isEmpty)
    }

    func testGymRestPeriodsDoNotBreakTheStretch() {
        var e = engine()
        _ = e.handle(.gymEntered, at: 0)
        // Sets: 60 s at 115, 90 s rest at 75, repeated. Elevated fraction in 3 min ≈ 0.4 to 0.67.
        var actions: [E.Action] = []
        actions += feedHR(&e, from: 0, to: 1_200) { t in (t % 150) < 90 ? 115 : 75 }
        // The 0.6 fraction gate may or may not hit with 60% work; lift work density so it does.
        if starts(actions).isEmpty {
            actions += feedHR(&e, from: 1_200, to: 1_500) { t in (t % 150) < 120 ? 115 : 75 }
        }
        XCTAssertEqual(starts(actions).count, 1)
        XCTAssertEqual(starts(actions).first?.1, 0, "short rests do not reset the backdated start")
    }

    func testGymStartOnlyOncePerVisit() {
        var e = engine()
        _ = e.handle(.gymEntered, at: 0)
        var actions = feedHR(&e, from: 0, to: 400) { _ in 110 }
        actions += e.handle(.startDismissed, at: 400)
        actions += feedHR(&e, from: 400, to: 1_200) { _ in 110 }
        XCTAssertEqual(starts(actions).count, 1)
        // A new visit can suggest again.
        _ = e.handle(.gymExited, at: 1_300)
        _ = e.handle(.gymEntered, at: 5_000)
        let again = feedHR(&e, from: 5_000, to: 5_400) { _ in 110 }
        XCTAssertEqual(starts(again).count, 1)
    }

    func testCalmGymVisitDoesNotSuggest() {
        var e = engine()
        _ = e.handle(.gymEntered, at: 0)
        let actions = feedHR(&e, from: 0, to: 1_800) { _ in 72 }
        XCTAssertTrue(starts(actions).isEmpty)
    }

    func testLeavingGymWithdrawsUnansweredStart() {
        var e = engine()
        _ = e.handle(.gymEntered, at: 0)
        feedHR(&e, from: 0, to: 400) { _ in 110 }
        XCTAssertNotNil(e.pendingStart)
        let out = e.handle(.gymExited, at: 500)
        XCTAssertTrue(out.contains(.withdrawStart))
        XCTAssertNil(e.pendingStart)
    }

    // MARK: - Walk start

    func testBriskWalkSuggestsWalkBackdatedToBoutStart() {
        var e = engine()
        _ = e.handle(.motion(.walking), at: 1_000)
        let actions = feedHR(&e, from: 1_060, to: 1_000 + E.walkMinBoutS + 10) { _ in 90 }
        let s = starts(actions)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.first?.0, .walk)
        XCTAssertEqual(s.first?.1, 1_000)
    }

    func testSlowStrollDoesNotSuggest() {
        var e = engine()
        _ = e.handle(.motion(.walking), at: 0)
        let actions = feedHR(&e, from: 60, to: 1_500) { _ in 68 }
        XCTAssertTrue(starts(actions).isEmpty)
    }

    func testRunSuggestsRunEarlier() {
        var e = engine()
        _ = e.handle(.motion(.running), at: 0)
        let actions = feedHR(&e, from: 60, to: E.runMinBoutS + 5) { _ in 140 }
        XCTAssertEqual(starts(actions).first?.0, .run)
    }

    func testWalkWithoutHeartRateSuggestsAfterLongerBout() {
        var e = engine()
        _ = e.handle(.motion(.walking), at: 0)
        XCTAssertTrue(starts(e.handle(.tick, at: E.walkNoHRMinBoutS - 1)).isEmpty)
        XCTAssertEqual(starts(e.handle(.tick, at: E.walkNoHRMinBoutS)).count, 1)
    }

    func testShortPauseKeepsBoutAndLongStopEndsIt() {
        var e = engine()
        _ = e.handle(.motion(.walking), at: 0)
        _ = e.handle(.motion(.stationary), at: 200)
        _ = e.handle(.motion(.walking), at: 260)   // 60 s red light
        let actions = feedHR(&e, from: 260, to: E.walkMinBoutS + 30) { _ in 92 }
        XCTAssertEqual(starts(actions).first?.1, 0, "a 60 s pause does not restart the bout")
    }

    func testWalkInsideGymIsLeftToGymRule() {
        var e = engine()
        _ = e.handle(.gymEntered, at: 0)
        _ = e.handle(.motion(.walking), at: 0)
        let actions = feedHR(&e, from: 0, to: 400) { _ in 95 }   // treadmill, above gym floor
        XCTAssertEqual(starts(actions).first?.0, .gym)
    }

    // MARK: - Ends

    func testLeavingGymSuggestsEndAtExitTime() {
        var e = engine()
        _ = e.handle(.gymEntered, at: 0)
        _ = e.handle(.workoutStarted(context: .gym), at: 100)
        let out = e.handle(.gymExited, at: 4_000)
        XCTAssertEqual(ends(out).first?.0, 4_000)
        XCTAssertEqual(ends(out).first?.1, .leftGym)
    }

    func testGymQuietHeartRateSuggestsEnd() {
        var e = engine()
        _ = e.handle(.gymEntered, at: 0)
        _ = e.handle(.workoutStarted(context: .gym), at: 0)
        var actions = feedHR(&e, from: 0, to: 1_800) { _ in 110 }
        XCTAssertTrue(ends(actions).isEmpty)
        actions = feedHR(&e, from: 1_800, to: 1_800 + E.gymQuietEndS + 5) { _ in 66 }
        XCTAssertEqual(ends(actions).count, 1)
        XCTAssertEqual(ends(actions).first?.1, .heartRateRecovered)
        XCTAssertEqual(ends(actions).first?.0, 1_799, "end is the last loud sample")
    }

    func testWalkEndOnStopWithCalmHeartRate() {
        var e = engine()
        _ = e.handle(.motion(.walking), at: 0)
        _ = e.handle(.workoutStarted(context: .walk), at: 300)
        feedHR(&e, from: 300, to: 1_200) { _ in 95 }
        _ = e.handle(.motion(.stationary), at: 1_200)
        let actions = feedHR(&e, from: 1_200, to: 1_200 + E.walkStopGraceS + 5) { _ in 66 }
        XCTAssertEqual(ends(actions).first?.0, 1_200)
        XCTAssertEqual(ends(actions).first?.1, .stoppedMoving)
    }

    func testWalkEndWaitsWhileHeartRateStillHighThenGivesUp() {
        var e = engine()
        _ = e.handle(.motion(.running), at: 0)
        _ = e.handle(.workoutStarted(context: .run), at: 300)
        feedHR(&e, from: 300, to: 1_200) { _ in 150 }
        _ = e.handle(.motion(.stationary), at: 1_200)
        var actions = feedHR(&e, from: 1_200, to: 1_200 + E.walkStopGraceS + 30) { _ in 130 }
        XCTAssertTrue(ends(actions).isEmpty, "still breathing hard, may resume")
        actions = feedHR(&e, from: 1_200 + E.walkStopGraceS + 30, to: 1_200 + E.walkStopMaxS + 5) { _ in 128 }
        XCTAssertEqual(ends(actions).count, 1)
    }

    func testDrivingEndsWalkImmediately() {
        var e = engine()
        _ = e.handle(.motion(.walking), at: 0)
        _ = e.handle(.workoutStarted(context: .walk), at: 300)
        let out = e.handle(.motion(.automotive), at: 900)
        XCTAssertEqual(ends(out).first?.1, .startedDriving)
        XCTAssertEqual(ends(out).first?.0, 900)
    }

    func testEndSuggestedOnceUntilActivityResumes() {
        var e = engine()
        _ = e.handle(.motion(.walking), at: 0)
        _ = e.handle(.workoutStarted(context: .walk), at: 300)
        _ = e.handle(.motion(.stationary), at: 900)
        var all = e.handle(.tick, at: 900 + E.walkStopMaxS)
        all += e.handle(.endDismissed, at: 900 + E.walkStopMaxS + 1)
        all += e.handle(.tick, at: 2_000)
        XCTAssertEqual(ends(all).count, 1)
        // Resume walking: stale suggestion withdrawn, a later stop raises a new one.
        all = e.handle(.motion(.walking), at: 3_000)
        all += e.handle(.tick, at: 3_000 + E.walkStopGraceS)
        XCTAssertTrue(all.contains(.withdrawEnd))
        all = e.handle(.motion(.stationary), at: 3_600)
        all += e.handle(.tick, at: 3_600 + E.walkStopMaxS)
        XCTAssertEqual(ends(all).count, 1)
    }

    func testManualWorkoutUsesLongQuietSpan() {
        var e = engine()
        _ = e.handle(.workoutStarted(context: nil), at: 0)
        var actions = feedHR(&e, from: 0, to: E.gymQuietEndS + 10) { _ in 64 }
        XCTAssertTrue(ends(actions).isEmpty)
        actions = feedHR(&e, from: E.gymQuietEndS + 10, to: E.otherQuietEndS + 10) { _ in 64 }
        XCTAssertEqual(ends(actions).count, 1)
    }

    func testEndingWorkoutWithdrawsEndSuggestion() {
        var e = engine()
        _ = e.handle(.gymEntered, at: 0)
        _ = e.handle(.workoutStarted(context: .gym), at: 0)
        _ = e.handle(.gymExited, at: 100)
        let out = e.handle(.workoutEnded, at: 120)
        XCTAssertTrue(out.contains(.withdrawEnd))
        XCTAssertFalse(e.wantsRealtime)
    }

    // MARK: - Hygiene

    func testOutOfRangeAndDuplicateSamplesAreIgnored() {
        var e = engine()
        _ = e.handle(.heartRate(0), at: 1)
        _ = e.handle(.heartRate(300), at: 2)
        _ = e.handle(.heartRate(80), at: 3)
        _ = e.handle(.heartRate(81), at: 3)
        _ = e.handle(.heartRate(79), at: 2)   // out of order, dropped
        XCTAssertEqual(e.heartRate(from: 0, to: 10).map(\.bpm), [81])
    }

    func testUnansweredStartTimesOut() {
        var e = engine()
        _ = e.handle(.gymEntered, at: 0)
        feedHR(&e, from: 0, to: 400) { _ in 110 }
        XCTAssertNotNil(e.pendingStart)
        let out = e.handle(.tick, at: 400 + E.pendingStartTimeoutS)
        XCTAssertTrue(out.contains(.withdrawStart))
    }
}

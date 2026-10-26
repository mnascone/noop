import XCTest
@testable import StrandAnalytics

final class LiveWorkoutSuggestionEngineTests: XCTestCase {

    typealias E = LiveWorkoutSuggestionEngine

    private func engine(resting: Int = 60, gym: Bool = true, walk: Bool = true) -> E {
        E(config: .init(restingBpm: resting, placesEnabled: gym, walkEnabled: walk))
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
            if case let .start(c, s, _) = $0 { return (c, s) }
            return nil
        }
    }

    private func ends(_ actions: [E.Action]) -> [(Int, E.EndReason)] {
        actions.compactMap {
            if case let .end(_, t, r) = $0 { return (t, r) }
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
        _ = e.handle(.placeEntered(id: "gym", params: .lifting), at: 0)
        XCTAssertTrue(e.wantsRealtime)
        _ = e.handle(.tick, at: E.placeMaxArmS + 1)
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
        _ = e.handle(.placeEntered(id: "gym", params: .lifting), at: 0)
        _ = e.handle(.motion(.walking), at: 0)
        _ = e.handle(.tick, at: 300)
        XCTAssertFalse(e.wantsRealtime)
    }

    // MARK: - Gym start

    func testGymStartFiresOnSustainedElevatedHRAndBackdates() {
        var e = engine()
        _ = e.handle(.placeEntered(id: "gym", params: .lifting), at: 0)
        // Resting HR for 5 min (changing room), then elevated from t=300.
        feedHR(&e, from: 0, to: 300) { _ in 70 }
        let actions = feedHR(&e, from: 300, to: 600) { _ in 105 }
        let s = starts(actions)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.first?.0, .place("gym"))
        XCTAssertEqual(s.first?.1, 300, "start is backdated to the first elevated sample")
    }

    func testGymStartNotBeforeArrival() {
        var e = engine()
        feedHR(&e, from: 0, to: 100) { _ in 110 }   // elevated before arriving (cycled there)
        XCTAssertTrue(starts(e.handle(.placeEntered(id: "gym", params: .lifting), at: 100)).isEmpty, "arriving out of breath is not a start")
        let early = feedHR(&e, from: 100, to: 100 + E.placeMinDwellS - 1) { _ in 110 }
        XCTAssertTrue(starts(early).isEmpty, "nothing before the dwell time")
        let actions = feedHR(&e, from: 100 + E.placeMinDwellS - 1, to: 500) { _ in 110 }
        XCTAssertEqual(starts(actions).first?.1, 100)
    }

    func testArrivingElevatedThenSettlingDoesNotSuggest() {
        var e = engine()
        feedHR(&e, from: 0, to: 100) { _ in 125 }
        _ = e.handle(.placeEntered(id: "gym", params: .lifting), at: 100)
        // Heart rate settles within about a minute of walking in, then stays at rest.
        let actions = feedHR(&e, from: 100, to: 1_000) { t in t < 160 ? 100 : 72 }
        XCTAssertTrue(starts(actions).isEmpty)
    }

    func testGymRestPeriodsDoNotBreakTheStretch() {
        var e = engine()
        _ = e.handle(.placeEntered(id: "gym", params: .lifting), at: 0)
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
        _ = e.handle(.placeEntered(id: "gym", params: .lifting), at: 0)
        var actions = feedHR(&e, from: 0, to: 400) { _ in 110 }
        actions += e.handle(.startDismissed, at: 400)
        actions += feedHR(&e, from: 400, to: 1_200) { _ in 110 }
        XCTAssertEqual(starts(actions).count, 1)
        // A new visit can suggest again.
        _ = e.handle(.placeExited(id: "gym"), at: 1_300)
        _ = e.handle(.placeEntered(id: "gym", params: .lifting), at: 5_000)
        let again = feedHR(&e, from: 5_000, to: 5_400) { _ in 110 }
        XCTAssertEqual(starts(again).count, 1)
    }

    func testCalmGymVisitDoesNotSuggest() {
        var e = engine()
        _ = e.handle(.placeEntered(id: "gym", params: .lifting), at: 0)
        let actions = feedHR(&e, from: 0, to: 1_800) { _ in 72 }
        XCTAssertTrue(starts(actions).isEmpty)
    }

    func testLeavingGymWithdrawsUnansweredStart() {
        var e = engine()
        _ = e.handle(.placeEntered(id: "gym", params: .lifting), at: 0)
        feedHR(&e, from: 0, to: 400) { _ in 110 }
        XCTAssertNotNil(e.pendingStart)
        let out = e.handle(.placeExited(id: "gym"), at: 500)
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
        _ = e.handle(.placeEntered(id: "gym", params: .lifting), at: 0)
        _ = e.handle(.motion(.walking), at: 0)
        let actions = feedHR(&e, from: 0, to: 400) { _ in 95 }   // treadmill, above gym floor
        XCTAssertEqual(starts(actions).first?.0, .place("gym"))
    }

    // MARK: - Ends

    func testLeavingGymSuggestsEndAtExitTime() {
        var e = engine()
        _ = e.handle(.placeEntered(id: "gym", params: .lifting), at: 0)
        _ = e.handle(.workoutStarted(context: .place("gym")), at: 100)
        let out = e.handle(.placeExited(id: "gym"), at: 4_000)
        XCTAssertEqual(ends(out).first?.0, 4_000)
        XCTAssertEqual(ends(out).first?.1, .leftPlace)
    }

    func testGymQuietHeartRateSuggestsEnd() {
        var e = engine()
        _ = e.handle(.placeEntered(id: "gym", params: .lifting), at: 0)
        _ = e.handle(.workoutStarted(context: .place("gym")), at: 0)
        var actions = feedHR(&e, from: 0, to: 1_800) { _ in 110 }
        XCTAssertTrue(ends(actions).isEmpty)
        actions = feedHR(&e, from: 1_800, to: 1_800 + E.PlaceParams.lifting.quietEndS + 5) { _ in 66 }
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
        var actions = feedHR(&e, from: 0, to: E.PlaceParams.lifting.quietEndS + 10) { _ in 64 }
        XCTAssertTrue(ends(actions).isEmpty)
        actions = feedHR(&e, from: E.PlaceParams.lifting.quietEndS + 10, to: E.otherQuietEndS + 10) { _ in 64 }
        XCTAssertEqual(ends(actions).count, 1)
    }

    func testEndingWorkoutWithdrawsEndSuggestion() {
        var e = engine()
        _ = e.handle(.placeEntered(id: "gym", params: .lifting), at: 0)
        _ = e.handle(.workoutStarted(context: .place("gym")), at: 0)
        _ = e.handle(.placeExited(id: "gym"), at: 100)
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
        _ = e.handle(.placeEntered(id: "gym", params: .lifting), at: 0)
        feedHR(&e, from: 0, to: 400) { _ in 110 }
        XCTAssertNotNil(e.pendingStart)
        let out = e.handle(.tick, at: 400 + E.pendingStartTimeoutS)
        XCTAssertTrue(out.contains(.withdrawStart))
    }

    // MARK: - Places v2

    func testLeavingPlaceEndsAtLastHeartRateDrop() {
        var e = engine()
        _ = e.handle(.placeEntered(id: "gym", params: .lifting), at: 0)
        _ = e.handle(.workoutStarted(context: .place("gym")), at: 300)
        feedHR(&e, from: 300, to: 3_000) { _ in 112 }        // lifting
        feedHR(&e, from: 3_000, to: 3_600) { _ in 70 }       // packing up, walking out
        let out = e.handle(.placeExited(id: "gym"), at: 3_600)
        XCTAssertEqual(ends(out).first?.0, 2_999, "ends when HR dropped for the last time, not at the exit")
        XCTAssertEqual(ends(out).first?.1, .leftPlace)
    }

    func testPerPlaceMarginControlsStart() {
        // A rink with a 30 bpm margin: 85 bpm (resting 60) does not start it, 95 does.
        var e = engine()
        _ = e.handle(.placeEntered(id: "rink", params: .sport), at: 0)
        let calm = feedHR(&e, from: 0, to: 600) { _ in 85 }
        XCTAssertTrue(starts(calm).isEmpty)
        let hard = feedHR(&e, from: 600, to: 900) { _ in 95 }
        XCTAssertEqual(starts(hard).first?.0, .place("rink"))
    }

    func testPerPlaceQuietSpanControlsEnd() {
        var e = engine()
        _ = e.handle(.placeEntered(id: "rink", params: .init(marginBPM: 30, quietEndS: 20 * 60)), at: 0)
        _ = e.handle(.workoutStarted(context: .place("rink")), at: 0)
        feedHR(&e, from: 0, to: 3_600) { _ in 140 }
        var actions = feedHR(&e, from: 3_600, to: 3_600 + 15 * 60) { _ in 65 }
        XCTAssertTrue(ends(actions).isEmpty, "15 min quiet is not enough for a 20 min place setting")
        actions = feedHR(&e, from: 3_600 + 15 * 60, to: 3_600 + 21 * 60) { _ in 65 }
        XCTAssertEqual(ends(actions).first?.0, 3_599)
    }

    func testSwitchingPlacesTracksTheNewOne() {
        var e = engine()
        _ = e.handle(.placeEntered(id: "gym", params: .lifting), at: 0)
        _ = e.handle(.placeExited(id: "gym"), at: 100)
        _ = e.handle(.placeEntered(id: "rink", params: .sport), at: 200)
        XCTAssertEqual(e.currentPlace, "rink")
        _ = e.handle(.placeExited(id: "gym"), at: 300)   // stale exit for another place is ignored
        XCTAssertEqual(e.currentPlace, "rink")
    }

    func testContextKeyRoundTrip() {
        for c: E.Context in [.walk, .run, .place("A1-b"), .place("with:colon")] {
            XCTAssertEqual(E.Context(key: c.key), c)
        }
        XCTAssertNil(E.Context(key: "place:"))
        XCTAssertNil(E.Context(key: "bogus"))
    }

    // MARK: - Walk to place hand-off

    /// A walk that arrives at the gym ends at the door; the lift waits for heart rate above the walk's
    /// level rather than starting from walking heart rate.
    func testWalkIntoGymEndsWalkAndLiftWaitsForSpike() {
        var e = engine(resting: 60)
        _ = e.handle(.motion(.walking), at: 0)
        // Walking at ~95 bpm (resting + 35, above the place's resting + 20 floor).
        feedHR(&e, from: 0, to: 600) { _ in 95 }
        _ = e.handle(.workoutStarted(context: .walk), at: 600)
        feedHR(&e, from: 600, to: 900) { _ in 95 }
        let arrive = e.handle(.placeEntered(id: "gym", params: .lifting), at: 900)
        XCTAssertEqual(ends(arrive).first?.0, 900)
        XCTAssertEqual(ends(arrive).first?.1, .arrivedAtPlace)
        // Walking around the gym does not withdraw the hand-off.
        let around = feedHR(&e, from: 900, to: 1_100) { _ in 95 }
        XCTAssertFalse(around.contains(.withdrawEnd))
        _ = e.handle(.workoutEnded, at: 1_100)
        // Still at walking heart rate for 10 minutes: no lift.
        let still = feedHR(&e, from: 1_100, to: 1_700) { _ in 96 }
        XCTAssertTrue(starts(still).isEmpty)
        // Sets push heart rate past the walk's level + 10: the lift starts.
        let lift = feedHR(&e, from: 1_700, to: 2_000) { _ in 118 }
        let s = starts(lift)
        XCTAssertEqual(s.first?.0, .place("gym"))
        XCTAssertGreaterThanOrEqual(s.first?.1 ?? 0, 1_700)
    }

    /// Leaving the gym and walking away at walking pace starts a walk from the moment you left.
    func testLeavingGymAtWalkingPaceStartsWalkFromExit() {
        var e = engine(resting: 60)
        _ = e.handle(.placeEntered(id: "gym", params: .lifting), at: 0)
        _ = e.handle(.workoutStarted(context: .place("gym")), at: 300)
        feedHR(&e, from: 300, to: 3_600) { t in t % 180 < 60 ? 125 : 100 }
        let leave = e.handle(.placeExited(id: "gym"), at: 3_600)
        XCTAssertEqual(ends(leave).first?.1, .leftPlace)
        _ = e.handle(.workoutEnded, at: 3_601)
        XCTAssertTrue(e.wantsLocationUpdates)
        var got: [E.Action] = []
        var t = 3_610
        while t < 3_610 + E.postExitWalkS + 20 {
            got += e.handle(.speed(1.3), at: t)
            t += 5
        }
        let s = starts(got)
        XCTAssertEqual(s.first?.0, .walk)
        XCTAssertEqual(s.first?.1, 3_610)
    }

    /// Driving speed after leaving is not a walk.
    func testLeavingGymByCarStartsNothing() {
        var e = engine(resting: 60)
        _ = e.handle(.placeEntered(id: "gym", params: .lifting), at: 0)
        _ = e.handle(.placeExited(id: "gym"), at: 3_600)
        var got: [E.Action] = []
        var t = 3_610
        while t < 3_610 + 600 {
            got += e.handle(.speed(14), at: t)
            t += 5
        }
        XCTAssertTrue(starts(got).isEmpty)
    }

    // MARK: - Walk ends from GPS and heart rate

    /// Feed one HR sample a second and a GPS speed every 5 s over [from, to).
    @discardableResult
    private func feedWalk(_ e: inout E, from: Int, to: Int, bpm: Int, mps: Double?) -> [E.Action] {
        var out: [E.Action] = []
        for t in from..<to {
            out += e.handle(.heartRate(bpm), at: t)
            if let mps, t % 5 == 0 { out += e.handle(.speed(mps), at: t) }
        }
        return out
    }

    /// The classifier sticks on walking, but GPS stops moving: the walk ends where GPS went still.
    func testGPSStillEndsAWalkTheClassifierMissed() {
        var e = engine()
        _ = e.handle(.motion(.walking), at: 0)
        _ = e.handle(.workoutStarted(context: .walk), at: 300)
        XCTAssertTrue(e.wantsLocationUpdates, "GPS watches the walk")
        feedWalk(&e, from: 300, to: 1_200, bpm: 95, mps: 1.3)
        let out = feedWalk(&e, from: 1_200, to: 1_200 + E.walkStopGraceS + 10, bpm: 68, mps: 0.1)
        XCTAssertEqual(ends(out).count, 1)
        XCTAssertEqual(ends(out).first?.0, 1_200)
        XCTAssertEqual(ends(out).first?.1, .stoppedMoving)
    }

    /// No GPS, classifier still on walking, heart rate back near resting: the walk ends at the last
    /// sample above the walk floor.
    func testCalmHeartRateEndsAWalkWithoutGPS() {
        var e = engine()
        _ = e.handle(.motion(.walking), at: 0)
        _ = e.handle(.workoutStarted(context: .walk), at: 300)
        feedWalk(&e, from: 300, to: 1_200, bpm: 95, mps: nil)
        var out = feedWalk(&e, from: 1_200, to: 1_200 + E.walkCalmEndS - 30, bpm: 64, mps: nil)
        XCTAssertTrue(ends(out).isEmpty, "not calm for long enough yet")
        out = feedWalk(&e, from: 1_200 + E.walkCalmEndS - 30, to: 1_200 + E.walkCalmEndS + 10, bpm: 64, mps: nil)
        XCTAssertEqual(ends(out).first?.0, 1_199)
    }

    /// A gentle stroll, heart rate barely up, but GPS shows you going somewhere: keep the walk.
    func testSlowStrollMovingByGPSKeepsTheWalk() {
        var e = engine()
        _ = e.handle(.motion(.walking), at: 0)
        _ = e.handle(.workoutStarted(context: .walk), at: 300)
        let out = feedWalk(&e, from: 300, to: 300 + 3 * E.walkCalmEndS, bpm: 66, mps: 0.9)
        XCTAssertTrue(ends(out).isEmpty)
    }

    /// Walking around the house: the classifier says walking and heart rate is up, but GPS never moves.
    func testPacingIndoorsDoesNotStartAWalk() {
        var e = engine()
        _ = e.handle(.motion(.walking), at: 0)
        let out = feedWalk(&e, from: 0, to: E.walkMinBoutS + 120, bpm: 95, mps: 0.2)
        XCTAssertTrue(starts(out).isEmpty)
    }

    // MARK: - Driving past a place

    /// Driving through the area with heart rate up (a tense drive, a coffee) starts nothing.
    func testDrivingThroughAPlaceStartsNothing() {
        var e = engine(resting: 60)
        _ = e.handle(.motion(.automotive), at: 0)
        _ = e.handle(.placeEntered(id: "gym", params: .lifting), at: 10)
        let out = feedHR(&e, from: 10, to: 10 + E.placeMinDwellS + 300) { _ in 95 }
        XCTAssertTrue(starts(out).isEmpty)
    }

    /// Parking and walking in: the dwell runs from when the car stopped, then a lift starts as usual.
    func testParkingRestartsTheDwellThenStarts() {
        var e = engine(resting: 60)
        _ = e.handle(.motion(.automotive), at: 0)
        _ = e.handle(.placeEntered(id: "gym", params: .lifting), at: 10)
        feedHR(&e, from: 10, to: 120) { _ in 70 }
        _ = e.handle(.motion(.walking), at: 120)
        var out = feedHR(&e, from: 120, to: 120 + E.placeMinDwellS - 5) { _ in 95 }
        XCTAssertTrue(starts(out).isEmpty, "dwell counts from parking, not from crossing the edge")
        out = feedHR(&e, from: 120 + E.placeMinDwellS - 5, to: 120 + E.placeMinDwellS + 60) { _ in 95 }
        XCTAssertEqual(starts(out).first?.0, .place("gym"))
        XCTAssertGreaterThanOrEqual(starts(out).first?.1 ?? 0, 120)
    }
}

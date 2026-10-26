import XCTest
@testable import StrandAnalytics

/// Simulated strength workouts for set detection and editing: heart rate that rises late and keeps
/// climbing after the last rep, wrist-motion runs, pauses inside a set, real rests, false and missed sets.
final class StrengthSetsTests: XCTestCase {
    typealias S = SetCalibration.Span

    private struct Noise {
        var state: UInt64 = 0x9E3779B97F4A7C15
        mutating func next(_ amp: Double) -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Double(state >> 11) / Double(1 << 53) * 2 - 1) * amp
        }
    }

    /// One second at a time from `t0` to `t1`. Movement in `moving` drives heart rate up after a 3 s
    /// lag at `climb` bpm/s, and it keeps climbing 12 s past the last rep, then decays to 92 with a 25 s
    /// time constant. Beat-to-beat jitter is large at rest and small while moving.
    private func session(_ moving: [S], t0: Int = 1000, t1: Int = 1900, climb: Double = 0.6,
                         bumps: [S] = []) -> (hr: [SetCalibration.HRSampleTS], beats: [SetCalibration.Beat]) {
        var noise = Noise()
        var level = 92.0
        var hr: [SetCalibration.HRSampleTS] = [], beats: [SetCalibration.Beat] = []
        for t in t0..<t1 {
            let driving = moving.contains { t >= $0.start + 3 && t < $0.end + 12 }
            let bump = bumps.contains { t >= $0.start && t < $0.end }
            if driving { level += climb } else { level = 92 + (level - 92) * exp(-1 / 25) }
            let bpm = level + (bump ? 7 : 0) + noise.next(1.5)
            hr.append(.init(ts: t, bpm: Int(bpm.rounded())))
            let busy = moving.contains { t >= $0.start && t < $0.end + 10 }
            let sinceRest = moving.filter { $0.end + 10 <= t }.map { t - ($0.end + 10) }.min() ?? 999
            let jitter = busy ? 6.0 : min(45, 10 + Double(sinceRest))   // HRV rebounds through a rest
            beats.append(.init(ts: t, ms: Int(60_000 / bpm + (t % 2 == 0 ? jitter : -jitter))))
        }
        return (hr, beats)
    }

    private func run(_ s: S, reps: Int = 8) -> MotionRun {
        MotionRun(start: s.start, end: s.end, reps: reps, rangeG: 0.3)
    }

    private func counted(_ v: [TimelineSet]) -> [TimelineSet] { v.filter { !$0.uncertain } }

    // MARK: Detection

    /// Heart rate alone, rising late: the sets still land on the movement, give or take the lag.
    func testDelayedHeartRateRiseFindsTheMovement() {
        let truth = [S(start: 1120, end: 1160), S(start: 1300, end: 1345), S(start: 1480, end: 1520)]
        let s = session(truth)
        let det = counted(StrengthSetDetector.detect(hr: s.hr, beats: s.beats, motion: [], mode: .lifting,
                                                     tuning: StrengthTuning()))
        XCTAssertEqual(det.count, 3)
        for (d, t) in zip(det, truth) {
            XCTAssertEqual(Double(d.start), Double(t.start), accuracy: 10, "start \(d.start) vs \(t.start)")
            XCTAssertEqual(Double(d.end), Double(t.end), accuracy: 12, "end \(d.end) vs \(t.end)")
        }
    }

    /// With wrist motion, the edges are motion's, to the second, and heart rate's late rise confirms it.
    func testMotionGivesTheEdgesHeartRateConfirms() {
        let truth = [S(start: 1120, end: 1160), S(start: 1300, end: 1345)]
        let s = session(truth)
        let det = counted(StrengthSetDetector.detect(hr: s.hr, beats: s.beats, motion: truth.map { run($0) },
                                                     mode: .lifting, tuning: StrengthTuning()))
        XCTAssertEqual(det.map(\.span), truth)
        XCTAssertEqual(det.first?.reps, 8)
    }

    /// A short pause inside one set (heart rate stays up) is one set, from heart rate or from two motion runs.
    func testShortPauseInsideOneSet() {
        let parts = [S(start: 1120, end: 1150), S(start: 1162, end: 1190)]
        let s = session(parts)
        let fromHR = counted(StrengthSetDetector.detect(hr: s.hr, beats: s.beats, motion: [], mode: .lifting,
                                                        tuning: StrengthTuning()))
        XCTAssertEqual(fromHR.count, 1)
        let fromMotion = counted(StrengthSetDetector.detect(hr: s.hr, beats: s.beats, motion: parts.map { run($0, reps: 5) },
                                                            mode: .lifting, tuning: StrengthTuning()))
        XCTAssertEqual(fromMotion.map(\.span), [S(start: 1120, end: 1190)])
        XCTAssertEqual(fromMotion.first?.reps, 10)
    }

    /// A genuine rest (heart rate comes down) keeps two sets apart, even a fairly short one.
    func testGenuineRestKeepsTwoSets() {
        let truth = [S(start: 1120, end: 1160), S(start: 1250, end: 1290)]
        let s = session(truth)
        let det = counted(StrengthSetDetector.detect(hr: s.hr, beats: s.beats, motion: truth.map { run($0) },
                                                     mode: .lifting, tuning: StrengthTuning()))
        XCTAssertEqual(det.count, 2)
    }

    /// Clean HRV rising through a break marks it a rest even when heart rate stayed fairly high; HRV is
    /// never read during the movement itself.
    func testCleanHRVReboundOnlyInTheBreak() {
        let beats: [SetCalibration.Beat] = (0..<60).map { i in
            let jitter = i < 15 ? 8.0 : 40.0
            return .init(ts: 2000 + i, ms: 700 + (i % 2 == 0 ? Int(jitter) : -Int(jitter)))
        }
        XCTAssertNotNil(StrengthSetDetector.restRebound(beats, from: 2000, to: 2060))
        XCTAssertGreaterThan(StrengthSetDetector.restRebound(beats, from: 2000, to: 2060)!, 1)
        // Noisy beats (movement, artefacts) are not used at all.
        let noisy: [SetCalibration.Beat] = (0..<60).map { .init(ts: 2000 + $0, ms: 700 + ($0 % 3 == 0 ? 400 : -300)) }
        XCTAssertNil(StrengthSetDetector.cleanRMSSD(noisy, from: 2000, to: 2060))
    }

    /// Motion that heart rate never answered (a warm-up swing, re-racking) is uncertain, not a set; so is
    /// a small heart-rate bump while motion was streaming and saw nothing.
    func testFalseSetsAreUncertainNotCounted() {
        let real = [S(start: 1120, end: 1160)]
        let s = session(real, bumps: [S(start: 1500, end: 1530)])
        let fake = MotionRun(start: 1700, end: 1720, reps: 5, rangeG: 0.2)
        let det = StrengthSetDetector.detect(hr: s.hr, beats: s.beats, motion: real.map { run($0) } + [fake],
                                             mode: .lifting, tuning: StrengthTuning())
        XCTAssertEqual(counted(det).map(\.span), real)
        XCTAssertTrue(det.contains { $0.uncertain && $0.start == 1700 }, "the motion-only run is shown as uncertain")
    }

    /// A set the wrist didn't see (a machine) but heart rate clearly did is still found.
    func testMissedByMotionFoundByHeartRate() {
        let truth = [S(start: 1120, end: 1160), S(start: 1320, end: 1365)]
        let s = session(truth)
        let det = counted(StrengthSetDetector.detect(hr: s.hr, beats: s.beats, motion: [run(truth[0])],
                                                     mode: .lifting, tuning: StrengthTuning()))
        XCTAssertEqual(det.count, 2)
        XCTAssertEqual(Double(det[1].start), 1320, accuracy: 10)
    }

    // MARK: Learning

    /// You join pauses the defaults read as rests (heart rate only dipped a little): learning raises the
    /// pause tolerance, from evidence, and the count comes out right.
    func testLearnsPausesFromJoins() {
        // Two parts, 20 s apart, with a slow climb so heart rate dips ~6 bpm in between.
        let parts1 = [S(start: 1120, end: 1145), S(start: 1170, end: 1195)]
        let parts2 = [S(start: 1400, end: 1425), S(start: 1448, end: 1475)]
        let s = session(parts1 + parts2, climb: 0.9)
        let truth = [S(start: 1120, end: 1195), S(start: 1400, end: 1475)]
        let ex = StrengthExample(hr: s.hr, beats: s.beats, motion: (parts1 + parts2).map { run($0, reps: 4) }, truth: truth)
        var start = StrengthTuning()
        start.pauseFallBPM = 3
        start.hrvRebound = 0
        let fit = StrengthLearner.fit([ex], mode: .lifting, start: start)!
        XCTAssertGreaterThan(fit.errorsBefore, 0)
        XCTAssertEqual(fit.errorsAfter, 0)
        XCTAssertEqual(fit.exactAfter, 1)
    }

    /// Learning per exercise only uses the stretch around that exercise's sets.
    func testExamplesPerExercise() {
        let s = session([S(start: 1120, end: 1160), S(start: 1500, end: 1540)])
        var t = SetTimeline(startTs: 1000, endTs: 1900, sport: "Strength", mode: "lifting", hr: s.hr, beats: s.beats,
                            detected: [], detectedFrom: "heartRate")
        t.edited = [TimelineSet(start: 1120, end: 1160, exercise: "Bench press"),
                    TimelineSet(start: 1500, end: 1540, exercise: "Squat")]
        let bench = StrengthExample.from([t], exercise: "Bench press")
        XCTAssertEqual(bench.count, 1)
        XCTAssertEqual(bench[0].truth, [S(start: 1120, end: 1160)])
        XCTAssertTrue(bench[0].hr.allSatisfy { $0.ts >= 1060 && $0.ts <= 1220 })
    }

    // MARK: Editing

    private func editor() -> SetTimelineEditor {
        SetTimelineEditor(sets: [TimelineSet(id: "a", start: 100, end: 140, reps: 8, exercise: "Bench press"),
                                 TimelineSet(id: "b", start: 160, end: 190, reps: 6),
                                 TimelineSet(id: "c", start: 400, end: 410, confidence: 0.3, uncertain: true)],
                          bounds: 0...1000)
    }

    func testAddDeleteMoveSplitJoinUndoRedo() {
        var e = editor()
        XCTAssertEqual(e.counted.count, 2)

        // Add a missed set by drawing over empty time.
        let added = e.add(start: 600, end: 640, now: 1)
        XCTAssertNotNil(added)
        XCTAssertEqual(e.counted.count, 3)

        // Delete a false one.
        XCTAssertTrue(e.delete(added!, now: 2))
        XCTAssertEqual(e.counted.count, 2)

        // Drag an edge.
        XCTAssertTrue(e.move("a", end: 150, now: 3))
        XCTAssertEqual(e.sets.first { $0.id == "a" }?.end, 150)

        // Join a short pause: one continuous span over both and the gap, reps added.
        XCTAssertTrue(e.joinWithNext("a", now: 4))
        XCTAssertEqual(e.counted.count, 1)
        XCTAssertEqual(e.counted.first?.span, S(start: 100, end: 190))
        XCTAssertEqual(e.counted.first?.reps, 14)
        XCTAssertEqual(e.counted.first?.exercise, "Bench press")

        // Split it back.
        XCTAssertTrue(e.split("a", at: 152, now: 5))
        XCTAssertEqual(e.counted.count, 2)

        // Confirm the uncertain one.
        XCTAssertTrue(e.confirm("c", now: 6))
        XCTAssertEqual(e.counted.count, 3)

        // Undo three steps, redo one.
        e.undo(); e.undo(); e.undo()
        XCTAssertEqual(e.counted.count, 2)
        XCTAssertEqual(e.counted.first?.end, 150)
        e.redo()
        XCTAssertEqual(e.counted.count, 1)
        XCTAssertTrue(e.canUndo && e.canRedo)

        // Every applied edit is logged, undo and redo included.
        XCTAssertEqual(e.log.map(\.kind), [.add, .delete, .move, .join, .split, .confirm, .undo, .undo, .undo, .redo])
    }

    /// Split lands on the stop in the reps, else on heart rate's dip, never just the middle when there's
    /// evidence.
    func testSplitPointFollowsRepsThenHeartRate() {
        // Reps every 3 s from 100 to 130, a 15 s stop, reps again 145 to 175.
        let reps = Array(stride(from: 100.0, through: 130, by: 3)) + Array(stride(from: 145.0, through: 175, by: 3))
        let m = [MotionRun(start: 100, end: 176, reps: reps.count, repTimes: reps)]
        XCTAssertEqual(Double(SetCalibration.splitPoint(start: 98, end: 178, hr: [], motion: m)), 137.5, accuracy: 1)
        // No motion: heart rate climbs, dips at 160, climbs again; delay 6 s.
        let hr = (100..<220).map { t -> SetCalibration.HRSampleTS in
            let bpm = t < 160 ? 100 + (t - 100) / 2 : (t < 170 ? 130 - (t - 160) : 120 + (t - 170) / 2)
            return .init(ts: t, bpm: bpm)
        }
        XCTAssertEqual(Double(SetCalibration.splitPoint(start: 100, end: 220, hr: hr, motion: [], hrDelayS: 6)), 164, accuracy: 3)
        // Nothing to go on: the middle.
        XCTAssertEqual(SetCalibration.splitPoint(start: 100, end: 200, hr: [], motion: []), 150)
    }

    /// Reps at a steady rhythm are stronger evidence than the same count with stretching gaps.
    func testIrregularRhythmCountsForLess() {
        let steady = MotionRun(start: 100, end: 130, reps: 8, repTimes: (0..<8).map { 100 + Double($0) * 4 })
        let ragged = MotionRun(start: 100, end: 130, reps: 8, repTimes: [100, 102, 110, 112, 120, 122, 128, 130])
        XCTAssertTrue(StrengthSetDetector.isSteady(steady, 1.6))
        XCTAssertFalse(StrengthSetDetector.isSteady(ragged, 1.6))
        let t = StrengthTuning()
        let a = StrengthSetDetector.detect(hr: [], beats: [], motion: [steady], mode: .lifting, tuning: t)
        let b = StrengthSetDetector.detect(hr: [], beats: [], motion: [ragged], mode: .lifting, tuning: t)
        XCTAssertGreaterThan(a.first?.confidence ?? 0, b.first?.confidence ?? 0)
    }

    func testDraggingIntoANeighbourJoinsIt() {
        var e = editor()
        XCTAssertTrue(e.move("a", end: 170))
        XCTAssertEqual(e.counted.count, 1)
        XCTAssertEqual(e.counted.first?.span, S(start: 100, end: 190))
    }

    func testImpossibleEditsChangeNothing() {
        var e = editor()
        XCTAssertNil(e.add(start: 700, end: 701))
        XCTAssertFalse(e.delete("nope"))
        XCTAssertFalse(e.split("b", at: 161))
        XCTAssertFalse(e.joinWithNext("c"))
        XCTAssertFalse(e.canUndo)
        XCTAssertTrue(e.log.isEmpty)
    }

    // MARK: Persistence

    func testTimelineRoundTripsAndKeepsSensorDataAndHistory() throws {
        var e = editor()
        e.joinWithNext("a", now: 9)
        let t = SetTimeline(startTs: 0, endTs: 1000, sport: "Strength", mode: "lifting",
                            hr: [.init(ts: 1, bpm: 90)], beats: [.init(ts: 1, ms: 650)],
                            motion: [MotionRun(start: 100, end: 140, reps: 8, repTimes: [101, 106])],
                            detected: editor().sets, detectedFrom: "motion+heartRate",
                            edited: e.sets, history: e.log)
        let back = try JSONDecoder().decode(SetTimeline.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(back, t)
        XCTAssertEqual(back.counted.count, 1)
        XCTAssertEqual(back.detected.count, 3, "what was detected is kept beside your edits")
        XCTAssertEqual(back.history.first?.kind, .join)
    }

    /// Records saved by the previous build (start/end/reps only) still load.
    func testOlderRecordsDecode() throws {
        let old = #"{"startTs":0,"endTs":600,"sport":"Strength","mode":"lifting","hr":[],"beats":[],"detected":[{"start":10,"end":50,"reps":8}],"detectedFrom":"heartRate","edited":[{"start":10,"end":60}]}"#
        let t = try JSONDecoder().decode(SetTimeline.self, from: Data(old.utf8))
        XCTAssertEqual(t.counted.map(\.span), [S(start: 10, end: 60)])
        XCTAssertTrue(t.motion.isEmpty && t.history.isEmpty)
    }

    // MARK: Push / pull / legs

    func testCategoryDefaults() {
        XCTAssertEqual(StrengthCategory.guess(name: "Bench Press"), .push)
        XCTAssertEqual(StrengthCategory.guess(name: "Overhead press"), .push)
        XCTAssertEqual(StrengthCategory.guess(name: "Barbell row"), .pull)
        XCTAssertEqual(StrengthCategory.guess(name: "Lat pulldown"), .pull)
        XCTAssertEqual(StrengthCategory.guess(name: "Biceps curl"), .pull)
        XCTAssertEqual(StrengthCategory.guess(name: "Leg curl"), .legs)
        XCTAssertEqual(StrengthCategory.guess(name: "Back squat"), .legs)
        XCTAssertEqual(StrengthCategory.guess(name: "Romanian deadlift"), .legs)
        XCTAssertEqual(StrengthCategory.guess(name: "Face pull"), .pull)
        XCTAssertEqual(StrengthCategory.guess(name: "Plank"), nil)
        XCTAssertEqual(StrengthCategory.guess(name: "Cable thing", primaryRegion: "pull"), .pull)
        XCTAssertEqual(StrengthCategory.guess(name: "Plank", primaryRegion: "trunk"), nil)
    }

    /// A workout mixing exercises sums by category; each set takes its exercise's.
    func testSummaryCountsByCategory() {
        var t = SetTimeline(startTs: 0, endTs: 1000, sport: "Strength", mode: "lifting", hr: [], beats: [],
                            detected: [], detectedFrom: "heartRate")
        t.edited = [TimelineSet(start: 10, end: 50, exercise: "Bench press"),
                    TimelineSet(start: 150, end: 190, exercise: "Bench press"),
                    TimelineSet(start: 300, end: 340, exercise: "Row"),
                    TimelineSet(start: 500, end: 540, exercise: "Squat"),
                    TimelineSet(start: 700, end: 710, uncertain: true)]
        let sum = SetSummary(t) { StrengthCategory.guess(name: $0) }
        XCTAssertEqual(sum.count, 4)
        XCTAssertEqual(sum.byCategory, [.push: 2, .pull: 1, .legs: 1])
        XCTAssertEqual(sum.rests, [100, 110, 160])
    }
}

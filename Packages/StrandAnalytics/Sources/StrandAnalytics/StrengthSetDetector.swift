import Foundation

// StrengthSetDetector.swift: finds the sets in a strength workout, with no taps.
//
// EVIDENCE, combined:
//   - Heart rate. A set lifts heart rate off its rest low and it falls back after. Heart rate responds
//     late: it leaves the low a few seconds after the first rep and keeps climbing for `hrDelayS` after
//     the last, so a heart-rate set runs from the low (minus `hrLeadS`) to the peak minus `hrDelayS`.
//   - Wrist motion. A steady run of reps (`MotionRun`, from `RepCounter`) marks a set's edges to the
//     second, where the wrist moves with the weight.
//   - Reps and rhythm: a run needs `minReps` and swings of at least `motionMinG`.
//   - Context: which tuning applies (per exercise when known, else per kind of workout).
// A motion run with heart rate rising after it is a sure set with motion's edges. Heart rate alone is a
// set when it rose clearly (machines where the wrist stays still, or no motion stream). Motion with no
// heart-rate response, or a small heart-rate bump, is UNCERTAIN: shown, not counted, never a precise
// set made up from weak evidence.
//
// PAUSES vs RESTS. A break where heart rate didn't come down `pauseFallBPM`, no longer than
// `maxPauseS`, is a pause inside one set (re-gripping, a breath at lockout) and the two join. Heart-rate
// variability is consulted only there, only in the break (never during movement), and only when the
// beats are clean: a clear rise in RMSSD through the break says the body was resting, so the two stay
// separate. HRV is never needed to find a set.
//
// Every knob is in `StrengthTuning`, learned from your corrections (`StrengthFit`) and overridable in
// Detection settings. Pure and deterministic.

public struct StrengthTuning: Codable, Equatable, Sendable {
    /// Heart rate must rise this far off its rest low (minimum evidence).
    public var riseBPM: Double
    /// And fall this far off a peak for the set to end.
    public var fallBPM: Double
    /// Set duration range.
    public var minWorkS: Int
    public var maxWorkS: Int
    /// Rests shorter than this join the sets either side (heart-rate level).
    public var minRestS: Int
    /// Breaks up to this long, where heart rate didn't drop `pauseFallBPM`, are pauses in one set.
    public var maxPauseS: Int
    public var pauseFallBPM: Double
    /// Heart rate keeps climbing this long after the last rep; and leaves its low this long after the first.
    public var hrDelayS: Int
    public var hrLeadS: Int
    /// A clean RMSSD rise through a break of at least this share marks it a rest. 0 = off.
    public var hrvRebound: Double
    /// Motion: reps for a run to count, smallest swing (g), and how uneven the rhythm may be (ratio).
    public var minReps: Int
    public var motionMinG: Double
    public var rhythmTolerance: Double
    /// Below this confidence a segment is uncertain.
    public var confidenceThreshold: Double

    public init(riseBPM: Double = 11, fallBPM: Double = 8, minWorkS: Int = 12, maxWorkS: Int = 150,
                minRestS: Int = 35, maxPauseS: Int = 30, pauseFallBPM: Double = 5, hrDelayS: Int = 12,
                hrLeadS: Int = 3, hrvRebound: Double = 0.25, minReps: Int = 4, motionMinG: Double = 0.05,
                rhythmTolerance: Double = 1.6, confidenceThreshold: Double = 0.5) {
        self.riseBPM = riseBPM; self.fallBPM = fallBPM; self.minWorkS = minWorkS; self.maxWorkS = maxWorkS
        self.minRestS = minRestS; self.maxPauseS = maxPauseS; self.pauseFallBPM = pauseFallBPM
        self.hrDelayS = hrDelayS; self.hrLeadS = hrLeadS; self.hrvRebound = hrvRebound; self.minReps = minReps
        self.motionMinG = motionMinG; self.rhythmTolerance = rhythmTolerance
        self.confidenceThreshold = confidenceThreshold
    }

    public static func defaults(_ mode: WorkRestSegmenter.Mode) -> StrengthTuning {
        switch mode {
        case .lifting: return StrengthTuning()
        case .assaultBike:
            return StrengthTuning(riseBPM: 12, fallBPM: 8, minWorkS: 8, maxWorkS: 240, minRestS: 10, maxPauseS: 8,
                                  pauseFallBPM: 4, hrDelayS: 8, hrLeadS: 2, minReps: 99)
        case .sprints:
            return StrengthTuning(riseBPM: 12, fallBPM: 8, minWorkS: 6, maxWorkS: 120, minRestS: 15, maxPauseS: 5,
                                  pauseFallBPM: 4, hrDelayS: 10, hrLeadS: 2, minReps: 99)
        }
    }

    public func segmenterParams(_ mode: WorkRestSegmenter.Mode) -> WorkRestSegmenter.Params {
        .init(riseBPM: riseBPM, fallBPM: fallBPM, minWorkS: minWorkS, minRestS: minRestS,
              smoothS: WorkRestSegmenter.params(for: mode).smoothS)
    }

    // Decoding tolerates tunings saved before a field existed.
    public init(from decoder: Decoder) throws {
        let d = StrengthTuning()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        riseBPM = try c.decodeIfPresent(Double.self, forKey: .riseBPM) ?? d.riseBPM
        fallBPM = try c.decodeIfPresent(Double.self, forKey: .fallBPM) ?? d.fallBPM
        minWorkS = try c.decodeIfPresent(Int.self, forKey: .minWorkS) ?? d.minWorkS
        maxWorkS = try c.decodeIfPresent(Int.self, forKey: .maxWorkS) ?? d.maxWorkS
        minRestS = try c.decodeIfPresent(Int.self, forKey: .minRestS) ?? d.minRestS
        maxPauseS = try c.decodeIfPresent(Int.self, forKey: .maxPauseS) ?? d.maxPauseS
        pauseFallBPM = try c.decodeIfPresent(Double.self, forKey: .pauseFallBPM) ?? d.pauseFallBPM
        hrDelayS = try c.decodeIfPresent(Int.self, forKey: .hrDelayS) ?? d.hrDelayS
        hrLeadS = try c.decodeIfPresent(Int.self, forKey: .hrLeadS) ?? d.hrLeadS
        hrvRebound = try c.decodeIfPresent(Double.self, forKey: .hrvRebound) ?? d.hrvRebound
        minReps = try c.decodeIfPresent(Int.self, forKey: .minReps) ?? d.minReps
        motionMinG = try c.decodeIfPresent(Double.self, forKey: .motionMinG) ?? d.motionMinG
        rhythmTolerance = try c.decodeIfPresent(Double.self, forKey: .rhythmTolerance) ?? d.rhythmTolerance
        confidenceThreshold = try c.decodeIfPresent(Double.self, forKey: .confidenceThreshold) ?? d.confidenceThreshold
    }
}

public enum StrengthSetDetector {

    /// The sets in a workout. Uncertain segments are included, flagged.
    public static func detect(hr: [SetCalibration.HRSampleTS], beats: [SetCalibration.Beat], motion: [MotionRun],
                              mode: WorkRestSegmenter.Mode, tuning t: StrengthTuning,
                              bounds: ClosedRange<Int>? = nil) -> [TimelineSet] {
        let h = SetCalibration.smoothed(hr)
        // 1. Heart-rate candidates, shifted for the response delay.
        var seg = WorkRestSegmenter(mode: mode, params: t.segmenterParams(mode))
        for s in hr { seg.ingest(ts: s.ts, bpm: s.bpm) }
        var hrSets: [(span: SetCalibration.Span, rise: Double)] = []
        for iv in seg.intervals {
            let start = iv.startTs - t.hrLeadS
            let end = Swift.max(start + t.minWorkS, iv.endTs - t.hrDelayS)
            hrSets.append((.init(start: start, end: end), riseOf(h, start: start, end: end, delay: t.hrDelayS)))
        }

        // 2. Motion candidates.
        let runs = motion.filter { $0.reps >= t.minReps && ($0.rangeG ?? 1) >= t.motionMinG && $0.end > $0.start }

        // 3. Fuse.
        var out: [TimelineSet] = []
        var usedHR = Set<Int>()
        for r in runs {
            let rise = riseOf(h, start: r.start, end: r.end, delay: t.hrDelayS)
            // The heart-rate set this run explains, if any (its edges lag the run's).
            if let j = hrSets.indices.first(where: { !usedHR.contains($0)
                && hrSets[$0].span.end + t.hrDelayS >= r.start && hrSets[$0].span.start <= r.end + t.hrDelayS }) {
                usedHR.insert(j)
            }
            let hrPart = h.isEmpty ? 0.25 : 0.4 * Swift.min(1, rise / t.riseBPM)
            // Reps at a steady rhythm are lifting; a run whose gaps keep stretching past
            // `rhythmTolerance` times its usual gap (fidgeting, re-racking, walking about) counts for less.
            let repPart = Swift.min(0.45, 0.25 + 0.03 * Double(r.reps)) * (Self.isSteady(r, t.rhythmTolerance) ? 1 : 0.5)
            let conf = Swift.min(1, repPart + hrPart + (h.isEmpty ? 0.1 : 0))
            out.append(TimelineSet(id: "m\(r.start)", start: r.start, end: r.end, reps: r.reps, confidence: conf))
        }
        let motionStreamed = !motion.isEmpty
        for (j, c) in hrSets.enumerated() where !usedHR.contains(j) {
            // A clear rise alone is a set (machines, or no motion stream); a small one is a maybe.
            var conf = 0.3 + 0.5 * Swift.min(1, c.rise / (1.5 * t.riseBPM))
            if !motionStreamed { conf += 0.1 }
            out.append(TimelineSet(id: "h\(c.span.start)", start: c.span.start, end: c.span.end, confidence: Swift.min(1, conf)))
        }
        out.sort { $0.start < $1.start }

        // 4. Pauses inside one set join.
        out = joinPauses(out, h: h, beats: beats, t: t)

        // 5. Plausibility and confidence.
        out = out.compactMap { s in
            var s = s
            if let b = bounds { s.start = Swift.max(b.lowerBound, s.start); s.end = Swift.min(b.upperBound, s.end) }
            guard s.duration >= Swift.max(3, t.minWorkS / 2) else { return nil }
            if s.duration < t.minWorkS || s.duration > t.maxWorkS { s.confidence = (s.confidence ?? 0.5) * 0.6 }
            s.uncertain = (s.confidence ?? 1) < t.confidenceThreshold
            return s
        }
        return out
    }

    /// Fewer than a third of the run's rep gaps are over `tolerance` times its median gap. True when its
    /// rep times weren't recorded.
    static func isSteady(_ r: MotionRun, _ tolerance: Double) -> Bool {
        let t = r.repTimes.sorted()
        guard t.count >= 4 else { return true }
        let gaps = (1..<t.count).map { t[$0] - t[$0 - 1] }
        let median = gaps.sorted()[gaps.count / 2]
        guard median > 0 else { return true }
        return Double(gaps.filter { $0 > tolerance * median }.count) < Double(gaps.count) / 3
    }

    /// Heart rate's rise for a set: from its low in the minute before to its peak by the end plus the
    /// response delay (and a little).
    static func riseOf(_ h: [SetCalibration.HRSampleTS], start: Int, end: Int, delay: Int) -> Double {
        guard let before = SetCalibration.range(h, start - 60, start + 3)?.lo,
              let peak = SetCalibration.range(h, start, end + delay + 10)?.hi else { return 0 }
        return Double(Swift.max(0, peak - before))
    }

    static func joinPauses(_ sets: [TimelineSet], h: [SetCalibration.HRSampleTS], beats: [SetCalibration.Beat],
                           t: StrengthTuning) -> [TimelineSet] {
        var out: [TimelineSet] = []
        for s in sets {
            guard var last = out.last else { out.append(s); continue }
            let gap = s.start - last.end
            if gap <= SetCalibration.minGapS || (gap <= t.maxPauseS && isPause(last, s, h: h, beats: beats, t: t)) {
                last.end = Swift.max(last.end, s.end)
                last.reps = SetTimelineEditor.sumReps([last, s])
                last.confidence = Swift.max(last.confidence ?? 0, s.confidence ?? 0)
                out[out.count - 1] = last
            } else {
                out.append(s)
            }
        }
        return out
    }

    /// Heart rate in the break stayed near the set's peak, and clean HRV doesn't say otherwise.
    static func isPause(_ a: TimelineSet, _ b: TimelineSet, h: [SetCalibration.HRSampleTS],
                        beats: [SetCalibration.Beat], t: StrengthTuning) -> Bool {
        guard let peak = SetCalibration.range(h, a.start, Swift.min(b.start, a.end + t.hrDelayS))?.hi,
              let gapLow = SetCalibration.range(h, a.end + t.hrDelayS / 2, b.start)?.lo ?? SetCalibration.range(h, a.end, b.start)?.lo
        else { return false }   // no heart rate in the break: no evidence of a pause
        let drop = Double(peak - gapLow)
        if drop >= t.pauseFallBPM { return false }
        // Heart rate says pause. Clean HRV through the break can still say rest.
        if t.hrvRebound > 0, let rebound = restRebound(beats, from: a.end, to: b.start), rebound >= t.hrvRebound {
            return false
        }
        return true
    }

    /// RMSSD in the later half of a break against its first 15 s, when both are clean. Nil otherwise.
    public static func restRebound(_ beats: [SetCalibration.Beat], from: Int, to: Int) -> Double? {
        guard to - from >= 24 else { return nil }
        let mid = from + (to - from) / 2
        guard let early = cleanRMSSD(beats, from: from, to: Swift.min(mid, from + 15)),
              let late = cleanRMSSD(beats, from: mid, to: to), early > 0 else { return nil }
        return late / early - 1
    }

    /// RMSSD from at least 10 beats when at least 85% of the successive differences are plausible
    /// (under 200 ms), else nil: a noisy or moving reading is not used.
    public static func cleanRMSSD(_ beats: [SetCalibration.Beat], from: Int, to: Int) -> Double? {
        let w = beats.filter { $0.ts >= from && $0.ts < to }.map(\.ms)
        guard w.count >= 10 else { return nil }
        var sum = 0.0, good = 0
        for i in 1..<w.count {
            let d = Double(w[i] - w[i - 1])
            if abs(d) < 200 { sum += d * d; good += 1 }
        }
        guard Double(good) / Double(w.count - 1) >= 0.85, good >= 8 else { return nil }
        return sqrt(sum / Double(good))
    }
}

// MARK: - Learning from corrections

/// One corrected workout, or the part of one around a single exercise.
public struct StrengthExample: Sendable {
    public let hr: [SetCalibration.HRSampleTS]
    public let beats: [SetCalibration.Beat]
    public let motion: [MotionRun]
    public let truth: [SetCalibration.Span]
    public init(hr: [SetCalibration.HRSampleTS], beats: [SetCalibration.Beat], motion: [MotionRun],
                truth: [SetCalibration.Span]) {
        self.hr = hr; self.beats = beats; self.motion = motion; self.truth = truth
    }

    /// The examples a set of corrected timelines gives: the whole workout, or, for `exercise`, the
    /// stretch from a minute before its first set to a minute after its last.
    public static func from(_ timelines: [SetTimeline], exercise: String? = nil) -> [StrengthExample] {
        timelines.compactMap { t in
            guard let edited = t.edited else { return nil }
            let truth = edited.filter { !$0.uncertain }
            if let exercise {
                let mine = truth.filter { $0.exercise == exercise }
                guard let a = mine.map(\.start).min(), let b = mine.map(\.end).max() else { return nil }
                let lo = a - 60, hi = b + 60
                return StrengthExample(hr: t.hr.filter { $0.ts >= lo && $0.ts <= hi },
                                       beats: t.beats.filter { $0.ts >= lo && $0.ts <= hi },
                                       motion: t.motion.filter { $0.end >= lo && $0.start <= hi },
                                       truth: truth.filter { $0.end >= lo && $0.start <= hi }.map(\.span))
            }
            return StrengthExample(hr: t.hr, beats: t.beats, motion: t.motion, truth: truth.map(\.span))
        }
    }
}

public struct StrengthFit: Codable, Equatable, Sendable {
    public let tuning: StrengthTuning
    public let examples: Int
    /// Missed plus extra sets across the corrected workouts, with the starting tuning and with the fit.
    public let errorsBefore: Int
    public let errorsAfter: Int
    /// Corrected workouts whose set count comes out exactly right, before and after.
    public let exactBefore: Int
    public let exactAfter: Int
}

public enum StrengthLearner {
    /// Candidate values per knob. Fitting walks one knob at a time to the value that best reproduces
    /// your sets (coordinate descent), three passes, with a small pull toward the starting values so
    /// thin evidence doesn't swing everything.
    static let grid: [(WritableKeyPath<StrengthTuning, Double>?, WritableKeyPath<StrengthTuning, Int>?, [Double])] = [
        (\StrengthTuning.riseBPM, nil, [6, 8, 11, 14, 18]),
        (\StrengthTuning.fallBPM, nil, [4, 6, 8, 11]),
        (nil, \StrengthTuning.minWorkS, [6, 10, 15, 25]),
        (nil, \StrengthTuning.maxWorkS, [60, 100, 150, 240]),
        (nil, \StrengthTuning.minRestS, [15, 25, 35, 55]),
        (nil, \StrengthTuning.maxPauseS, [0, 15, 30, 45, 70]),
        (\StrengthTuning.pauseFallBPM, nil, [3, 5, 8, 12]),
        (nil, \StrengthTuning.hrDelayS, [0, 6, 12, 18, 25]),
        (nil, \StrengthTuning.hrLeadS, [0, 3, 8]),
        (\StrengthTuning.hrvRebound, nil, [0, 0.25, 0.5]),
        (nil, \StrengthTuning.minReps, [3, 4, 6]),
        (\StrengthTuning.motionMinG, nil, [0.02, 0.05, 0.1]),
        (\StrengthTuning.rhythmTolerance, nil, [1.3, 1.6, 2.2]),
        (\StrengthTuning.confidenceThreshold, nil, [0.35, 0.5, 0.65]),
    ]

    public static func cost(_ examples: [StrengthExample], _ t: StrengthTuning, mode: WorkRestSegmenter.Mode) -> Double {
        examples.reduce(0) { sum, ex in
            let det = StrengthSetDetector.detect(hr: ex.hr, beats: ex.beats, motion: ex.motion, mode: mode, tuning: t)
                .filter { !$0.uncertain }.map(\.span)
            let e = SetCalibration.errors(det, ex.truth)
            return sum + Double(e.count) + 0.002 * Double(e.edgeS)
        }
    }

    static func prior(_ t: StrengthTuning, _ base: StrengthTuning) -> Double {
        func l(_ a: Double, _ b: Double) -> Double { abs(log(Swift.max(a, 0.5) / Swift.max(b, 0.5))) }
        return 0.05 * (l(t.riseBPM, base.riseBPM) + l(t.fallBPM, base.fallBPM)
                       + l(Double(t.minWorkS), Double(base.minWorkS)) + l(Double(t.maxWorkS), Double(base.maxWorkS))
                       + l(Double(t.minRestS), Double(base.minRestS)) + l(Double(t.maxPauseS + 5), Double(base.maxPauseS + 5))
                       + l(t.pauseFallBPM, base.pauseFallBPM) + l(Double(t.hrDelayS + 3), Double(base.hrDelayS + 3))
                       + l(Double(t.hrLeadS + 2), Double(base.hrLeadS + 2)) + abs(t.hrvRebound - base.hrvRebound)
                       + l(Double(t.minReps), Double(base.minReps)) + abs(t.confidenceThreshold - base.confidenceThreshold))
    }

    /// The tuning that best reproduces your corrected sets, starting from `start`. Nil without examples.
    public static func fit(_ examples: [StrengthExample], mode: WorkRestSegmenter.Mode,
                           start: StrengthTuning) -> StrengthFit? {
        let usable = examples.filter { $0.hr.count >= 30 || !$0.motion.isEmpty }
        guard !usable.isEmpty else { return nil }
        var best = start
        var bestCost = cost(usable, best, mode: mode) + prior(best, start)
        for _ in 0..<3 {
            var improved = false
            for (dk, ik, values) in grid {
                for v in values {
                    var t = best
                    if let dk { t[keyPath: dk] = v }
                    if let ik { t[keyPath: ik] = Int(v) }
                    guard t.minWorkS < t.maxWorkS, t != best else { continue }
                    let c = cost(usable, t, mode: mode) + prior(t, start)
                    if c < bestCost - 1e-9 { best = t; bestCost = c; improved = true }
                }
            }
            if !improved { break }
        }
        func tally(_ t: StrengthTuning) -> (Int, Int) {
            var errs = 0, exact = 0
            for ex in usable {
                let det = StrengthSetDetector.detect(hr: ex.hr, beats: ex.beats, motion: ex.motion, mode: mode, tuning: t)
                    .filter { !$0.uncertain }.map(\.span)
                errs += SetCalibration.errors(det, ex.truth).count
                if det.count == ex.truth.count { exact += 1 }
            }
            return (errs, exact)
        }
        let b = tally(start), a = tally(best)
        return StrengthFit(tuning: best, examples: usable.count, errorsBefore: b.0, errorsAfter: a.0,
                           exactBefore: b.1, exactAfter: a.1)
    }
}

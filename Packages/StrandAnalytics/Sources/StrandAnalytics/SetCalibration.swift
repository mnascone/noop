import Foundation

/// Learns how YOUR sets look in heart rate and HRV from the workouts you've corrected, instead of
/// scaling one sensitivity number.
///
/// Detection is `WorkRestSegmenter` (heart rate rising `riseBPM` off a rest low, falling `fallBPM` off a
/// work peak, at least `minWorkS` of work, rests under `minRestS` joining the sets either side), then an
/// HRV check: a set's RMSSD must sit at least `hrvDrop` below the minute of rest before it, since effort
/// pulls heart-rate variability down and fidgeting or talking mostly doesn't. Each of the five knobs is
/// fitted separately.
///
/// Breaks under `minGapS` always join, so a set is never split by a pause inside it.
///
/// Fitting re-runs detection over every corrected workout's recorded heart rate and beats for each
/// combination on a grid, and keeps the one whose sets best match yours: a missed or extra set costs 1,
/// and set edges a few seconds off cost a little. A small pull toward the defaults keeps one corrected
/// workout from swinging everything. Pure and deterministic.
public enum SetCalibration {

    public struct Span: Codable, Equatable, Hashable, Sendable {
        public var start: Int
        public var end: Int
        public init(start: Int, end: Int) { self.start = start; self.end = end }
        public var duration: Int { end - start }
    }

    public struct HRSampleTS: Codable, Equatable, Sendable {
        public let ts: Int
        public let bpm: Int
        public init(ts: Int, bpm: Int) { self.ts = ts; self.bpm = bpm }
    }

    public struct Beat: Codable, Equatable, Sendable {
        public let ts: Int
        public let ms: Int
        public init(ts: Int, ms: Int) { self.ts = ts; self.ms = ms }
    }

    /// One corrected workout: what was recorded and the sets you say you did.
    public struct Example: Sendable {
        public let hr: [HRSampleTS]
        public let beats: [Beat]
        public let truth: [Span]
        public init(hr: [HRSampleTS], beats: [Beat], truth: [Span]) {
            self.hr = hr; self.beats = beats; self.truth = truth
        }
    }

    /// The learned knobs.
    public struct Tuning: Codable, Equatable, Sendable {
        public var riseBPM: Double
        public var fallBPM: Double
        public var minWorkS: Int
        public var minRestS: Int
        /// 0 = no HRV check.
        public var hrvDrop: Double

        public init(riseBPM: Double, fallBPM: Double, minWorkS: Int, minRestS: Int, hrvDrop: Double) {
            self.riseBPM = riseBPM; self.fallBPM = fallBPM; self.minWorkS = minWorkS
            self.minRestS = minRestS; self.hrvDrop = hrvDrop
        }

        public static func defaults(_ mode: WorkRestSegmenter.Mode) -> Tuning {
            let p = WorkRestSegmenter.params(for: mode)
            return Tuning(riseBPM: p.riseBPM, fallBPM: p.fallBPM, minWorkS: p.minWorkS, minRestS: p.minRestS,
                          hrvDrop: 0)
        }

        public func params(_ mode: WorkRestSegmenter.Mode) -> WorkRestSegmenter.Params {
            let base = WorkRestSegmenter.params(for: mode)
            return .init(riseBPM: riseBPM, fallBPM: fallBPM, minWorkS: minWorkS, minRestS: minRestS,
                         smoothS: base.smoothS)
        }
    }

    public struct Fit: Codable, Equatable, Sendable {
        public let tuning: Tuning
        public let examples: Int
        /// Missed plus extra sets across the corrected workouts, with the defaults and with the fit.
        public let errorsBefore: Int
        public let errorsAfter: Int
        /// Corrected workouts whose set count the defaults and the fit get exactly right.
        public let exactBefore: Int
        public let exactAfter: Int
    }

    // MARK: Detection

    public static func detect(hr: [HRSampleTS], beats: [Beat], mode: WorkRestSegmenter.Mode,
                              tuning: Tuning) -> [WorkRestSegmenter.Interval] {
        var seg = WorkRestSegmenter(mode: mode, params: tuning.params(mode))
        for s in hr { seg.ingest(ts: s.ts, bpm: s.bpm) }
        return joinShortGaps(hrvFilter(seg.intervals, beats: beats, drop: tuning.hrvDrop))
    }

    /// A break shorter than this is a pause inside a set (re-gripping, a breath at the top), never a rest,
    /// whatever has been learned.
    public static let minGapS = 20

    /// Join sets whose break is under `minGapS`.
    public static func joinShortGaps(_ sets: [WorkRestSegmenter.Interval]) -> [WorkRestSegmenter.Interval] {
        var out: [WorkRestSegmenter.Interval] = []
        for s in sets.sorted(by: { $0.startTs < $1.startTs }) {
            if let last = out.last, s.startTs - last.endTs < minGapS {
                out[out.count - 1] = .init(startTs: last.startTs, endTs: max(last.endTs, s.endTs),
                                           peakBpm: max(last.peakBpm, s.peakBpm))
            } else {
                out.append(s)
            }
        }
        return out
    }

    /// Drop sets whose RMSSD isn't at least `drop` below the minute before them. A set without enough
    /// beats either side to judge is kept.
    public static func hrvFilter(_ sets: [WorkRestSegmenter.Interval], beats: [Beat],
                                 drop: Double) -> [WorkRestSegmenter.Interval] {
        guard drop > 0, !beats.isEmpty else { return sets }
        return sets.filter { s in
            guard let work = rmssd(beats, from: s.startTs, to: s.endTs),
                  let rest = rmssd(beats, from: s.startTs - 60, to: s.startTs), rest > 0 else { return true }
            return 1 - work / rest >= drop
        }
    }

    /// RMSSD of the beats in [from, to), from at least 15 beats, ignoring jumps over 200 ms.
    static func rmssd(_ beats: [Beat], from: Int, to: Int) -> Double? {
        let w = beats.filter { $0.ts >= from && $0.ts < to }.map(\.ms)
        guard w.count >= 15 else { return nil }
        var sum = 0.0, n = 0
        for i in 1..<w.count {
            let d = Double(w[i] - w[i - 1])
            if abs(d) < 200 { sum += d * d; n += 1 }
        }
        return n >= 10 ? sqrt(sum / Double(n)) : nil
    }

    // MARK: Scoring

    /// Missed + extra sets, after pairing each of your sets with the detected one it overlaps most (at
    /// least 30% of the shorter of the two).
    public static func errors(_ detected: [Span], _ truth: [Span]) -> (count: Int, edgeS: Int) {
        var used = Set<Int>()
        var matched = 0
        var edge = 0
        for t in truth {
            var best: (i: Int, overlap: Int)?
            for (i, d) in detected.enumerated() where !used.contains(i) {
                let o = min(t.end, d.end) - max(t.start, d.start)
                let need = Int(0.3 * Double(min(t.duration, d.duration)))
                if o > 0, o >= need, o > (best?.overlap ?? 0) { best = (i, o) }
            }
            if let b = best {
                used.insert(b.i)
                matched += 1
                let d = detected[b.i]
                edge += min(60, abs(d.start - t.start)) + min(60, abs(d.end - t.end))
            }
        }
        return ((truth.count - matched) + (detected.count - matched), edge)
    }

    static func cost(_ detected: [Span], _ truth: [Span]) -> Double {
        let e = errors(detected, truth)
        return Double(e.count) + 0.002 * Double(e.edgeS)
    }

    // MARK: Fitting

    static let riseGrid: [Double] = [6, 8, 11, 14, 18]
    static let fallGrid: [Double] = [4, 6, 8, 11]
    static let minWorkGrid: [Int] = [8, 15, 25]
    static let minRestGrid: [Int] = [15, 25, 35, 55, 90]
    static let hrvGrid: [Double] = [0, 0.15, 0.3]

    /// The tuning that best reproduces your corrected sets, or nil without a corrected workout.
    public static func fit(_ examples: [Example], mode: WorkRestSegmenter.Mode) -> Fit? {
        let usable = examples.filter { $0.hr.count >= 60 }
        guard !usable.isEmpty else { return nil }
        let d = Tuning.defaults(mode)
        func spans(_ v: [WorkRestSegmenter.Interval]) -> [Span] { v.map { Span(start: $0.startTs, end: $0.endTs) } }
        // Pull toward the defaults, in log steps, so ties and thin evidence stay near what's known to work.
        func prior(_ t: Tuning) -> Double {
            0.08 * (abs(log(t.riseBPM / d.riseBPM)) + abs(log(t.fallBPM / d.fallBPM))
                    + abs(log(Double(t.minWorkS) / Double(d.minWorkS)))
                    + abs(log(Double(t.minRestS) / Double(d.minRestS))))
                + 0.15 * t.hrvDrop
        }
        var best: (tuning: Tuning, cost: Double)?
        for rise in riseGrid {
            for fall in fallGrid where fall <= rise {
                for minWork in minWorkGrid {
                    for minRest in minRestGrid {
                        let base = Tuning(riseBPM: rise, fallBPM: fall, minWorkS: minWork, minRestS: minRest, hrvDrop: 0)
                        // Segment once per heart-rate setting; the HRV check is a cheap filter on top.
                        let raw: [[WorkRestSegmenter.Interval]] = usable.map { ex in
                            var seg = WorkRestSegmenter(mode: mode, params: base.params(mode))
                            for s in ex.hr { seg.ingest(ts: s.ts, bpm: s.bpm) }
                            return seg.intervals
                        }
                        for gate in hrvGrid {
                            var t = base
                            t.hrvDrop = gate
                            var c = prior(t)
                            for (i, ex) in usable.enumerated() {
                                c += cost(spans(joinShortGaps(hrvFilter(raw[i], beats: ex.beats, drop: gate))), ex.truth)
                            }
                            if best == nil || c < best!.cost - 1e-9 { best = (t, c) }
                        }
                    }
                }
            }
        }
        guard let b = best else { return nil }
        func tally(_ t: Tuning) -> (errors: Int, exact: Int) {
            var errs = 0, exact = 0
            for ex in usable {
                let det = spans(detect(hr: ex.hr, beats: ex.beats, mode: mode, tuning: t))
                errs += errors(det, ex.truth).count
                if det.count == ex.truth.count { exact += 1 }
            }
            return (errs, exact)
        }
        let before = tally(d), after = tally(b.tuning)
        return Fit(tuning: b.tuning, examples: usable.count, errorsBefore: before.errors, errorsAfter: after.errors,
                   exactBefore: before.exact, exactAfter: after.exact)
    }
}

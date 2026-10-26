import Foundation

/// Shared pieces for strength-set detection and editing: the span, sample and beat types the timeline
/// stores, scoring detected sets against yours, and heart-rate helpers for placing edges, adding a
/// missed set and spotting what looks off. Detection itself is `StrengthSetDetector`; learning is
/// `StrengthLearner`. Pure.
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

    /// A break shorter than this can't be a rest at all: heart rate can't have had time to come down.
    public static let minGapS = 8

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
}

// MARK: - Editing helpers: decisions from heart rate and your own sets, not fixed seconds

extension SetCalibration {

    /// Median work and rest in a list of sets, for "about as long as your others".
    public static func typical(_ sets: [Span]) -> (work: Int?, rest: Int?) {
        func median(_ v: [Int]) -> Int? { v.isEmpty ? nil : v.sorted()[v.count / 2] }
        let s = sets.sorted { $0.start < $1.start }
        let rests = s.count > 1 ? (1..<s.count).map { s[$0].start - s[$0 - 1].end } : []
        return (median(s.map(\.duration)), median(rests))
    }

    /// Heart rate smoothed by a 5-sample running median, so one bad reading can't place an edge.
    static func smoothed(_ hr: [HRSampleTS]) -> [HRSampleTS] {
        guard hr.count >= 5 else { return hr }
        return hr.indices.map { i in
            let w = hr[max(0, i - 2)...min(hr.count - 1, i + 2)].map(\.bpm).sorted()
            return HRSampleTS(ts: hr[i].ts, bpm: w[w.count / 2])
        }
    }

    /// The lowest heart rate between two times, and the highest.
    static func range(_ hr: [HRSampleTS], _ from: Int, _ to: Int) -> (lo: Int, hi: Int)? {
        let w = hr.filter { $0.ts >= from && $0.ts <= to }.map(\.bpm)
        guard let lo = w.min(), let hi = w.max() else { return nil }
        return (lo, hi)
    }

    /// A set that wasn't counted, ending about now: from where heart rate last bottomed out (after the
    /// previous set) to where it peaked, or to now while it's still climbing. With no rise to go on, as
    /// long as your typical set.
    public static func setEndingNow(hr: [HRSampleTS], after: Int, now: Int, typicalWork: Int?) -> Span? {
        let h = smoothed(hr.filter { $0.ts > after && $0.ts <= now })
        if h.count >= 10, let lo = h.map(\.bpm).min() {
            // The last moment at the low, so a long flat rest doesn't stretch the set back over it.
            let startIdx = h.lastIndex { $0.bpm <= lo + 1 } ?? 0
            let rising = Array(h[startIdx...])
            if let top = rising.map(\.bpm).max(), top - lo >= 5 {
                let peakIdx = rising.lastIndex { $0.bpm >= top - 1 } ?? rising.count - 1
                // Still near the top: the set may be ending now. Well past it: it ended at the peak.
                let end = rising[peakIdx].ts < now - 15 && (rising.last?.bpm ?? top) <= top - 4
                    ? rising[peakIdx].ts : now
                let start = h[startIdx].ts
                if end - start >= 5 { return Span(start: start, end: end) }
            }
        }
        guard let w = typicalWork, w >= 5 else { return nil }
        let start = max(after + 1, now - w)
        return now - start >= 5 ? Span(start: start, end: now) : nil
    }

    /// Where a dragged edge lands: the nearest heart-rate low within `reach` seconds for a start (a set
    /// starts as heart rate leaves its low), the nearest high for an end. Unchanged without a clear one.
    public static func snap(_ ts: Int, isStart: Bool, hr: [HRSampleTS], reach: Int = 12) -> Int {
        let w = smoothed(hr).filter { abs($0.ts - ts) <= reach }
        guard w.count >= 5, let lo = w.map(\.bpm).min(), let hi = w.map(\.bpm).max(), hi - lo >= 3 else { return ts }
        let target = isStart ? lo : hi
        return w.filter { $0.bpm == target }.min { abs($0.ts - ts) < abs($1.ts - ts) }?.ts ?? ts
    }

    /// Where to cut a set that was really two: the longest stop between its reps when motion counted
    /// them (one clearly longer than its usual rep gap), else where heart rate dips most in its middle,
    /// moved earlier by heart rate's response delay, else its middle.
    public static func splitPoint(start: Int, end: Int, hr: [HRSampleTS], motion: [MotionRun], hrDelayS: Int = 0) -> Int {
        let mid = (start + end) / 2
        let lo = start + (end - start) / 5, hi = end - (end - start) / 5
        guard hi > lo else { return mid }
        let reps = motion.filter { $0.end >= start && $0.start <= end }
            .flatMap(\.repTimes).filter { $0 > Double(start) && $0 < Double(end) }.sorted()
        if reps.count >= 4 {
            let gaps = (1..<reps.count).map { (i: $0, g: reps[$0] - reps[$0 - 1]) }
            let usual = gaps.map(\.g).sorted()[gaps.count / 2]
            if let big = gaps.filter({ $0.i >= 2 && $0.i <= reps.count - 2 }).max(by: { $0.g < $1.g }),
               big.g >= 2 * usual, big.g >= 3 {
                return Int(((reps[big.i - 1] + reps[big.i]) / 2).rounded())
            }
        }
        // The deepest fall from the running peak: heart rate coming down mid-set means you stopped.
        let h = smoothed(hr).filter { $0.ts >= start && $0.ts <= hi }
        var peak = Int.min, best: (ts: Int, drop: Int)?
        for x in h {
            peak = Swift.max(peak, x.bpm)
            guard x.ts >= lo else { continue }
            let drop = peak - x.bpm
            if drop >= 3, drop > (best?.drop ?? 0) { best = (x.ts, drop) }
        }
        if let b = best { return Swift.max(lo, b.ts - hrDelayS) }
        return mid
    }

    public enum Suggestion: Equatable {
        /// Join set `index` with the next: heart rate stayed up through the break.
        case join(index: Int, dropBPM: Int?, gapS: Int)
        /// Set `index` isn't a set: heart rate barely moved and it's far shorter than your others.
        case delete(index: Int, riseBPM: Int?, durationS: Int)
    }

    /// What looks off in a list of sets, judged by heart rate against your tuning and by your own typical
    /// set and rest in this workout. Without heart rate, only by how they compare with your others.
    public static func suggestions(_ sets: [Span], hr: [HRSampleTS], tuning: StrengthTuning) -> [Suggestion] {
        let s = sets.sorted { $0.start < $1.start }
        let h = smoothed(hr)
        let (work, rest) = typical(s)
        var out: [Suggestion] = []
        for i in s.indices {
            let set = s[i]
            // A set: heart rate rises from the minute before to its peak (which can land just after).
            let before = range(h, set.start - 60, set.start)?.lo
            let peak = range(h, set.start, set.end + 20)?.hi
            let rise = before.flatMap { b in peak.map { $0 - b } }
            let shortForYou = work.map { set.duration * 3 < $0 } ?? false
            if let rise {
                if Double(rise) < tuning.riseBPM / 2, shortForYou || set.duration < tuning.minWorkS {
                    out.append(.delete(index: i, riseBPM: rise, durationS: set.duration))
                }
            } else if shortForYou, s.count >= 3 {
                out.append(.delete(index: i, riseBPM: nil, durationS: set.duration))
            }
            guard i + 1 < s.count else { continue }
            let gap = s[i + 1].start - set.end
            if let peakSet = range(h, set.start, min(s[i + 1].start, set.end + 20))?.hi,
               let lo = range(h, set.end, s[i + 1].start)?.lo {
                let drop = peakSet - lo
                if Double(drop) < tuning.pauseFallBPM, gap <= max(tuning.maxPauseS, minGapS) * 2 {
                    out.append(.join(index: i, dropBPM: drop, gapS: gap))
                }
            } else if let r = rest, s.count >= 3, gap * 4 < r {
                out.append(.join(index: i, dropBPM: nil, gapS: gap))
            }
        }
        return out
    }
}

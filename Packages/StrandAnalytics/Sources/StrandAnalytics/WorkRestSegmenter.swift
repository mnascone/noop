import Foundation

// WorkRestSegmenter.swift — live sets / intervals and rests from heart rate alone.
//
// Heart rate climbs while you work and falls while you rest. The segmenter smooths the live bpm, follows
// the lowest point while resting and the highest while working, and flips state when heart rate has moved
// far enough from that extreme:
//   - resting -> working when smoothed HR rises `riseBPM` above the rest trough. The set started at the
//     trough (when HR began to climb).
//   - working -> resting when smoothed HR falls `fallBPM` below the work peak. The set ended at the peak.
// Rest is the time from one set's end (peak) to the next set's start (trough). The live rest timer runs
// from the last peak, so it reads correctly as soon as the drop is confirmed.
//
// Raw heart rate first goes through a 7-sample running median, so a few seconds of optical spike (a hard
// grip on the bar, the strap shifting) can't pass for a set. A set must also run `minWorkS`, and a rest
// shorter than `minRestS` joins the bouts either side into one set: a pause inside a set, or walking to
// the next machine, isn't a new set.
//
// Limits, stated plainly: heart rate lags effort by several seconds, and with short rests (under about a
// minute) it may not fall far enough to split two sets, which then count as one. Very light sets (warm-ups)
// may not raise it enough to count. These are estimates, shown as such.
//
// Pure and deterministic. Timestamps are unix seconds supplied by the caller. iOS-only: no Kotlin twin.

public struct WorkRestSegmenter: Sendable {

    public enum Mode: String, CaseIterable, Sendable {
        case lifting
        case assaultBike
        case sprints
    }

    public struct Params: Sendable, Equatable {
        public var riseBPM: Double
        public var fallBPM: Double
        /// Shorter work bouts are treated as noise.
        public var minWorkS: Int
        /// Rests shorter than this merge the two bouts around them.
        public var minRestS: Int
        /// Smoothing time constant (seconds).
        public var smoothS: Double
    }

    /// Thresholds per mode. `sensitivity` above 1 splits more readily (smaller swings count), below 1 less.
    public static func params(for mode: Mode, sensitivity: Double = 1.0) -> Params {
        let s = min(2.0, max(0.5, sensitivity))
        switch mode {
        case .lifting:
            return Params(riseBPM: 11 / s, fallBPM: 8 / s, minWorkS: 15, minRestS: 35, smoothS: 4)
        case .assaultBike:
            return Params(riseBPM: 12 / s, fallBPM: 8 / s, minWorkS: 8, minRestS: 10, smoothS: 3)
        case .sprints:
            return Params(riseBPM: 12 / s, fallBPM: 8 / s, minWorkS: 6, minRestS: 15, smoothS: 3)
        }
    }

    public struct Interval: Sendable, Equatable {
        public var startTs: Int
        public var endTs: Int
        public var peakBpm: Int
        public var durationS: Int { endTs - startTs }
    }

    public enum Phase: Sendable, Equatable {
        case warmingUp
        case working(since: Int)
        case resting(since: Int)
    }

    public struct Summary: Sendable, Equatable {
        public var count: Int
        public var phase: Phase
        /// Seconds into the current rest, nil when not resting.
        public var currentRestS: Int?
        /// Seconds into the current set, nil when not working.
        public var currentWorkS: Int?
        public var lastRestS: Int?
        public var avgRestS: Int?
        public var longestRestS: Int?
        public var avgWorkS: Int?
        public var totalWorkS: Int

        public init(count: Int, phase: Phase, currentRestS: Int? = nil, currentWorkS: Int? = nil,
                    lastRestS: Int? = nil, avgRestS: Int? = nil, longestRestS: Int? = nil,
                    avgWorkS: Int? = nil, totalWorkS: Int = 0) {
            self.count = count; self.phase = phase; self.currentRestS = currentRestS
            self.currentWorkS = currentWorkS; self.lastRestS = lastRestS; self.avgRestS = avgRestS
            self.longestRestS = longestRestS; self.avgWorkS = avgWorkS; self.totalWorkS = totalWorkS
        }
    }

    /// Within this much of the rest low counts as still sitting at it (smoothed noise is about 1 bpm).
    static let plateauBPM = 1.5

    public let mode: Mode
    public let params: Params

    public private(set) var intervals: [Interval] = []
    public private(set) var phase: Phase = .warmingUp

    private var smoothed: Double?
    private var lastTs: Int?
    /// The last few raw samples, for the spike-rejecting median.
    private var recentRaw: [Int] = []
    static let medianWindow = 7
    private var trough: (ts: Int, v: Double)?
    private var peak: (ts: Int, v: Double, raw: Int)?
    private var currentStart: Int?
    private var currentPeakRaw = 0

    public init(mode: Mode, sensitivity: Double = 1.0) {
        self.mode = mode
        self.params = Self.params(for: mode, sensitivity: sensitivity)
    }

    /// Feed one heart-rate sample. Out-of-order or implausible samples are ignored.
    public mutating func ingest(ts: Int, bpm: Int) {
        guard bpm >= 30, bpm <= 230 else { return }
        if let last = lastTs, ts <= last { return }
        // A long gap starts the median afresh, so stale beats don't hold it back.
        if let last = lastTs, ts - last > 30 { recentRaw.removeAll() }
        recentRaw.append(bpm)
        if recentRaw.count > Self.medianWindow { recentRaw.removeFirst(recentRaw.count - Self.medianWindow) }
        let sortedRaw = recentRaw.sorted()
        let v = Double(sortedRaw[sortedRaw.count / 2])
        if let prev = smoothed, let last = lastTs {
            let dt = Double(min(ts - last, 30))
            let alpha = 1 - exp(-dt / params.smoothS)
            smoothed = prev + alpha * (v - prev)
        } else {
            smoothed = v
        }
        lastTs = ts
        guard let s = smoothed else { return }

        switch phase {
        case .warmingUp, .resting:
            // Follow the LAST moment heart rate sat at its low, not the first: on a plateau the next set
            // starts at the end of it, which is what makes long rests measure correctly.
            if trough == nil || s < trough!.v {
                trough = (ts, s)
            } else if let t = trough, s - t.v < Self.plateauBPM {
                trough = (ts, t.v)
            }
            if let t = trough, s - t.v >= params.riseBPM {
                beginWork(at: t.ts, s: s, ts: ts, raw: bpm)
            }
        case .working:
            currentPeakRaw = max(currentPeakRaw, bpm)
            if peak == nil || s > peak!.v { peak = (ts, s, bpm) }
            if let p = peak, p.v - s >= params.fallBPM {
                endWork(at: p.ts)
                trough = (ts, s)
            }
        }
    }

    private mutating func beginWork(at start: Int, s: Double, ts: Int, raw: Int) {
        // A rest too short to count merges this bout into the previous one.
        if case .resting = phase, let last = intervals.last, start - last.endTs < params.minRestS {
            intervals.removeLast()
            currentStart = last.startTs
            currentPeakRaw = max(last.peakBpm, raw)
        } else {
            currentStart = start
            currentPeakRaw = raw
        }
        peak = (ts, s, raw)
        phase = .working(since: currentStart ?? start)
    }

    private mutating func endWork(at end: Int) {
        guard let start = currentStart else { return }
        if end - start >= params.minWorkS {
            intervals.append(Interval(startTs: start, endTs: end, peakBpm: currentPeakRaw))
            phase = .resting(since: end)
        } else if let last = intervals.last {
            // Noise blip: go back to resting from the previous bout's end.
            phase = .resting(since: last.endTs)
        } else {
            phase = .warmingUp
        }
        currentStart = nil
        peak = nil
    }

    public var rests: [Int] {
        guard intervals.count > 1 else { return [] }
        return (1..<intervals.count).map { intervals[$0].startTs - intervals[$0 - 1].endTs }
    }

    public func summary(now: Int) -> Summary {
        let r = rests
        let works = intervals.map(\.durationS)
        var currentRest: Int?
        var currentWork: Int?
        switch phase {
        case .resting(let since): currentRest = max(0, now - since)
        case .working(let since): currentWork = max(0, now - since)
        case .warmingUp: break
        }
        return Summary(
            count: intervals.count,
            phase: phase,
            currentRestS: currentRest,
            currentWorkS: currentWork,
            lastRestS: r.last,
            avgRestS: r.isEmpty ? nil : Int((Double(r.reduce(0, +)) / Double(r.count)).rounded()),
            longestRestS: r.max(),
            avgWorkS: works.isEmpty ? nil : Int((Double(works.reduce(0, +)) / Double(works.count)).rounded()),
            totalWorkS: works.reduce(0, +))
    }
}

import Foundation

/// Sleep cycles, REM episodes and night structure read from a staged hypnogram.
///
/// A cycle is a stretch of non-REM sleep followed by a REM episode (the Feinberg-Floyd convention). REM
/// runs split by less than `remMergeGapS` of other stages count as one episode, and an episode needs at
/// least `minRemS` of REM to count. REM that comes back after less than `minNremBeforeCycleS` of other
/// sleep belongs to the same REM period, so it closes the same cycle rather than opening a 20-minute one. Typical adult nights run 4 to 6 cycles of 80 to 110 minutes, with the
/// first REM 70 to 120 minutes after falling asleep and REM episodes getting longer toward morning.
///
/// Stages come from heart rate and motion, so these are estimates of the pattern, not polysomnography.
public enum SleepArchitecture {
    public enum Stage: Sendable, Equatable { case wake, light, deep, rem }

    public struct Segment: Sendable, Equatable {
        public let stage: Stage
        public let start: Double
        public let end: Double
        public init(stage: Stage, start: Double, end: Double) {
            self.stage = stage; self.start = start; self.end = end
        }
    }

    public struct Episode: Sendable, Equatable {
        /// Seconds since sleep onset.
        public let start: Double
        public let end: Double
        public var minutes: Double { (end - start) / 60 }
    }

    /// One cycle: non-REM sleep through the REM episode that closes it.
    public struct Cycle: Sendable, Equatable {
        /// Seconds since sleep onset.
        public let start: Double
        public let end: Double
        public let deepMinutes: Double
        public let remMinutes: Double
        /// A wake of 2 minutes or more fell inside this cycle.
        public let interrupted: Bool
        public var minutes: Double { (end - start) / 60 }
    }

    public enum Pattern: String, Sendable, Equatable {
        /// REM gets longer through the night, most of it in the second half.
        case typical
        /// First REM came very early (under 50 min), often after short or poor sleep.
        case earlyRem
        /// First REM came late (over 2 h), often after alcohol, late caffeine or a hard late session.
        case lateRem
        /// Many short REM bits instead of a few solid episodes.
        case fragmentedRem
        /// Fewer cycles than the night's length should give.
        case fewCycles
        /// REM didn't build toward morning.
        case flatRem
    }

    public struct Result: Sendable, Equatable {
        public let sleepOnset: Double
        public let sleepEnd: Double
        public let asleepMinutes: Double
        /// Complete cycles (non-REM then REM).
        public let cycles: Int
        /// Average cycle length in minutes (onset or previous REM end to this REM end).
        public let averageCycleMinutes: Double?
        public let remEpisodes: [Episode]
        /// Minutes from falling asleep to the first REM episode.
        public let remLatencyMinutes: Double?
        public let longestRemMinutes: Double?
        /// Share of all REM that fell in the second half of the sleep period (0...1).
        public let remSecondHalfShare: Double?
        /// Share of deep sleep in the first third of the sleep period (0...1).
        public let deepFirstThirdShare: Double?
        /// Wake bouts of 2 minutes or more after falling asleep and before the final wake.
        public let awakenings: Int
        /// Minutes awake after first falling asleep (wake after sleep onset).
        public let wasoMinutes: Double
        /// Longest stretch asleep without a 2-minute wake.
        public let longestStretchMinutes: Double
        public let patterns: [Pattern]
        /// Each complete cycle in order.
        public let cycleSpans: [Cycle]
        /// Wake bouts of 2 minutes or more between falling asleep and the final wake (seconds since onset).
        public let wakeBouts: [Episode]
        /// Sleep after the last REM episode that didn't reach another REM (an unfinished cycle), minutes.
        public let trailingMinutes: Double
    }

    public static let remMergeGapS: Double = 10 * 60
    public static let minRemS: Double = 3 * 60
    public static let minNremBeforeCycleS: Double = 30 * 60
    public static let awakeningMinS: Double = 2 * 60

    public static func analyze(_ raw: [Segment]) -> Result? {
        let segs = raw.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard let onset = segs.first(where: { $0.stage != .wake })?.start,
              let end = segs.last(where: { $0.stage != .wake })?.end, end - onset >= 60 * 60 else { return nil }
        let inSleep = segs.filter { $0.end > onset && $0.start < end }
            .map { Segment(stage: $0.stage, start: max($0.start, onset), end: min($0.end, end)) }

        // REM episodes: merge runs split by short gaps, then drop slivers.
        var merged: [(start: Double, end: Double, rem: Double)] = []
        for s in inSleep where s.stage == .rem {
            if let last = merged.last, s.start - last.end < remMergeGapS {
                merged[merged.count - 1] = (last.start, s.end, last.rem + (s.end - s.start))
            } else {
                merged.append((s.start, s.end, s.end - s.start))
            }
        }
        let episodes = merged.filter { $0.rem >= minRemS }
            .map { Episode(start: $0.start - onset, end: $0.end - onset) }

        // A cycle ends with each REM episode preceded by enough non-REM sleep.
        var cycles = 0
        var cycleLengths: [Double] = []
        var bounds: [(start: Double, end: Double)] = []
        var cycleStart = 0.0
        for e in episodes {
            let nremBefore = e.start - cycleStart
            if nremBefore >= minNremBeforeCycleS || cycles == 0 {
                cycles += 1
                cycleLengths.append(e.end - cycleStart)
                bounds.append((cycleStart, e.end))
                cycleStart = e.end
            } else if !cycleLengths.isEmpty {
                // Too close to the last one: treat as the same REM period.
                cycleLengths[cycleLengths.count - 1] += e.end - cycleStart
                bounds[bounds.count - 1].end = e.end
                cycleStart = e.end
            }
        }

        let span = end - onset
        let mid = onset + span / 2
        let third = onset + span / 3
        func overlap(_ s: Segment, _ a: Double, _ b: Double) -> Double { max(0, min(s.end, b) - max(s.start, a)) }
        let remTotal = inSleep.filter { $0.stage == .rem }.reduce(0) { $0 + ($1.end - $1.start) }
        let remLate = inSleep.filter { $0.stage == .rem }.reduce(0) { $0 + overlap($1, mid, end) }
        let deepTotal = inSleep.filter { $0.stage == .deep }.reduce(0) { $0 + ($1.end - $1.start) }
        let deepEarly = inSleep.filter { $0.stage == .deep }.reduce(0) { $0 + overlap($1, onset, third) }

        // Awakenings and the longest unbroken stretch.
        var awakenings = 0
        var waso = 0.0
        var longest = 0.0
        var stretchStart = onset
        var wakeRun: (start: Double, end: Double)?
        var bouts: [Episode] = []
        func closeWake() {
            guard let w = wakeRun else { return }
            let len = w.end - w.start
            waso += len
            if len >= awakeningMinS {
                awakenings += 1
                bouts.append(Episode(start: w.start - onset, end: w.end - onset))
                longest = max(longest, w.start - stretchStart)
                stretchStart = w.end
            }
            wakeRun = nil
        }
        for s in inSleep {
            if s.stage == .wake {
                if let w = wakeRun, s.start - w.end < 1 { wakeRun = (w.start, s.end) } else { closeWake(); wakeRun = (s.start, s.end) }
            } else {
                closeWake()
            }
        }
        closeWake()
        longest = max(longest, end - stretchStart)
        let asleep = inSleep.filter { $0.stage != .wake }.reduce(0) { $0 + ($1.end - $1.start) }

        let latency = episodes.first.map { $0.start / 60 }
        var patterns: [Pattern] = []
        if let l = latency, l < 50 { patterns.append(.earlyRem) }
        if let l = latency, l > 120 { patterns.append(.lateRem) }
        let shortEpisodes = episodes.filter { $0.minutes < 8 }.count
        if episodes.count >= 5 && Double(shortEpisodes) / Double(episodes.count) >= 0.6 { patterns.append(.fragmentedRem) }
        let expectedCycles = Int((asleep / 60 / 100).rounded(.down))
        if asleep >= 6 * 3600 && cycles < max(3, expectedCycles - 1) { patterns.append(.fewCycles) }
        let lateShare = remTotal > 0 ? remLate / remTotal : nil
        let builds: Bool = {
            guard episodes.count >= 2, let first = episodes.first, let last = episodes.last else { return false }
            return last.minutes > first.minutes && (lateShare ?? 0) >= 0.55
        }()
        if episodes.count >= 2 && !builds { patterns.append(.flatRem) }
        if patterns.isEmpty && builds { patterns.append(.typical) }

        let spans: [Cycle] = bounds.map { b in
            let a = onset + b.start, z = onset + b.end
            let deep = inSleep.filter { $0.stage == .deep }.reduce(0) { $0 + overlap($1, a, z) }
            let rem = inSleep.filter { $0.stage == .rem }.reduce(0) { $0 + overlap($1, a, z) }
            let broken = bouts.contains { $0.start < b.end && $0.end > b.start }
            return Cycle(start: b.start, end: b.end, deepMinutes: deep / 60, remMinutes: rem / 60, interrupted: broken)
        }
        let trailing = max(0, span - (bounds.last?.end ?? 0)) / 60

        return Result(
            sleepOnset: onset, sleepEnd: end, asleepMinutes: asleep / 60,
            cycles: cycles,
            averageCycleMinutes: cycleLengths.isEmpty ? nil : cycleLengths.reduce(0, +) / Double(cycleLengths.count) / 60,
            remEpisodes: episodes,
            remLatencyMinutes: latency,
            longestRemMinutes: episodes.map(\.minutes).max(),
            remSecondHalfShare: lateShare,
            deepFirstThirdShare: deepTotal > 0 ? deepEarly / deepTotal : nil,
            awakenings: awakenings,
            wasoMinutes: waso / 60,
            longestStretchMinutes: longest / 60,
            patterns: patterns,
            cycleSpans: spans,
            wakeBouts: bouts,
            trailingMinutes: trailing)
    }
}

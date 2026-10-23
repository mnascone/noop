import Foundation
import WhoopProtocol

// BandWakePromotion.swift — count the time NOOP calls asleep but the strap itself says you were awake.
//
// THE PROBLEM. Both stagers lean on wrist motion for wake, so lying awake and still reads as sleep. Against
// 31 human-scored PSG nights the shipped recipe calls about 4% of the night wake where the truth is about 9%,
// catching roughly 31% of real wake (see `SleepStager.bandStateWakeVetoEnabled`).
//
// THE SIGNAL. A WHOOP 5.0/MG reports its own per-second sleep state (persisted v18 @81 high nibble:
// 0 wake / 1 still / 2 asleep / 3 up), an independent scorer NOOP does not derive. WHOOP 4.0 has none, so
// this is a no-op there.
//
// TWO RULES, both only ever turning sleep INTO wake, never the reverse:
//   1. Strong (default on): a run of at least `strongMinRunS` the strap scores wake (0) or up (3) becomes
//      wake. Runs this long are a real awakening, not a turn-over.
//   2. Quiet (opt-in): a run of at least `quietMinRunS` the strap scores "still" (1, not "asleep") whose median
//      heart rate sits at least `quietHrRatio` above the night's own sleeping heart rate becomes wake. This is
//      the lying-awake-still case. It rests on two unvalidated readings (that "still" is distinct from asleep,
//      and that awake-still heart rate runs higher), so it ships off and its would-be effect is always traced.
//
// SAFETY. Band samples older than `maxCarryS` are not carried across a gap (a dropped stream must not paint a
// whole night awake). If the rules together would turn more than `maxPromotedFraction` of the night's sleep
// into wake, nothing is changed: that much disagreement means the band is unusable that night, not that the
// wearer was awake for half of it.
//
// Pure, deterministic. iOS personal build: no Kotlin twin. Not medical advice.

public enum BandWakePromotion {

    public static let bandWake = 0
    public static let bandStill = 1
    public static let bandAsleep = 2
    public static let bandUp = 3

    public static let strongMinRunS = 180
    public static let quietMinRunS = 600
    public static let quietHrRatio = 1.08
    /// A band sample counts for an epoch only if it is at most this old at the epoch's start.
    public static let maxCarryS = 90
    public static let maxPromotedFraction = 0.5

    static var epochS: Double { SleepStager.epochS }

    public struct Result: Equatable, Sendable {
        public var stages: [StageSegment]
        /// Sleep seconds turned to wake by each rule.
        public var strongSeconds: Int
        public var quietSeconds: Int
        /// What the quiet rule WOULD turn to wake (equals `quietSeconds` when it is on).
        public var quietCandidateSeconds: Int
        /// Set when the safety cap declined the whole night.
        public var declined: Bool
    }

    /// Promote sleep to wake in `stages` (tiling `[start, end]`) per the rules above.
    public static func apply(_ stages: [StageSegment], start: Int, end: Int,
                             band: [(ts: Int, state: Int)], hr: [HRSample],
                             includeQuiet: Bool) -> Result {
        let unchanged = Result(stages: stages, strongSeconds: 0, quietSeconds: 0,
                               quietCandidateSeconds: 0, declined: false)
        guard !band.isEmpty, !stages.isEmpty, end > start else { return unchanged }
        let n = max(1, Int(ceil(Double(end - start) / epochS)))
        func epochStart(_ i: Int) -> Int { start + Int(Double(i) * epochS) }
        func epochEnd(_ i: Int) -> Int { i == n - 1 ? end : epochStart(i + 1) }

        // Stage label per epoch.
        var labels = [String](repeating: "wake", count: n)
        var si = 0
        let sorted = stages.sorted { $0.start < $1.start }
        for i in 0..<n {
            let t = epochStart(i)
            while si < sorted.count - 1 && sorted[si].end <= t { si += 1 }
            labels[i] = sorted[si].stage
        }
        let isSleep = labels.map { !SleepStageVocabulary.isWake($0) }
        let sleepEpochs = isSleep.filter { $0 }.count
        guard sleepEpochs > 0 else { return unchanged }

        // Band state per epoch, -1 where there is no fresh sample.
        let bandSorted = band.filter { $0.ts >= start - maxCarryS && $0.ts < end }.sorted { $0.ts < $1.ts }
        var states = [Int](repeating: -1, count: n)
        var bi = 0
        var last: (ts: Int, state: Int)?
        for i in 0..<n {
            let eEnd = epochEnd(i)
            while bi < bandSorted.count && bandSorted[bi].ts < eEnd {
                last = bandSorted[bi]
                bi += 1
            }
            if let l = last, epochStart(i) - l.ts <= maxCarryS { states[i] = l.state }
        }

        // Per-epoch mean heart rate (for the quiet rule).
        var hrSum = [Double](repeating: 0, count: n)
        var hrCnt = [Int](repeating: 0, count: n)
        for s in hr where s.ts >= start && s.ts < end {
            let i = min(n - 1, Int(Double(s.ts - start) / epochS))
            hrSum[i] += Double(s.bpm)
            hrCnt[i] += 1
        }
        let epochHr: [Double?] = (0..<n).map { hrCnt[$0] > 0 ? hrSum[$0] / Double(hrCnt[$0]) : nil }

        var promoteStrong = [Bool](repeating: false, count: n)
        var promoteQuiet = [Bool](repeating: false, count: n)

        // Rule 1: runs of band wake/up.
        forEachRun(states, where: { $0 == bandWake || $0 == bandUp }) { range in
            let dur = epochEnd(range.upperBound - 1) - epochStart(range.lowerBound)
            guard dur >= strongMinRunS else { return }
            for i in range where isSleep[i] { promoteStrong[i] = true }
        }

        // Rule 2: runs of band "still" with raised heart rate.
        let sleepHrs = (0..<n).compactMap { isSleep[$0] && !promoteStrong[$0] ? epochHr[$0] : nil }.sorted()
        if sleepHrs.count >= 20 {
            let baseline = sleepHrs[sleepHrs.count / 4]   // the night's sleeping heart rate (25th percentile)
            forEachRun(states, where: { $0 == bandStill }) { range in
                let dur = epochEnd(range.upperBound - 1) - epochStart(range.lowerBound)
                guard dur >= quietMinRunS else { return }
                let runHrs = range.compactMap { epochHr[$0] }.sorted()
                guard runHrs.count * 2 >= range.count else { return }   // need heart rate for most of it
                let median = runHrs[runHrs.count / 2]
                guard median >= baseline * quietHrRatio else { return }
                for i in range where isSleep[i] && !promoteStrong[i] { promoteQuiet[i] = true }
            }
        }

        func seconds(_ mask: [Bool]) -> Int {
            (0..<n).reduce(0) { $0 + (mask[$1] ? epochEnd($1) - epochStart($1) : 0) }
        }
        let strongS = seconds(promoteStrong)
        let quietCandS = seconds(promoteQuiet)
        let quietS = includeQuiet ? quietCandS : 0
        guard strongS + quietS > 0 else {
            return Result(stages: stages, strongSeconds: 0, quietSeconds: 0,
                          quietCandidateSeconds: quietCandS, declined: false)
        }
        let promotedEpochs = (0..<n).filter { promoteStrong[$0] || (includeQuiet && promoteQuiet[$0]) }.count
        if Double(promotedEpochs) / Double(sleepEpochs) > maxPromotedFraction {
            return Result(stages: stages, strongSeconds: 0, quietSeconds: 0,
                          quietCandidateSeconds: quietCandS, declined: true)
        }

        for i in 0..<n where promoteStrong[i] || (includeQuiet && promoteQuiet[i]) { labels[i] = "wake" }
        var out: [StageSegment] = []
        for i in 0..<n {
            if let lastSeg = out.last, lastSeg.stage == labels[i] {
                out[out.count - 1].end = epochEnd(i)
            } else {
                out.append(StageSegment(start: epochStart(i), end: epochEnd(i), stage: labels[i]))
            }
        }
        return Result(stages: out, strongSeconds: strongS, quietSeconds: quietS,
                      quietCandidateSeconds: quietCandS, declined: false)
    }

    /// Session-level convenience: returns the corrected session (efficiency recomputed) and the result.
    public static func apply(_ session: SleepSession, band: [(ts: Int, state: Int)], hr: [HRSample],
                             includeQuiet: Bool) -> (SleepSession, Result) {
        let r = apply(session.stages, start: session.start, end: session.end, band: band, hr: hr,
                      includeQuiet: includeQuiet)
        guard r.stages != session.stages else { return (session, r) }
        let eff = SleepStager.efficiency(start: session.start, end: session.end, stages: r.stages)
        return (SleepSession(start: session.start, end: session.end, efficiency: eff, stages: r.stages,
                             restingHR: session.restingHR, avgHRV: session.avgHRV, hrOnly: session.hrOnly), r)
    }

    /// One trace line per night: what each rule moved, so the effect can be judged on real nights.
    public static func traceLine(startTs: Int, result r: Result, quietOn: Bool) -> String {
        "bandWake: startTs=\(startTs) strongMin=\(r.strongSeconds / 60) "
            + "quietMin=\(r.quietSeconds / 60) quietCandidateMin=\(r.quietCandidateSeconds / 60) "
            + "quietOn=\(quietOn) declined=\(r.declined)"
    }

    private static func forEachRun(_ states: [Int], where pred: (Int) -> Bool, _ body: (Range<Int>) -> Void) {
        var i = 0
        while i < states.count {
            guard pred(states[i]) else { i += 1; continue }
            var j = i
            while j < states.count && pred(states[j]) { j += 1 }
            body(i..<j)
            i = j
        }
    }
}

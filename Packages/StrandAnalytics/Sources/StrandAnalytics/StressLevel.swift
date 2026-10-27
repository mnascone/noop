import Foundation

// StressLevel.swift: an all-day stress level on a 0-100 scale, one value per 3-minute epoch, in the
// manner of Garmin's (Firstbeat) all-day stress.
//
// What is borrowed, and from where:
//   - The scale and bands: 0-25 rest, 26-50 low, 51-75 medium, 76-100 high, one value every 3 minutes
//     (Garmin's published bands; the 3-minute epoch is what Garmin's exported stress series uses).
//   - Activity first: an epoch spent moving is not scored as stress (Firstbeat classifies physical
//     activity before stress or recovery; Garmin shows those stretches as activity, not stress).
//   - Stress as heart rate up and HRV down against YOUR resting level, not a population norm
//     (Firstbeat's definition: sympathetic dominance, elevated HR relative to the person's baseline,
//     HRV reduced from their resting level).
//   - Heart rate carries most of the weight. An independent study of Garmin's score found it tracks HR
//     (within-person r 0.74) far more than RMSSD (r -0.41), and this app's own comparison found daytime
//     wrist RMSSD artifact-prone, so HRV here only adjusts the level, capped, and only from clean beats.
//   - The scale's anchor: heart rate 15 bpm over your calm awake floor reads 66, the top third, which is
//     where this codebase's comparison against Oura's stress signal put "high" on its 0-3 scale
//     (`DaytimeStress.baselineRelativeHighMarginBPM`). Garmin's High (76) then needs about 18-20 bpm, and
//     ordinary sitting a few bpm over the floor reads Low, as Garmin's typical days do.
//
// The morning factors (last night's resting HR and HRV against your 30-day normal, the 0-3 score) shift
// the day's level a little: a stressed morning reads slightly higher all day, a well-recovered one lower.
//
// Pure and deterministic: the same samples and baseline always give the same epochs, which is what lets
// a stored day read back exactly as it was shown.

public enum StressLevel {

    // MARK: Constants

    /// One value per this many seconds, aligned to the clock.
    public static let epochSeconds = 180
    /// Heart-rate samples an epoch needs to be scored (a third of it at one a second).
    public static let minHRSamples = 60
    /// Beats an epoch needs for its RMSSD to count, and the share of beat-to-beat changes that must look
    /// physiological (under 200 ms). Below either, HRV says nothing for that epoch.
    public static let minBeats = 60
    public static let minCleanShare = 0.85
    /// Heart rate this far over the calm floor reads 66 (two thirds up the scale): the validated margin.
    public static let highMarginBPM = 15.0
    /// The most the HRV term can move the level, in the same units as `highMarginBPM` fractions.
    public static let maxHRVTerm = 0.6
    /// Weight of HRV: halving RMSSD from typical counts like this share of the high margin.
    public static let hrvWeight = 0.5
    /// How much the morning factors move the whole day: each 0-3 point away from 1.5 is this share of
    /// the high margin (so a High morning, 3.0, adds about 2 bpm's worth: under 10 points mid-scale).
    public static let morningWeight = 0.10
    /// Movement: an epoch is activity when at least this share of its motion readings are over the walk
    /// floor (0.20 g, the codebase's calibrated walking threshold).
    public static let motionThreshold = 0.20
    public static let activeShare = 0.25
    /// Heart rate this far over the calm floor is taken as exertion, not stress, when the strap felt some
    /// movement too (`lightMotionShare`): an unlogged lift moves the wrist less than walking does. Heart
    /// rate alone never makes a stretch activity: high heart rate while still is what stress is.
    public static let exertionOverCalmBPM = 30.0
    /// The share of an epoch's motion samples over `motionThreshold` that counts as some movement.
    public static let lightMotionShare = 0.10
    /// The calm floor is never taken below resting heart rate plus this: a floor at sleeping heart rate
    /// (a night the sleep wasn't recognised) would make ordinary sitting read as stress.
    public static let calmOverRestingMinBPM = 4.0
    /// After activity heart rate takes a while to come down (Firstbeat's "recovery from activity"): the
    /// following epochs are "after activity", not scored, while heart rate is still this far over the calm
    /// floor, for up to `afterActivityBase` epochs plus one per epoch of activity, at most
    /// `afterActivityMaxEpochs` (half an hour).
    public static let afterActivityBPM = 10.0
    public static let afterActivityBase = 2
    public static let afterActivityMaxEpochs = 10
    /// The calm floor: this percentile of the awake, still epochs' mean heart rates.
    public static let calmPercentile = 0.10

    // The curve: level = 100 / (1 + e^-(a z + b)), with z = 0 at the calm floor reading 15 (rest) and
    // z = 1 (calm + 15 bpm) reading 66. Calm + 5 reads about 28, + 10 about 47, + 20 about 81.
    static let curveB = log(15.0 / 85.0)
    static let curveA = log(66.0 / 34.0) - curveB

    // MARK: Types

    public struct HRPoint: Equatable, Sendable {
        public let ts: Int
        public let bpm: Int
        public init(ts: Int, bpm: Int) { self.ts = ts; self.bpm = bpm }
    }

    public struct Beat: Equatable, Sendable {
        public let ts: Int
        public let ms: Int
        public init(ts: Int, ms: Int) { self.ts = ts; self.ms = ms }
    }

    public struct Motion: Equatable, Sendable {
        public let ts: Int
        public let intensity: Double
        public init(ts: Int, intensity: Double) { self.ts = ts; self.intensity = intensity }
    }

    public enum State: String, Codable, Sendable {
        /// Scored.
        case measured
        /// Moving: not stress.
        case active
        /// Heart rate still coming down from activity: not scored.
        case afterActivity
        /// Too little heart rate (off wrist, strap not syncing, a gap).
        case noData
    }

    public enum Band: String, Codable, CaseIterable, Sendable {
        case rest, low, medium, high
        public init(level: Int) {
            switch level {
            case ..<26: self = .rest
            case ..<51: self = .low
            case ..<76: self = .medium
            default: self = .high
            }
        }
    }

    public struct Epoch: Codable, Equatable, Sendable {
        /// Start, unix seconds, a multiple of `epochSeconds`.
        public let start: Int
        public let state: State
        /// 0-100 when measured.
        public let level: Int?
        public let meanHR: Double?
        public let rmssd: Double?
        public let asleep: Bool

        public init(start: Int, state: State, level: Int?, meanHR: Double?, rmssd: Double?, asleep: Bool) {
            self.start = start; self.state = state; self.level = level
            self.meanHR = meanHR; self.rmssd = rmssd; self.asleep = asleep
        }

        public var band: Band? { level.map(Band.init(level:)) }
    }

    /// What the levels are scored against. Kept with each day so it reads back the same.
    public struct Baseline: Codable, Equatable, Sendable {
        /// Calm awake heart rate: the floor your heart rate sits at when you're awake and still.
        public let calmHR: Double
        /// Typical clean awake RMSSD, when known.
        public let typicalRMSSD: Double?
        /// This morning's factors, 0-3 (1.5 is your normal), when known.
        public let morning: Double?
        /// Where the calm floor came from: "history" (your recent days), "today", or "resting".
        public let source: String

        public init(calmHR: Double, typicalRMSSD: Double?, morning: Double?, source: String) {
            self.calmHR = calmHR; self.typicalRMSSD = typicalRMSSD; self.morning = morning; self.source = source
        }
    }

    // MARK: Scoring

    /// The level for a stretch with this mean heart rate (and RMSSD when clean), 0-100.
    public static func level(meanHR: Double, rmssd: Double?, baseline b: Baseline) -> Int {
        var z = (meanHR - b.calmHR) / highMarginBPM
        if let r = rmssd, let t = b.typicalRMSSD, r > 0, t > 0 {
            z += Swift.min(maxHRVTerm, Swift.max(-maxHRVTerm, hrvWeight * log2(t / r)))
        }
        if let m = b.morning { z += morningWeight * (m - 1.5) }
        let v = 100 / (1 + exp(-(curveA * z + curveB)))
        return Int(Swift.min(100, Swift.max(0, v)).rounded())
    }

    /// RMSSD of a run of beats when it's clean enough to trust, else nil.
    public static func cleanRMSSD(_ ms: [Int]) -> Double? {
        let rr = ms.filter { $0 >= 300 && $0 <= 2000 }
        guard rr.count >= minBeats else { return nil }
        var sq: [Double] = []
        sq.reserveCapacity(rr.count)
        var total = 0
        for i in 1..<rr.count {
            let d = Double(rr[i] - rr[i - 1])
            total += 1
            if abs(d) < 200 { sq.append(d * d) }
        }
        guard total > 0, Double(sq.count) / Double(total) >= minCleanShare else { return nil }
        return (sq.reduce(0, +) / Double(sq.count)).squareRoot()
    }

    public struct Inputs {
        public var hr: [HRPoint]
        public var beats: [Beat]
        public var motion: [Motion]
        /// Logged workouts, and walking, running or cycling the phone saw: always activity.
        public var workouts: [ClosedRange<Int>]
        /// Sleep: still scored (it's mostly rest), marked asleep, and left out of the calm floor.
        public var sleeps: [ClosedRange<Int>]

        public init(hr: [HRPoint], beats: [Beat] = [], motion: [Motion] = [],
                    workouts: [ClosedRange<Int>] = [], sleeps: [ClosedRange<Int>] = []) {
            self.hr = hr; self.beats = beats; self.motion = motion; self.workouts = workouts; self.sleeps = sleeps
        }
    }

    /// Per-epoch raw readings before scoring.
    public struct Raw: Equatable, Sendable {
        public let start: Int
        public let meanHR: Double?
        public let rmssd: Double?
        public let moving: Bool
        public let asleep: Bool
        /// Some movement: under walking, enough to say a high heart rate came from effort.
        public var stirring: Bool = false
    }

    /// Group the samples into clock-aligned epochs over `from..<to`.
    public static func raw(from: Int, to: Int, _ x: Inputs) -> [Raw] {
        let first = (from / epochSeconds) * epochSeconds
        guard to > first else { return [] }
        let n = (to - first + epochSeconds - 1) / epochSeconds
        var hrSum = [Double](repeating: 0, count: n), hrN = [Int](repeating: 0, count: n)
        var beats = [[Int]](repeating: [], count: n)
        var mAct = [Int](repeating: 0, count: n), mN = [Int](repeating: 0, count: n)
        func idx(_ ts: Int) -> Int? {
            let i = (ts - first) / epochSeconds
            return ts >= first && i < n ? i : nil
        }
        for s in x.hr { if let i = idx(s.ts), s.bpm > 25, s.bpm < 230 { hrSum[i] += Double(s.bpm); hrN[i] += 1 } }
        for b in x.beats { if let i = idx(b.ts) { beats[i].append(b.ms) } }
        for m in x.motion { if let i = idx(m.ts) { mN[i] += 1; if m.intensity > motionThreshold { mAct[i] += 1 } } }
        return (0..<n).map { i in
            let s = first + i * epochSeconds
            let span = s...(s + epochSeconds - 1)
            let inWorkout = x.workouts.contains { $0.overlaps(span) }
            let share = mN[i] > 0 ? Double(mAct[i]) / Double(mN[i]) : 0
            let movingByMotion = share >= activeShare
            let asleep = x.sleeps.contains { $0.contains(s + epochSeconds / 2) }
            return Raw(start: s, meanHR: hrN[i] >= minHRSamples ? hrSum[i] / Double(hrN[i]) : nil,
                       rmssd: cleanRMSSD(beats[i]), moving: inWorkout || movingByMotion, asleep: asleep,
                       stirring: share >= lightMotionShare)
        }
    }

    /// The calm heart rate to score against: `floor`, never under resting heart rate plus
    /// `calmOverRestingMinBPM`.
    public static func calmHR(floor: Double, restingHR: Double?) -> Double {
        guard let r = restingHR, r > 25 else { return floor }
        return Swift.max(floor, r + calmOverRestingMinBPM)
    }

    /// The calm floor from epochs: the `calmPercentile` of awake, still epochs' mean heart rate. Nil
    /// under 20 such epochs (an hour).
    public static func calmFloor(_ raws: [Raw]) -> (hr: Double?, rmssd: Double?) {
        let still = raws.filter { !$0.moving && !$0.asleep }
        let hrs = still.compactMap(\.meanHR).sorted()
        let rm = still.compactMap(\.rmssd).sorted()
        let hr = hrs.count >= 20 ? hrs[Int(Double(hrs.count - 1) * calmPercentile)] : nil
        let r = rm.count >= 10 ? rm[rm.count / 2] : nil
        return (hr, r)
    }

    /// Score epochs against a baseline.
    public static func score(_ raws: [Raw], baseline b: Baseline) -> [Epoch] {
        var out: [Epoch] = []
        out.reserveCapacity(raws.count)
        var sinceActive = Int.max
        var activeRun = 0
        func allowance() -> Int { Swift.min(afterActivityMaxEpochs, afterActivityBase + activeRun) }
        for r in raws {
            guard let hr = r.meanHR else {
                out.append(Epoch(start: r.start, state: r.moving ? .active : .noData, level: nil, meanHR: nil,
                                 rmssd: nil, asleep: r.asleep))
                if r.moving { if sinceActive != 0 { activeRun = 0 }; sinceActive = 0; activeRun += 1 }
                else if sinceActive != .max { sinceActive += 1 }
                continue
            }
            // Hard exertion: heart rate far up with some movement, short of what reads as walking.
            let exertion = !r.asleep && r.stirring && hr > b.calmHR + exertionOverCalmBPM
            if r.moving || exertion {
                if sinceActive != 0 { activeRun = 0 }
                sinceActive = 0
                activeRun += 1
                out.append(Epoch(start: r.start, state: .active, level: nil, meanHR: hr, rmssd: r.rmssd, asleep: r.asleep))
                continue
            }
            if sinceActive != .max { sinceActive += 1 }
            if sinceActive <= allowance(), hr > b.calmHR + afterActivityBPM {
                out.append(Epoch(start: r.start, state: .afterActivity, level: nil, meanHR: hr, rmssd: r.rmssd,
                                 asleep: r.asleep))
                continue
            }
            // Back down: the recovery is over.
            if sinceActive != .max, hr <= b.calmHR + afterActivityBPM { sinceActive = .max }
            out.append(Epoch(start: r.start, state: .measured, level: level(meanHR: hr, rmssd: r.rmssd, baseline: b),
                             meanHR: hr, rmssd: r.rmssd, asleep: r.asleep))
        }
        return out
    }

    // MARK: Day summary

    public struct Summary: Equatable, Sendable {
        /// Mean level across measured epochs (Garmin's "overall stress level").
        public let average: Int?
        /// Mean across measured awake epochs.
        public let awakeAverage: Int?
        public let highest: Epoch?
        /// Seconds in each band, and moving, and with no reading.
        public let seconds: [Band: Int]
        public let activeSeconds: Int
        public let unmeasuredSeconds: Int
        public let measured: Int
    }

    public static func summary(_ epochs: [Epoch]) -> Summary {
        let m = epochs.filter { $0.state == .measured && $0.level != nil }
        let awake = m.filter { !$0.asleep }
        func avg(_ e: [Epoch]) -> Int? {
            e.isEmpty ? nil : Int((Double(e.compactMap(\.level).reduce(0, +)) / Double(e.count)).rounded())
        }
        var secs: [Band: Int] = [:]
        for e in m { if let b = e.band { secs[b, default: 0] += epochSeconds } }
        return Summary(average: avg(m), awakeAverage: avg(awake),
                       highest: awake.max { ($0.level ?? 0) < ($1.level ?? 0) },
                       seconds: secs,
                       activeSeconds: epochs.filter { $0.state == .active || $0.state == .afterActivity }.count * epochSeconds,
                       unmeasuredSeconds: epochs.filter { $0.state == .noData }.count * epochSeconds,
                       measured: m.count)
    }

    /// Merge freshly scored epochs into stored ones: a stored reading stays as it was (so what you saw is
    /// what you see again), and only epochs that had no reading take a new one, as late-synced data fills
    /// them in. `rescoreAll` replaces everything, for when the baseline itself changed.
    public static func merge(stored: [Epoch], fresh: [Epoch], rescoreAll: Bool = false) -> [Epoch] {
        guard !rescoreAll else { return fresh }
        var byStart: [Int: Epoch] = [:]
        for e in stored { byStart[e.start] = e }
        for e in fresh {
            // A reading stays, except that activity learned later (a workout logged afterwards) wins:
            // that stretch wasn't stress.
            if let old = byStart[e.start], old.state != .noData,
               !(old.state == .measured && (e.state == .active || e.state == .afterActivity)) { continue }
            byStart[e.start] = e
        }
        return byStart.values.sorted { $0.start < $1.start }
    }
}

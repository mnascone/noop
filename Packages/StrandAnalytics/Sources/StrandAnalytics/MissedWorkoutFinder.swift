import Foundation

// MissedWorkoutFinder.swift — workouts found afterwards in the strap's own data.
//
// Live auto tracking (`LiveWorkoutSuggestionEngine`) needs the phone: its motion classifier, GPS, place
// geofences and the realtime heart-rate stream. With the phone left behind, the strap still records heart
// rate, wrist motion and its step counter, and hands them over at the next sync. This finds the workouts in
// that data, with the same thresholds the live path uses where it has an equivalent:
//
//   - Walks and runs from the strap's step counter, a minute at a time: 50+ steps a minute is walking,
//     under 25 is still (the phone pedometer's cuts, `LiveWorkoutSuggestionEngine.stepWalkPerMin` /
//     `stepStillPerMin`). A walk ends at its last walking minute once 3 still minutes follow, or 5 minutes
//     pass without a walking one. At least 15 minutes for a walk (a walk to class or around the office
//     isn't a workout), 3 for a run. A run is a bout the strap's gait
//     class mostly calls running, or at 140+ steps a minute.
//   - Other workouts (a lift, a game) from heart rate: resting + 20 bpm, the lifting margin a pinned gym
//     uses. Stretches of it hold across dips of up to 5 minutes (rest between sets, a bench), stretches of
//     5+ minutes join across breaks of up to 20 minutes (an intermission), and the whole must last 10+
//     minutes with heart rate up for at least half of it. Wrist motion must confirm it when there is any:
//     sitting with a fast heart rate is stress, not a workout. These are candidates only: the caller
//     confirms each by where the phone was (a visit to one of your places), since heart rate and motion
//     can't tell a lift from a busy, stressful hour.
//
// A bout counts once its end is settled: the data runs at least the end condition past it. Anything that
// overlaps an excluded span (a logged workout, one already offered, sleep) is left out. Pure: no I/O, no
// clock. All times are unix seconds.
public enum MissedWorkoutFinder {

    public struct StepMinute: Equatable, Sendable {
        /// Minute start, a multiple of 60.
        public let start: Int
        public let steps: Int
        /// Of them, the ones the strap's gait class called running.
        public let runSteps: Int
        public init(start: Int, steps: Int, runSteps: Int = 0) {
            self.start = start; self.steps = steps; self.runSteps = runSteps
        }
    }

    public struct HRPoint: Equatable, Sendable {
        public let ts: Int
        public let bpm: Int
        public init(ts: Int, bpm: Int) { self.ts = ts; self.bpm = bpm }
    }

    public struct MotionPoint: Equatable, Sendable {
        public let ts: Int
        /// The per-record gravity delta (`WorkoutDetector.activitySeries`).
        public let intensity: Double
        public init(ts: Int, intensity: Double) { self.ts = ts; self.intensity = intensity }
    }

    public enum Kind: String, Equatable, Sendable, Codable {
        case walk, run, effort
    }

    public struct Found: Equatable, Sendable {
        public let start: Int
        public let end: Int
        public let kind: Kind
        public let avgBpm: Int?
        public let peakBpm: Int?

        public init(start: Int, end: Int, kind: Kind, avgBpm: Int?, peakBpm: Int?) {
            self.start = start; self.end = end; self.kind = kind; self.avgBpm = avgBpm; self.peakBpm = peakBpm
        }
    }

    // MARK: Tunables

    public static let walkStepsPerMin = 50
    public static let stillStepsPerMin = 25
    public static let stillMinutesEnd = 3
    public static let noWalkMinutesEnd = 5
    public static let walkMinS = 15 * 60
    public static let runMinS = 3 * 60
    public static let runStepsPerMin = 140
    public static let runShare = 0.5

    public static let effortMarginBPM = 20
    public static let effortGapS = 5 * 60
    public static let effortPieceMinS = 5 * 60
    public static let effortJoinS = 20 * 60
    public static let effortMinS = 10 * 60
    public static let effortElevatedShare = 0.5
    /// Mean wrist motion over the bout confirming it (`AutoWorkoutDetector.motionConfirmMean`).
    public static let motionConfirmMean = 0.05
    /// Data past a bout's end before it counts as over.
    public static let walkSettleS = 3 * 60
    public static let effortSettleS = 10 * 60

    // MARK: Finding

    /// Every settled bout in the data, oldest first, none overlapping `exclude`.
    public static func find(steps: [StepMinute], hr: [HRPoint], motion: [MotionPoint], restingBpm: Int,
                            exclude: [ClosedRange<Int>], dataEnd: Int) -> [Found] {
        let hrSorted = hr.sorted { $0.ts < $1.ts }
        let walks = walkBouts(steps, dataEnd: dataEnd)
        let efforts = effortBouts(hrSorted, motion: motion, restingBpm: restingBpm, dataEnd: dataEnd)
        var out: [Found] = []
        // An effort that is mostly walking is the walk (or run); otherwise the effort wins and the walks
        // inside it (around a court, between machines) are part of it.
        for e in efforts {
            let walked = walks.reduce(0) { $0 + overlap($1.range, e) }
            if Double(walked) >= 0.5 * Double(e.upperBound - e.lowerBound) { continue }
            out.append(found(e, .effort, hrSorted))
        }
        let kept = out.map { $0.start...$0.end }
        for w in walks where !kept.contains(where: { overlap(w.range, $0) > 0 }) {
            out.append(found(w.range, w.run ? .run : .walk, hrSorted))
        }
        return out
            .filter { f in !exclude.contains { $0.overlaps(f.start...f.end) } }
            .sorted { $0.start < $1.start }
    }

    // MARK: Walks

    struct WalkBout { let range: ClosedRange<Int>; let run: Bool }

    static func walkBouts(_ minutes: [StepMinute], dataEnd: Int) -> [WalkBout] {
        let byStart = Dictionary(minutes.map { ($0.start, $0) }, uniquingKeysWith: { a, _ in a })
        guard let first = minutes.map(\.start).min(), let last = minutes.map(\.start).max() else { return [] }
        var out: [WalkBout] = []
        var start: Int?, lastWalking = 0, still = 0, steps = 0, run = 0, walkingMins: [Int] = []
        func close() {
            guard let s = start else { return }
            let end = lastWalking + 60
            let isRun = steps > 0 && (Double(run) / Double(steps) >= runShare
                                      || median(walkingMins) >= runStepsPerMin)
            if end - s >= walkMinS || (isRun && end - s >= runMinS) {
                out.append(WalkBout(range: s...end, run: isRun))
            }
            start = nil; still = 0; steps = 0; run = 0; walkingMins = []
        }
        var m = (first / 60) * 60
        while m <= last {
            let n = byStart[m]?.steps ?? 0
            if n >= walkStepsPerMin {
                if start == nil { start = m }
                lastWalking = m
                still = 0
                steps += n
                run += byStart[m]?.runSteps ?? 0
                walkingMins.append(n)
            } else if start != nil {
                still = n < stillStepsPerMin ? still + 1 : 0
                if still >= stillMinutesEnd || m - lastWalking >= noWalkMinutesEnd * 60 { close() }
            }
            m += 60
        }
        // Still walking where the data stops: not over yet, unless the data runs on past it.
        if start != nil, dataEnd - (lastWalking + 60) >= walkSettleS { close() }
        return out
    }

    // MARK: Efforts

    static func effortBouts(_ hr: [HRPoint], motion: [MotionPoint], restingBpm: Int,
                            dataEnd: Int) -> [ClosedRange<Int>] {
        let floor = restingBpm + effortMarginBPM
        let up = hr.filter { $0.bpm >= floor }.map(\.ts)
        guard !up.isEmpty else { return [] }
        // Stretches of raised heart rate, holding across short dips.
        var pieces: [ClosedRange<Int>] = []
        var s = up[0], e = up[0]
        for t in up.dropFirst() {
            if t - e > effortGapS { pieces.append(s...e); s = t }
            e = t
        }
        pieces.append(s...e)
        pieces = pieces.filter { $0.upperBound - $0.lowerBound >= effortPieceMinS }
        // Join pieces across a break.
        var joined: [[ClosedRange<Int>]] = []
        for p in pieces {
            if let lastGroup = joined.last, let prev = lastGroup.last, p.lowerBound - prev.upperBound <= effortJoinS {
                joined[joined.count - 1].append(p)
            } else {
                joined.append([p])
            }
        }
        let motionSorted = motion.sorted { $0.ts < $1.ts }
        return joined.compactMap { group -> ClosedRange<Int>? in
            guard let a = group.first?.lowerBound, let b = group.last?.upperBound else { return nil }
            guard b - a >= effortMinS, dataEnd - b >= effortSettleS else { return nil }
            // Heart rate up for at least half of the time inside the pieces.
            let inside = hr.filter { x in group.contains { $0.contains(x.ts) } }
            let raised = inside.filter { $0.bpm >= floor }.count
            guard !inside.isEmpty, Double(raised) / Double(inside.count) >= effortElevatedShare else { return nil }
            let moves = motionSorted.filter { (a...b).contains($0.ts) }.map(\.intensity)
            if !moves.isEmpty, moves.reduce(0, +) / Double(moves.count) < motionConfirmMean { return nil }
            return a...b
        }
    }

    // MARK: Helpers

    static func found(_ r: ClosedRange<Int>, _ kind: Kind, _ hr: [HRPoint]) -> Found {
        let inside = hr.filter { r.contains($0.ts) }.map(\.bpm)
        return Found(start: r.lowerBound, end: r.upperBound, kind: kind,
                     avgBpm: inside.isEmpty ? nil : Int((Double(inside.reduce(0, +)) / Double(inside.count)).rounded()),
                     peakBpm: inside.max())
    }

    static func overlap(_ a: ClosedRange<Int>, _ b: ClosedRange<Int>) -> Int {
        max(0, min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound))
    }

    static func median(_ v: [Int]) -> Int {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s[s.count / 2]
    }
}

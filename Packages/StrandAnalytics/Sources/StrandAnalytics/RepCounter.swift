import Foundation

/// Sets and reps from wrist motion (accelerometer + gyroscope at ~100 Hz).
///
/// A set is a stretch where the wrist keeps rotating (gyro RMS over `enterDps`), ending after
/// `quietExitS` below `exitDps`. Inside a set the accelerometer is high-passed, projected onto its main
/// axis of movement (so it works whatever the strap's orientation and whichever way the bar moves), and
/// each full swing past ±`hysteresis` × its spread counts as one rep, no faster than `minRepS`.
///
/// Only RHYTHMIC motion counts: reps must come at a steady tempo (each rep within `gapRatioMax` of the
/// one before and of the set's median, no faster than `minRepS`) and at a similar size (no swing under
/// `minAmpShare` of the median). The longest such run inside the motion is the set; fidgeting, racking
/// the weight, walking between machines and adjusting the seat around it are left out, and a run of
/// fewer than `minReps` is no set at all. Heart rate is the app layer's second check (a set should push
/// it up), since motion alone can't tell a light warm-up swing from a working set.
///
/// WHAT COUNTS AS A REP: one full there-and-back excursion of the wrist along the set's main line of
/// movement (out past +`hysteresis` x its spread and back past the opposite side), taking `minRepS` to
/// `maxRepS`, at least `minAmpShare` of the set's typical size, and in step with the reps either side.
/// That covers the movements where the wrist travels with the weight: presses (bench, overhead, push-ups,
/// dips), curls, rows, pull-ups and pulldowns, raises, and squats, lunges and deadlifts holding the
/// weight. Each set is labelled `vertical` (its line of movement within ~45 degrees of gravity: presses,
/// curls, squats, pull-ups) or `horizontal` (rows, flyes, cable work across the body).
///
/// WHAT DOESN'T: walking between stations (an arm swinging across the body faster than `walkTempoS` a
/// swing), racking, unracking, loading plates and adjusting a seat (single swings, out of step),
/// small fidgets (under `minAmpShare`), holds and carries (no excursion), and machines where the hands
/// stay still (leg press, leg extension, leg curl, calf raise), which the wrist can't see.
///
/// WHAT MAKES A SET (`consolidate`): runs less than `mergeGapS` apart are one set with a pause in it
/// (a rest-pause, re-gripping, a breath at the top), and a set needs `minSetReps`.
/// Experimental: the thresholds are first guesses to tune against real sessions.
public struct RepCounter: Sendable {
    public struct Sample: Sendable, Equatable {
        public let t: Double
        public let ax, ay, az: Double   // g
        public let gx, gy, gz: Double   // deg/s
        public init(t: Double, ax: Double, ay: Double, az: Double, gx: Double, gy: Double, gz: Double) {
            self.t = t; self.ax = ax; self.ay = ay; self.az = az; self.gx = gx; self.gy = gy; self.gz = gz
        }
    }

    public struct RepSet: Sendable, Equatable {
        public let start: Double
        public let end: Double
        public let reps: Int
        /// Average seconds per rep.
        public let tempoS: Double?
        public var movement: Movement = .unknown
        /// Typical size of one rep's swing, in g (peak to trough of the filtered signal).
        public var rangeG: Double?

        public init(start: Double, end: Double, reps: Int, tempoS: Double?,
                    movement: Movement = .unknown, rangeG: Double? = nil) {
            self.start = start; self.end = end; self.reps = reps; self.tempoS = tempoS
            self.movement = movement; self.rangeG = rangeG
        }
    }

    /// The set's main line of movement against gravity.
    public enum Movement: String, Sendable, Equatable {
        /// Within about 45 degrees of vertical: presses, curls, squats, deadlifts, pull-ups, dips.
        case vertical
        /// Across: rows, flyes, cable work, lateral swings.
        case horizontal
        case unknown
    }

    /// What the counter saw in a stretch of motion, for drawing it: the filtered signal along the main
    /// axis (`rateHz` samples from `t0`), each swing it judged, and which it counted.
    public struct Analysis: Sendable, Equatable {
        public let t0: Double
        public let trace: [Double]
        /// Times of swings that counted as reps.
        public let counted: [Double]
        /// Times of swings left out (out of step, too small, or outside the steady run).
        public let rejected: [Double]
        public let movement: Movement
        public let tempoS: Double?
        public let rangeG: Double?
    }

    public static let rateHz = 25.0
    public static let enterDps = 30.0
    public static let exitDps = 15.0
    public static let quietExitS = 6.0
    public static let minSetS = 6.0
    public static let minRepS = 0.8
    public static let maxRepS = 8.0
    public static let hysteresis = 0.45
    public static let minReps = 3
    /// Neighbouring reps, and each rep against the run's median, may differ in length by at most this
    /// factor (1.6 = a rep can take 60% longer or 38% less time than the one before).
    public static let gapRatioMax = 1.6
    /// A swing smaller than this share of the run's median swing is noise, and ends the run.
    public static let minAmpShare = 0.4
    /// Runs closer together than this (seconds) are one set.
    public static let mergeGapS = 30.0
    /// A horizontal run quicker than this per swing is an arm swinging while walking.
    public static let walkTempoS = 1.3
    /// Fewer reps than this, after joining, isn't a set.
    public static let minSetReps = 4

    /// An arm swinging while walking: across the body, at walking pace.
    public static func looksLikeWalking(_ s: RepSet) -> Bool {
        s.movement == .horizontal && (s.tempoS ?? .infinity) < walkTempoS
    }

    /// Runs of reps as sets: walking dropped, runs under `mergeGapS` apart joined, short ones dropped.
    public static func consolidate(_ runs: [RepSet]) -> [RepSet] {
        var out: [RepSet] = []
        for r in runs where !looksLikeWalking(r) {
            if let last = out.last, r.start - last.end < mergeGapS {
                let reps = last.reps + r.reps
                let tempo: Double? = {
                    guard let a = last.tempoS, let b = r.tempoS else { return last.tempoS ?? r.tempoS }
                    return (a * Double(last.reps) + b * Double(r.reps)) / Double(reps)
                }()
                out[out.count - 1] = RepSet(start: last.start, end: r.end, reps: reps, tempoS: tempo,
                                            movement: last.movement, rangeG: last.rangeG ?? r.rangeG)
            } else {
                out.append(r)
            }
        }
        return out.filter { $0.reps >= minSetReps }
    }

    private struct Point { let t: Double; let a: (Double, Double, Double); let g: Double }

    private var points: [Point] = []
    private var acc: (n: Int, t: Double, ax: Double, ay: Double, az: Double, g: Double) = (0, 0, 0, 0, 0, 0)
    private var gyroWindow: [Double] = []
    private var inSet = false
    private var setStartIndex = 0
    private var quietSince: Double?
    public private(set) var sets: [RepSet] = []
    private var lastAnalysis: Analysis?

    public init() {}

    /// Reps in the set happening now, nil between sets.
    public var currentReps: Int? {
        guard inSet else { return nil }
        return Self.analyze(Array(points[setStartIndex...]))?.counted.count ?? 0
    }

    public var inProgressStart: Double? { inSet ? points[setStartIndex].t : nil }

    public mutating func feed(_ samples: [Sample]) {
        let per = max(1, Int((100 / Self.rateHz).rounded()))
        for s in samples {
            acc.n += 1; acc.t += s.t; acc.ax += s.ax; acc.ay += s.ay; acc.az += s.az
            acc.g += sqrt(s.gx * s.gx + s.gy * s.gy + s.gz * s.gz)
            if acc.n == per {
                let n = Double(per)
                push(Point(t: acc.t / n, a: (acc.ax / n, acc.ay / n, acc.az / n), g: acc.g / n))
                acc = (0, 0, 0, 0, 0, 0)
            }
        }
    }

    /// Close an open set (the workout ended).
    public mutating func finish() {
        if inSet { closeSet(at: points.count - 1) }
    }

    private mutating func push(_ p: Point) {
        points.append(p)
        gyroWindow.append(p.g * p.g)
        let win = Int(1.5 * Self.rateHz)
        if gyroWindow.count > win { gyroWindow.removeFirst(gyroWindow.count - win) }
        let rms = sqrt(gyroWindow.reduce(0, +) / Double(gyroWindow.count))
        if !inSet {
            if rms >= Self.enterDps {
                inSet = true
                setStartIndex = max(0, points.count - win)
                quietSince = nil
            } else if points.count > Int(30 * Self.rateHz) {
                // Keep the buffer short between sets.
                points.removeFirst(points.count - Int(5 * Self.rateHz))
            }
        } else {
            if rms < Self.exitDps {
                if quietSince == nil { quietSince = p.t }
                if let q = quietSince, p.t - q >= Self.quietExitS {
                    let endIndex = points.lastIndex { $0.t <= q } ?? points.count - 1
                    closeSet(at: endIndex)
                }
            } else {
                quietSince = nil
            }
        }
    }

    private mutating func closeSet(at endIndex: Int) {
        defer {
            inSet = false
            quietSince = nil
            let keep = min(points.count, Int(5 * Self.rateHz))
            points = Array(points.suffix(keep))
            gyroWindow.removeAll()
        }
        guard endIndex > setStartIndex else { return }
        let seg = Array(points[setStartIndex...endIndex])
        guard let first = seg.first, let last = seg.last, last.t - first.t >= Self.minSetS,
              let a = Self.analyze(seg) else { return }
        lastAnalysis = a
        guard a.counted.count >= Self.minReps else { return }
        let tempo = a.tempoS ?? 0
        sets.append(RepSet(start: (a.counted.first ?? first.t) - tempo, end: a.counted.last ?? last.t,
                           reps: a.counted.count, tempoS: a.tempoS, movement: a.movement, rangeG: a.rangeG))
    }

    /// The analysis of the set in progress, or of the last stretch of motion when between sets.
    public var currentAnalysis: Analysis? {
        if inSet { return Self.analyze(Array(points[setStartIndex...])) }
        return lastAnalysis
    }

    /// Full swings along the segment's main axis, keeping only the longest rhythmic run of them.
    private static func analyze(_ seg: [Point]) -> Analysis? {
        guard seg.count >= Int(2 * rateHz), let t0 = seg.first?.t else { return nil }
        // High-pass: subtract a 4 s moving mean (gravity and slow drift), then smooth over 0.2 s.
        let longW = Int(4 * rateHz), shortW = max(1, Int(0.2 * rateHz))
        func movingMean(_ x: [Double], _ w: Int) -> [Double] {
            var out = [Double](repeating: 0, count: x.count)
            var sum = 0.0
            var lo = 0
            for i in 0..<x.count {
                sum += x[i]
                if i - lo + 1 > w { sum -= x[lo]; lo += 1 }
                // A trailing mean is enough for counting swings: the phase lag is the same for every rep.
                out[i] = sum / Double(i - lo + 1)
            }
            return out
        }
        let raw = [seg.map { $0.a.0 }, seg.map { $0.a.1 }, seg.map { $0.a.2 }]
        let gravity = raw.map { $0.reduce(0, +) / Double($0.count) }
        let axes = raw.map { x -> [Double] in
            let base = movingMean(x, longW)
            let hp = zip(x, base).map { $0 - $1 }
            return movingMean(hp, shortW)
        }
        // Main axis of movement: power iteration on the 3x3 covariance.
        var cov = [[Double]](repeating: [0, 0, 0], count: 3)
        for i in 0..<seg.count {
            for r in 0..<3 { for c in 0..<3 { cov[r][c] += axes[r][i] * axes[c][i] } }
        }
        var v = [1.0, 1.0, 1.0]
        for _ in 0..<30 {
            var nv = [0.0, 0.0, 0.0]
            for r in 0..<3 { for c in 0..<3 { nv[r] += cov[r][c] * v[c] } }
            let n = sqrt(nv.reduce(0) { $0 + $1 * $1 })
            guard n > 0 else { return nil }
            v = nv.map { $0 / n }
        }
        let movement = movementOf(axis: v, gravity: gravity)
        let proj = (0..<seg.count).map { i in axes[0][i] * v[0] + axes[1][i] * v[1] + axes[2][i] * v[2] }
        let mean = proj.reduce(0, +) / Double(proj.count)
        let centred = proj.map { $0 - mean }
        let sd = sqrt(centred.reduce(0) { $0 + $1 * $1 } / Double(centred.count))
        guard sd > 0.01 else {
            return Analysis(t0: t0, trace: centred, counted: [], rejected: [], movement: movement,
                            tempoS: nil, rangeG: nil)
        }
        let h = hysteresis * sd
        // A swing = out past +h then back past -h. Each carries its time and its size.
        var swings: [(t: Double, amp: Double)] = []
        var high = false
        var hi = -Double.infinity, lo = Double.infinity
        for (i, x) in centred.enumerated() {
            let t = seg[i].t
            hi = max(hi, x); lo = min(lo, x)
            if !high, x > h {
                high = true
            } else if high, x < -h {
                high = false
                if let last = swings.last, t - last.t < minRepS { continue }
                swings.append((t, hi - lo))
                hi = -Double.infinity; lo = Double.infinity
            }
        }
        let run = rhythmicRun(swings)
        let counted = run.range.map { Array(swings[$0]).map(\.t) } ?? []
        let rejected = swings.enumerated().filter { !(run.range?.contains($0.offset) ?? false) }.map(\.element.t)
        let ranges = run.range.map { swings[$0].map(\.amp).sorted() } ?? []
        return Analysis(t0: t0, trace: centred, counted: counted, rejected: rejected, movement: movement,
                        tempoS: run.tempo, rangeG: ranges.isEmpty ? nil : ranges[ranges.count / 2])
    }

    /// Vertical when the line of movement is within ~45 degrees of gravity (|cos| over 0.7).
    static func movementOf(axis v: [Double], gravity g: [Double]) -> Movement {
        let gn = sqrt(g.reduce(0) { $0 + $1 * $1 })
        guard gn > 0.3 else { return .unknown }
        let cosine = abs(zip(v, g).reduce(0) { $0 + $1.0 * $1.1 }) / gn
        return cosine >= 0.7 ? .vertical : .horizontal
    }

    /// The longest run of reps at a steady tempo and a similar size. Each rep's gap (time since the one
    /// before) must sit within `gapRatioMax` of the previous gap and of the run's median, and inside
    /// [`minRepS`, `maxRepS`]; each rep's swing must be at least `minAmpShare` of the median swing.
    static func rhythmicRun(_ reps: [(t: Double, amp: Double)]) -> (reps: Int, tempo: Double?, start: Double?,
                                                                   end: Double?, range: ClosedRange<Int>?) {
        guard reps.count >= 2 else { return (reps.count, nil, nil, nil, nil) }
        let amps = reps.map(\.amp).sorted()
        let medAmp = amps[amps.count / 2]
        let gaps = (1..<reps.count).map { reps[$0].t - reps[$0 - 1].t }
        let usable = gaps.filter { $0 >= minRepS && $0 <= maxRepS }.sorted()
        guard !usable.isEmpty else { return (1, nil, nil, nil, nil) }
        let medGap = usable[usable.count / 2]
        func steady(_ g: Double) -> Bool {
            g >= minRepS && g <= maxRepS && g <= medGap * gapRatioMax && g >= medGap / gapRatioMax
        }
        var best = (from: 0, to: 0)   // rep indices, inclusive
        var from = 0
        for i in 1..<reps.count {
            let g = gaps[i - 1]
            let prevOK = i < 2 || (g <= gaps[i - 2] * gapRatioMax && g >= gaps[i - 2] / gapRatioMax)
            let ampOK = reps[i].amp >= medAmp * minAmpShare
            if !(steady(g) && ampOK && (i - 1 == from || prevOK)) {
                from = i
            }
            if i - from > best.to - best.from { best = (from, i) }
        }
        let count = best.to - best.from + 1
        guard count >= 2 else { return (1, nil, nil, nil, nil) }
        let runGaps = Array(gaps[best.from..<best.to])
        let tempo = runGaps.reduce(0, +) / Double(runGaps.count)
        return (count, tempo, reps[best.from].t - tempo, reps[best.to].t, best.from...best.to)
    }
}

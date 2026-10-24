import Foundation

/// Sets and reps from wrist motion (accelerometer + gyroscope at ~100 Hz).
///
/// A set is a stretch where the wrist keeps rotating (gyro RMS over `enterDps`), ending after
/// `quietExitS` below `exitDps`. Inside a set the accelerometer is high-passed, projected onto its main
/// axis of movement (so it works whatever the strap's orientation and whichever way the bar moves), and
/// each full swing past ±`hysteresis` × its spread counts as one rep, no faster than `minRepS`.
///
/// Works for movements where the wrist travels with the weight (presses, curls, rows, pull-ups, squats
/// and deadlifts holding a bar). It can't see reps when the hands stay still (leg press, leg extension).
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
    }

    public static let rateHz = 25.0
    public static let enterDps = 30.0
    public static let exitDps = 15.0
    public static let quietExitS = 6.0
    public static let minSetS = 6.0
    public static let minRepS = 0.8
    public static let maxRepS = 8.0
    public static let hysteresis = 0.45
    public static let minReps = 2

    private struct Point { let t: Double; let a: (Double, Double, Double); let g: Double }

    private var points: [Point] = []
    private var acc: (n: Int, t: Double, ax: Double, ay: Double, az: Double, g: Double) = (0, 0, 0, 0, 0, 0)
    private var gyroWindow: [Double] = []
    private var inSet = false
    private var setStartIndex = 0
    private var quietSince: Double?
    public private(set) var sets: [RepSet] = []

    public init() {}

    /// Reps in the set happening now, nil between sets.
    public var currentReps: Int? {
        guard inSet else { return nil }
        return Self.countReps(Array(points[setStartIndex...]))?.reps ?? 0
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
              let counted = Self.countReps(seg), counted.reps >= Self.minReps else { return }
        sets.append(RepSet(start: first.t, end: last.t, reps: counted.reps, tempoS: counted.tempo))
    }

    /// Full swings along the segment's main axis.
    private static func countReps(_ seg: [Point]) -> (reps: Int, tempo: Double?)? {
        guard seg.count >= Int(2 * rateHz) else { return nil }
        // High-pass: subtract a 4 s moving mean (gravity and slow drift), then smooth over 0.2 s.
        let longW = Int(4 * rateHz), shortW = max(1, Int(0.2 * rateHz))
        func movingMean(_ x: [Double], _ w: Int) -> [Double] {
            var out = [Double](repeating: 0, count: x.count)
            var sum = 0.0
            var lo = 0
            for i in 0..<x.count {
                sum += x[i]
                if i - lo + 1 > w { sum -= x[lo]; lo += 1 }
                // Centre the window by averaging forward and backward later; a trailing mean is enough
                // for counting swings, since the phase lag is the same for every rep.
                out[i] = sum / Double(i - lo + 1)
            }
            return out
        }
        let axes = [seg.map { $0.a.0 }, seg.map { $0.a.1 }, seg.map { $0.a.2 }].map { x -> [Double] in
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
        let proj = (0..<seg.count).map { i in axes[0][i] * v[0] + axes[1][i] * v[1] + axes[2][i] * v[2] }
        let mean = proj.reduce(0, +) / Double(proj.count)
        let sd = sqrt(proj.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(proj.count))
        guard sd > 0.01 else { return (0, nil) }
        let h = hysteresis * sd
        // A rep = a swing above +h followed by one below -h.
        var reps = 0
        var high = false
        var lastRepT: Double?
        var gaps: [Double] = []
        for (i, x) in proj.enumerated() {
            let t = seg[i].t
            if !high, x - mean > h {
                high = true
            } else if high, x - mean < -h {
                high = false
                if let l = lastRepT {
                    let gap = t - l
                    guard gap >= minRepS else { continue }
                    if gap <= maxRepS { gaps.append(gap) }
                }
                reps += 1
                lastRepT = t
            }
        }
        let tempo = gaps.isEmpty ? nil : gaps.reduce(0, +) / Double(gaps.count)
        return (reps, tempo)
    }
}

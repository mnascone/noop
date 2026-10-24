import Foundation

/// Whether heart rate has come down enough between lifting sets to start the next one.
///
/// Auto mode sets the "ready" heart rate from how far heart rate rose in the last set: ready once it has
/// recovered a share of the rise above resting, "almost" a little above that. The share needed scales with
/// today's HRV against your baseline: a suppressed HRV asks for more recovery before the next set, a high
/// one for less. Custom mode uses two fixed heart rates instead. A minimum rest caps the light at
/// "almost" until it has passed, so a quick drop doesn't call the next set too early.
public enum SetReadiness {
    public enum Light: String, Sendable, Equatable { case red, yellow, green }

    public struct Config: Sendable, Equatable {
        public var auto: Bool
        /// Custom mode: ready at or below this heart rate.
        public var greenBpm: Int
        /// Custom mode: almost ready at or below this heart rate.
        public var yellowBpm: Int
        /// The light stays at most yellow until this much rest has passed.
        public var minRestS: Int
        /// The rest the timer counts toward.
        public var targetRestS: Int
        public init(auto: Bool = true, greenBpm: Int = 110, yellowBpm: Int = 125,
                    minRestS: Int = 45, targetRestS: Int = 120) {
            self.auto = auto; self.greenBpm = greenBpm; self.yellowBpm = yellowBpm
            self.minRestS = minRestS; self.targetRestS = targetRestS
        }
    }

    public struct Thresholds: Sendable, Equatable {
        public let greenBpm: Int
        public let yellowBpm: Int
        /// Share of the set's rise above resting that may remain at "ready" (auto mode), else nil.
        public let remainingShare: Double?
    }

    public struct Reading: Sendable, Equatable {
        public let light: Light
        public let thresholds: Thresholds
        /// Seconds left until the target rest, zero once reached.
        public let restLeftS: Int
        /// Share of the last set's heart-rate rise already recovered (0...1), nil without a set peak.
        public let recovered: Double?
    }

    /// The share of the set's rise allowed to remain at ready. 0.45 at baseline HRV, down to 0.32 when
    /// HRV is well below baseline (more recovery needed), up to 0.55 when it is well above.
    public static func remainingShare(hrvRatio: Double?) -> Double {
        guard let r = hrvRatio, r.isFinite, r > 0 else { return 0.45 }
        return min(0.55, max(0.32, 0.45 + 0.35 * (r - 1)))
    }

    /// A set peak to measure recovery from when the last set's own peak isn't known: 75% of heart-rate
    /// reserve, with max heart rate from age (Tanaka, 208 - 0.7 x age).
    public static func assumedPeak(restingBpm: Int, age: Int?) -> Int {
        let maxHr = 208 - 0.7 * Double(age ?? 35)
        return Int((Double(restingBpm) + 0.75 * (maxHr - Double(restingBpm))).rounded())
    }

    public static func thresholds(config: Config, restingBpm: Int, setPeakBpm: Int?, age: Int?,
                                  hrvRatio: Double?) -> Thresholds {
        guard config.auto else {
            let g = config.greenBpm
            return Thresholds(greenBpm: g, yellowBpm: max(g + 1, config.yellowBpm), remainingShare: nil)
        }
        let peak = max(restingBpm + 20, setPeakBpm ?? assumedPeak(restingBpm: restingBpm, age: age))
        let rise = Double(peak - restingBpm)
        let share = remainingShare(hrvRatio: hrvRatio)
        let green = Int((Double(restingBpm) + rise * share).rounded())
        let yellow = Int((Double(restingBpm) + rise * min(0.85, share + 0.2)).rounded())
        return Thresholds(greenBpm: green, yellowBpm: max(green + 1, yellow), remainingShare: share)
    }

    public static func read(config: Config, currentBpm: Int, restS: Int, restingBpm: Int, setPeakBpm: Int?,
                            age: Int?, hrvRatio: Double?) -> Reading {
        let t = thresholds(config: config, restingBpm: restingBpm, setPeakBpm: setPeakBpm, age: age,
                           hrvRatio: hrvRatio)
        var light: Light = currentBpm <= t.greenBpm ? .green : (currentBpm <= t.yellowBpm ? .yellow : .red)
        if restS < config.minRestS, light == .green { light = .yellow }
        let recovered: Double? = setPeakBpm.flatMap { p in
            let rise = Double(p - restingBpm)
            guard rise > 5 else { return nil }
            return min(1, max(0, Double(p - currentBpm) / rise))
        }
        return Reading(light: light, thresholds: t, restLeftS: max(0, config.targetRestS - restS),
                       recovered: recovered)
    }
}

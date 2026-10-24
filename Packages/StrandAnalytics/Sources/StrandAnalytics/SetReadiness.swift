import Foundation

/// Whether heart rate has come down enough between lifting sets to start the next one.
///
/// Auto mode sets the "ready" heart rate from how far heart rate rose in the last set, measured from where
/// it was when that set STARTED (not from resting, which a warm-up never leaves by much): ready once it
/// has given back a share of that rise, "almost" a little above. The share needed scales with today's HRV
/// against your baseline: a suppressed HRV asks for more recovery, a high one for less. Two more ways to
/// green, so the light never holds you for a number you won't reach: a light set (a rise under
/// `lightSetRiseBPM`) is ready as soon as the minimum rest has passed, and so is a rest where heart rate
/// has stopped falling (`plateaued`) while already inside "almost". Custom mode uses two fixed heart
/// rates instead. A minimum rest caps the light at "almost" until it has passed.
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
    /// A set that lifted heart rate less than this above where it started is light: ready after the
    /// minimum rest.
    public static let lightSetRiseBPM = 15

    public static func assumedPeak(restingBpm: Int, age: Int?) -> Int {
        let maxHr = 208 - 0.7 * Double(age ?? 35)
        return Int((Double(restingBpm) + 0.75 * (maxHr - Double(restingBpm))).rounded())
    }

    /// `setStartBpm` is heart rate as the set began; nil measures from resting (the old behaviour). It is
    /// never taken below resting.
    public static func thresholds(config: Config, restingBpm: Int, setPeakBpm: Int?, age: Int?,
                                  hrvRatio: Double?, setStartBpm: Int? = nil) -> Thresholds {
        guard config.auto else {
            let g = config.greenBpm
            return Thresholds(greenBpm: g, yellowBpm: max(g + 1, config.yellowBpm), remainingShare: nil)
        }
        let base = max(restingBpm, setStartBpm ?? restingBpm)
        let peak = max(base + 10, setPeakBpm ?? assumedPeak(restingBpm: restingBpm, age: age))
        let rise = Double(peak - base)
        let share = remainingShare(hrvRatio: hrvRatio)
        let green = Int((Double(base) + rise * share).rounded())
        let yellow = Int((Double(base) + rise * min(0.85, share + 0.2)).rounded())
        return Thresholds(greenBpm: green, yellowBpm: max(green + 1, yellow), remainingShare: share)
    }

    public static func read(config: Config, currentBpm: Int, restS: Int, restingBpm: Int, setPeakBpm: Int?,
                            age: Int?, hrvRatio: Double?, setStartBpm: Int? = nil,
                            plateaued: Bool = false) -> Reading {
        let t = thresholds(config: config, restingBpm: restingBpm, setPeakBpm: setPeakBpm, age: age,
                           hrvRatio: hrvRatio, setStartBpm: setStartBpm)
        var light: Light = currentBpm <= t.greenBpm ? .green : (currentBpm <= t.yellowBpm ? .yellow : .red)
        if config.auto, restS >= config.minRestS {
            let base = max(restingBpm, setStartBpm ?? restingBpm)
            let light_ = setPeakBpm.map { $0 - base < Self.lightSetRiseBPM } ?? false
            // A warm-up barely moved heart rate, and a heart rate that has levelled off won't drop further
            // by waiting: either way, go.
            if light_ || (plateaued && light == .yellow) { light = .green }
        }
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

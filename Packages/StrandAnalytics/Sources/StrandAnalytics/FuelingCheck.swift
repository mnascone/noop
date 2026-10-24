import Foundation

/// Is intake keeping up with training? Protein against body weight, carbohydrate against the glycogen the
/// day's Effort used, and energy in against energy out.
///
/// Targets follow the usual sports-nutrition ranges (ISSN / ACSM position stands): protein 1.6 g/kg on
/// training days (1.2 on rest days), carbohydrate 3 g/kg on light days, 5 on moderate and 7 on hard ones.
/// These are population guides applied to a food log that may be incomplete, so the output says "looks"
/// rather than "is".
public enum FuelingCheck {
    public struct Day: Sendable, Equatable {
        public let day: String
        public let kcal: Double?
        public let proteinG: Double?
        public let carbsG: Double?
        public let fatG: Double?
        /// Energy out (basal + active), kcal.
        public let burnedKcal: Double?
        /// NOOP Effort, 0...100.
        public let effort: Double?
        public init(day: String, kcal: Double?, proteinG: Double?, carbsG: Double?, fatG: Double?,
                    burnedKcal: Double?, effort: Double?) {
            self.day = day; self.kcal = kcal; self.proteinG = proteinG; self.carbsG = carbsG
            self.fatG = fatG; self.burnedKcal = burnedKcal; self.effort = effort
        }
    }

    public enum Status: String, Sendable, Equatable { case low, close, good, high }

    public struct Line: Sendable, Equatable {
        public let status: Status
        public let actual: Double
        public let target: Double
    }

    public struct Result: Sendable, Equatable {
        /// The day judged (the last complete logged day).
        public let day: String
        public let protein: Line?
        public let proteinPerKg: Double?
        public let glycogen: Line?
        /// Carbohydrate target per kg for that day's load.
        public let carbsPerKgTarget: Double?
        /// Average daily intake minus burn over the logged days in the window. Negative = deficit.
        public let energyBalanceKcal: Double?
        public let loggedDays: Int
        public let fatShare: Double?
    }

    public static func carbsPerKg(effort: Double?) -> Double {
        guard let e = effort else { return 4 }
        return e < 33 ? 3 : (e < 66 ? 5 : 7)
    }

    public static func proteinPerKg(effort: Double?) -> Double {
        (effort ?? 0) >= 20 ? 1.6 : 1.2
    }

    static func status(_ actual: Double, target: Double, highAt: Double? = nil) -> Status {
        let r = actual / max(target, 1)
        if let highAt, r >= highAt { return .high }
        return r >= 0.95 ? .good : (r >= 0.75 ? .close : .low)
    }

    /// `days` oldest first. Judges the newest day with food logged, unless `skipLast` (today, still
    /// being eaten) is set and an earlier logged day exists.
    public static func evaluate(_ days: [Day], weightKg: Double, skipLast: Bool = true) -> Result? {
        let logged = days.filter { ($0.kcal ?? 0) > 300 || ($0.proteinG ?? 0) > 20 }
        guard !logged.isEmpty, weightKg > 20 else { return nil }
        let judged: Day = {
            if skipLast, logged.count >= 2, logged.last?.day == days.last?.day { return logged[logged.count - 2] }
            return logged[logged.count - 1]
        }()
        let pTarget = proteinPerKg(effort: judged.effort) * weightKg
        let cPerKg = carbsPerKg(effort: judged.effort)
        let protein = judged.proteinG.map { Line(status: status($0, target: pTarget), actual: $0, target: pTarget) }
        let glycogen = judged.carbsG.map {
            Line(status: status($0, target: cPerKg * weightKg), actual: $0, target: cPerKg * weightKg)
        }
        let balanced = logged.filter { $0.day != days.last?.day || !skipLast }
            .compactMap { d -> Double? in
                guard let k = d.kcal, let b = d.burnedKcal, b > 0 else { return nil }
                return k - b
            }
        let fatShare: Double? = {
            guard let f = judged.fatG, let k = judged.kcal, k > 0 else { return nil }
            return min(1, f * 9 / k)
        }()
        return Result(day: judged.day, protein: protein, proteinPerKg: judged.proteinG.map { $0 / weightKg },
                      glycogen: glycogen, carbsPerKgTarget: cPerKg,
                      energyBalanceKcal: balanced.isEmpty ? nil : balanced.reduce(0, +) / Double(balanced.count),
                      loggedDays: logged.count, fatShare: fatShare)
    }
}

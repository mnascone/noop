import Foundation

/// "I feel different from my score": what you tell NOOP that the strap can't measure.
///
/// Charge stays as measured. A check-in changes only the advice for the day, and is always shown as your
/// own report beside the measured score, never folded into it. Feeling off on a green day steers to an
/// easier session (or rest when unwell). Feeling good on a red day allows a LIGHT session instead of
/// nothing, but never a hard one: the measured recovery still sets the ceiling.
///
/// Patterns (say, sore the day after hockey) are only reported once they have repeated `minTimes` times
/// and make up at least half the chances they had, so two coincidences don't become a rule.
public enum FeelCheckIn {
    public enum Feel: String, Codable, Sendable, CaseIterable {
        /// Matches the score. Recorded so "you checked in" is distinguishable from "no check-in".
        case asScored
        case better
        case off
    }

    public enum Reason: String, Codable, Sendable, CaseIterable {
        // Feeling off
        case sore, lowEnergy, unwell, stressed
        // Feeling better
        case fresh, motivated

        public static let offReasons: [Reason] = [.sore, .lowEnergy, .unwell, .stressed]
        public static let betterReasons: [Reason] = [.fresh, .motivated]
    }

    public struct Entry: Codable, Equatable, Sendable {
        /// Local day key, "yyyy-MM-dd".
        public let day: String
        public var feel: Feel
        public var reasons: [Reason]
        public var ts: Int
        /// The follow-up answer, "was that the right call?", nil until answered.
        public var rightCall: Bool?

        public init(day: String, feel: Feel, reasons: [Reason] = [], ts: Int, rightCall: Bool? = nil) {
            self.day = day; self.feel = feel; self.reasons = reasons; self.ts = ts; self.rightCall = rightCall
        }
    }

    public enum Band: Sendable, Equatable {
        case red, yellow, green

        public init?(charge: Double?) {
            guard let c = charge else { return nil }
            self = c >= 67 ? .green : (c >= 34 ? .yellow : .red)
        }
    }

    /// Rule-based advice for the day from measured Charge and how you feel. nil when the check-in agrees
    /// with the score (the usual advice stands).
    public static func advice(charge: Double?, feel: Feel, reasons: [Reason]) -> String? {
        let band = Band(charge: charge)
        switch feel {
        case .asScored:
            return nil
        case .off:
            if reasons.contains(.unwell) {
                return "You feel unwell: rest today whatever Charge says. An easy walk at most."
            }
            if reasons.contains(.sore) {
                return band == .red
                    ? "Sore on a low-Charge day: rest, or light mobility only."
                    : "You feel sore: swap the hard session for an easier lift on other muscles, technique work, or easy Zone 2 cardio."
            }
            if reasons.contains(.lowEnergy) {
                switch band {
                case .green?: return "Low on energy despite a good Charge: keep it moderate, a shorter session at controlled effort."
                case .yellow?: return "Low on energy: easy Zone 2 or mobility rather than intensity."
                case .red?, nil: return "Low on energy and low Charge: take the rest day."
                }
            }
            if reasons.contains(.stressed) {
                return "Feeling stressed: steady Zone 2 or a walk tends to help. Skip max efforts today."
            }
            return band == .red
                ? "You feel off and Charge is low: rest."
                : "You feel off: go easier than Charge alone would suggest."
        case .better:
            switch band {
            case .red?:
                return "Charge is low as measured, but you feel good: a light session is fine (Zone 2, technique, mobility). Keep it easy, since your body hasn't fully recovered."
            case .yellow?:
                return "You feel better than Charge suggests: a normal session at controlled effort is fine."
            case .green?, nil:
                return "You feel good and Charge agrees: a good day to push."
            }
        }
    }

    /// A repeated link between a reason you reported and the sport you did the day before.
    public struct Pattern: Equatable, Sendable {
        public let reason: Reason
        public let sport: String
        public let times: Int
        /// Days after that sport that had a check-in at all.
        public let outOf: Int
    }

    public static let minTimes = 3

    /// Reasons you reported the day after a sport, at least `minTimes` times and in at least half of the
    /// days after that sport you checked in. Strongest first.
    public static func patterns(_ entries: [Entry], sportsByDay: [String: [String]]) -> [Pattern] {
        let byDay = Dictionary(entries.map { ($0.day, $0) }, uniquingKeysWith: { _, b in b })
        var chances: [String: Int] = [:]
        var hits: [String: [Reason: Int]] = [:]
        for (day, entry) in byDay {
            guard let prev = previousDay(day), let sports = sportsByDay[prev] else { continue }
            for sport in Set(sports) {
                chances[sport, default: 0] += 1
                for r in entry.reasons where entry.feel == .off {
                    hits[sport, default: [:]][r, default: 0] += 1
                }
            }
        }
        var out: [Pattern] = []
        for (sport, rs) in hits {
            let n = chances[sport] ?? 0
            for (r, k) in rs where k >= minTimes && Double(k) / Double(max(1, n)) >= 0.5 {
                out.append(Pattern(reason: r, sport: sport, times: k, outOf: n))
            }
        }
        return out.sorted { ($0.times, $0.sport) > ($1.times, $1.sport) }
    }

    /// "2026-10-24" -> "2026-10-23", by the calendar (month and year ends included).
    public static func previousDay(_ key: String) -> String? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let d = cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2])),
              let prev = cal.date(byAdding: .day, value: -1, to: d) else { return nil }
        let c = cal.dateComponents([.year, .month, .day], from: prev)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

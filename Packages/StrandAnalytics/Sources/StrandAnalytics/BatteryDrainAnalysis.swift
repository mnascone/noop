import Foundation

/// Strap battery drain from a log of battery readings, and how much each phone-side feature adds to it.
///
/// Each reading carries the features that were on at that moment. Between two readings off the charger,
/// the drop in percent over the hours between them is drain at the earlier reading's features. A feature's
/// cost is its drain rate while on minus the rate while off. Gaps over `maxGapH` (the app asleep for long, the strap
/// out of range) are skipped, as is any pair where the level rose (a charge in between).
///
/// This is a comparison of averages, not a controlled test: a feature that is only on during workouts
/// shares that time with the workout itself, so read the numbers as a guide.
public enum BatteryDrainAnalysis {
    public struct Sample: Sendable, Equatable, Codable {
        public let ts: Double
        public let pct: Double
        public let charging: Bool
        /// Bit set of `Feature` raw values that were on.
        public let features: Int
        public init(ts: Double, pct: Double, charging: Bool, features: Int) {
            self.ts = ts; self.pct = pct; self.charging = charging; self.features = features
        }
    }

    public enum Feature: Int, CaseIterable, Sendable {
        case liveHeartRate = 1
        case motionStream = 2
        case workout = 4
        case continuousHrv = 8
        case rawCapture = 16
        case lockScreenBanner = 32
    }

    public struct FeatureCost: Sendable, Equatable {
        public let feature: Feature
        public let hoursOn: Double
        public let rateOn: Double
        public let rateOff: Double
        /// Extra percent per hour while on (never below zero).
        public var extraPerHour: Double { max(0, rateOn - rateOff) }
    }

    public struct Result: Sendable, Equatable {
        /// Average percent per hour across everything measured.
        public let ratePerHour: Double?
        public let hoursMeasured: Double
        /// Features with at least `minHours` both on and off, costliest first.
        public let costs: [FeatureCost]
        /// Percent used per day, oldest first.
        public let dailyUse: [(day: String, pct: Double)]

        public static func == (a: Result, b: Result) -> Bool {
            a.ratePerHour == b.ratePerHour && a.hoursMeasured == b.hoursMeasured && a.costs == b.costs
                && a.dailyUse.map(\.day) == b.dailyUse.map(\.day) && a.dailyUse.map(\.pct) == b.dailyUse.map(\.pct)
        }
    }

    public static let maxGapH = 6.0
    public static let minHours = 1.0

    public static func analyze(_ raw: [Sample], dayOf: (Double) -> String) -> Result {
        let s = raw.sorted { $0.ts < $1.ts }
        var totalDrop = 0.0, totalH = 0.0
        var on = [Feature: (h: Double, d: Double)](), off = [Feature: (h: Double, d: Double)]()
        var daily: [String: Double] = [:]
        var order: [String] = []
        for (a, b) in zip(s, s.dropFirst()) {
            guard !a.charging, !b.charging else { continue }
            let h = (b.ts - a.ts) / 3600
            let drop = a.pct - b.pct
            guard h > 0, h <= maxGapH, drop >= 0 else { continue }
            totalDrop += drop
            totalH += h
            let day = dayOf(a.ts)
            if daily[day] == nil { order.append(day) }
            daily[day, default: 0] += drop
            for f in Feature.allCases {
                if a.features & f.rawValue != 0 {
                    let v = on[f] ?? (0, 0); on[f] = (v.h + h, v.d + drop)
                } else {
                    let v = off[f] ?? (0, 0); off[f] = (v.h + h, v.d + drop)
                }
            }
        }
        let costs: [FeatureCost] = Feature.allCases.compactMap { f in
            guard let o = on[f], let x = off[f], o.h >= minHours, x.h >= minHours else { return nil }
            return FeatureCost(feature: f, hoursOn: o.h, rateOn: o.d / o.h, rateOff: x.d / x.h)
        }.sorted { $0.extraPerHour > $1.extraPerHour }
        return Result(ratePerHour: totalH >= minHours ? totalDrop / totalH : nil, hoursMeasured: totalH,
                      costs: costs, dailyUse: order.map { ($0, daily[$0] ?? 0) })
    }
}

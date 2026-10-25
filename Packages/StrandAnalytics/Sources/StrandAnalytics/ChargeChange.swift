import Foundation

/// Why today's Charge is where it is: each overnight input against your own recent normal and against
/// the night before, ranked by how much it pushed Charge up or down.
///
/// Charge is scored once per wake from the night just slept, so a night can lower it: what matters is
/// how that night compared with your baseline, not that you slept. This names which inputs moved. The
/// weights are a reading aid for ranking, not the Charge formula itself.
public enum ChargeChange {
    public struct Night: Equatable {
        public let day: String
        public let charge: Double?
        public let hrv: Double?
        public let restingHR: Double?
        public let sleepMin: Double?
        public let respRate: Double?
        public let skinTempDev: Double?

        public init(day: String, charge: Double?, hrv: Double?, restingHR: Double?, sleepMin: Double?,
                    respRate: Double?, skinTempDev: Double?) {
            self.day = day
            self.charge = charge
            self.hrv = hrv
            self.restingHR = restingHR
            self.sleepMin = sleepMin
            self.respRate = respRate
            self.skinTempDev = skinTempDev
        }
    }

    public enum Factor: String, CaseIterable {
        case hrv, restingHR, sleep, respiration, skinTemp
    }

    public struct Driver: Equatable {
        public let factor: Factor
        public let today: Double
        public let yesterday: Double?
        /// Your usual: the mean of up to 30 earlier nights. For skin temperature, 0 (the deviation's own
        /// reference).
        public let usual: Double
        /// Change against usual as a share (0.15 = 15% above). For skin temperature, the deviation in °C.
        public let change: Double
        /// Signed pull on Charge: positive raised it, negative lowered it.
        public let pull: Double
    }

    public struct Explanation: Equatable {
        public let day: String
        public let charge: Double?
        public let yesterdayCharge: Double?
        /// Strongest first. Only inputs that moved enough to matter.
        public let drivers: [Driver]

        public var delta: Double? {
            guard let c = charge, let y = yesterdayCharge else { return nil }
            return c - y
        }
    }

    /// Below this pull an input is "about usual" and not listed.
    public static let minPull = 0.03

    /// The explanation for the newest night that has any overnight input, or nil when there isn't one or
    /// there are fewer than 3 earlier nights to compare with. `nights` oldest first.
    public static func explain(_ nights: [Night]) -> Explanation? {
        guard let idx = nights.lastIndex(where: { $0.hrv != nil || $0.restingHR != nil || $0.sleepMin != nil })
        else { return nil }
        let today = nights[idx]
        let before = Array(nights[..<idx].suffix(30))
        guard before.count >= 3 else { return nil }
        let prev = idx > 0 ? nights[idx - 1] : nil

        func mean(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }
        var out: [Driver] = []

        /// `sign` +1 when higher is better for Charge, -1 when lower is.
        func add(_ f: Factor, _ key: (Night) -> Double?, weight: Double, sign: Double) {
            guard let t = key(today), let u = mean(before.compactMap(key)), u > 0,
                  before.compactMap(key).count >= 3 else { return }
            let change = (t - u) / u
            out.append(Driver(factor: f, today: t, yesterday: prev.flatMap(key), usual: u,
                              change: change, pull: sign * weight * change))
        }
        add(.hrv, \.hrv, weight: 1.0, sign: 1)
        add(.restingHR, \.restingHR, weight: 1.5, sign: -1)
        add(.sleep, \.sleepMin, weight: 0.6, sign: 1)
        add(.respiration, \.respRate, weight: 1.5, sign: -1)
        // Skin temperature is already a deviation: only a clear rise counts against Charge.
        if let d = today.skinTempDev, abs(d) < 5, d >= 0.4 {
            out.append(Driver(factor: .skinTemp, today: d, yesterday: prev?.skinTempDev, usual: 0,
                              change: d, pull: -0.1 * d))
        }

        let ranked = out.filter { abs($0.pull) >= minPull }.sorted { abs($0.pull) > abs($1.pull) }
        return Explanation(day: today.day, charge: today.charge, yesterdayCharge: prev?.charge, drivers: ranked)
    }
}

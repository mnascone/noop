import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// On the Charge screen: why today's Charge is where it is. Charge is scored once when you wake, from the
/// night just slept against your own baseline, so it doesn't fill overnight or drain during the day. This
/// names the overnight inputs that moved it, against your usual and against the night before.
struct ChargeChangeCard: View {
    let days: [DailyMetric]

    private var explanation: ChargeChange.Explanation? {
        ChargeChange.explain(days.map {
            ChargeChange.Night(day: $0.day, charge: $0.recovery, hrv: $0.avgHrv,
                               restingHR: $0.restingHr.map(Double.init), sleepMin: $0.totalSleepMin,
                               respRate: $0.respRateBpm, skinTempDev: $0.skinTempDevC)
        })
    }

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("Why Charge is where it is").strandOverline()
                if let e = explanation {
                    Text(Self.headline(e))
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if e.drivers.isEmpty {
                        Text("Every overnight input was close to your usual, so Charge sits near your normal.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                            ForEach(e.drivers.prefix(4), id: \.factor) { d in row(d) }
                        }
                    }
                }
                Text("Charge is scored once when you wake, from the night you just slept against your own baseline. It doesn't fill up overnight or drain through the day, so a night of sleep can lower it when that night was harder on your body than usual: late training, alcohol, a late meal, illness coming on, or short sleep.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ d: ChargeChange.Driver) -> some View {
        let up = d.pull > 0
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: up ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .foregroundStyle(up ? StrandPalette.statusPositive : StrandPalette.recovery030)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.title(d))
                    .font(StrandFont.footnote.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(Self.detail(d))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func headline(_ e: ChargeChange.Explanation) -> String {
        guard let c = e.charge else { return String(localized: "Last night against your usual") }
        let now = Int(c.rounded())
        guard let d = e.delta, let y = e.yesterdayCharge else { return String(localized: "Charge \(now)") }
        let dd = Int(d.rounded())
        if abs(dd) < 3 { return String(localized: "Charge \(now), about the same as the day before") }
        return dd < 0
            ? String(localized: "Charge \(now), down \(-dd) from \(Int(y.rounded())) the day before")
            : String(localized: "Charge \(now), up \(dd) from \(Int(y.rounded())) the day before")
    }

    static func title(_ d: ChargeChange.Driver) -> String {
        switch d.factor {
        case .hrv: return String(localized: "HRV \(Int(d.today.rounded())) ms")
        case .restingHR: return String(localized: "Resting heart rate \(Int(d.today.rounded())) bpm")
        case .sleep:
            let m = Int(d.today.rounded())
            return String(localized: "Sleep \(m / 60)h \(m % 60)m")
        case .respiration: return String(localized: "Breathing \(String(format: "%.1f", d.today)) per min")
        case .skinTemp: return String(localized: "Skin temperature +\(String(format: "%.1f", d.today))°C")
        }
    }

    private static func value(_ v: Double, _ f: ChargeChange.Factor) -> String {
        switch f {
        case .respiration: return String(format: "%.1f", v)
        case .sleep:
            let m = Int(v.rounded())
            return "\(m / 60)h \(m % 60)m"
        default: return "\(Int(v.rounded()))"
        }
    }

    /// "22% below your usual 49, and 58 the night before. Lower HRV lowers Charge."
    static func detail(_ d: ChargeChange.Driver) -> String {
        if d.factor == .skinTemp {
            return String(localized: "Above your usual. A warm night often comes with illness or a hard day, and lowers Charge.")
        }
        let pct = Int((abs(d.change) * 100).rounded())
        let usual = value(d.usual, d.factor)
        var s = d.change < 0
            ? String(localized: "\(pct)% below your usual \(usual)")
            : String(localized: "\(pct)% above your usual \(usual)")
        if let y = d.yesterday {
            s += String(localized: ", \(value(y, d.factor)) the night before")
        }
        s += ". "
        switch d.factor {
        case .hrv: s += d.pull > 0 ? String(localized: "Higher HRV raises Charge.") : String(localized: "Lower HRV lowers Charge.")
        case .restingHR: s += d.pull > 0 ? String(localized: "A lower resting heart rate raises Charge.") : String(localized: "A higher resting heart rate lowers Charge.")
        case .sleep: s += d.pull > 0 ? String(localized: "More sleep than usual helps.") : String(localized: "Less sleep than usual counts against it.")
        case .respiration: s += d.pull > 0 ? String(localized: "Calmer breathing than usual helps.") : String(localized: "Faster breathing than usual counts against it.")
        case .skinTemp: break
        }
        return s
    }
}

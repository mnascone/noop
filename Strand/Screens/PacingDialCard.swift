import SwiftUI
import StrandDesign
import WhoopStore

/// Charge against Effort over the last week, each compared with your own previous four weeks. A dial from
/// green (Charge pulling ahead: you're recovering) to red (Effort pulling ahead: load is building faster
/// than you recover).
struct PacingDialCard: View {
    let days: [DailyMetric]
    let effortScale: EffortScale

    struct Pacing: Equatable {
        var chargeRecent: Double
        var chargeUsual: Double
        var effortRecent: Double
        var effortUsual: Double
        /// -1 = Charge far ahead, 0 = in step, +1 = Effort far ahead.
        var balance: Double

        enum State { case recovering, balanced, overreaching }
        var state: State {
            balance <= -Self.band ? .recovering : (balance >= Self.band ? .overreaching : .balanced)
        }
        static let band = 0.25
    }

    /// The change in Effort beyond the change in Charge (log ratios), so a 20% rise in Effort with Charge
    /// flat reads the same as Effort flat with Charge down 20%. ±0.35 fills the dial.
    static func pacing(days: [DailyMetric], todayKey: String) -> Pacing? {
        let past = RestDayRules.pastDayKeys(count: 34, todayKey: todayKey)
        guard past.count == 34 else { return nil }
        let recentKeys = Set([todayKey] + past.prefix(6))
        let usualKeys = Set(past.dropFirst(6))
        var cR: [Double] = [], cU: [Double] = [], eR: [Double] = [], eU: [Double] = []
        for d in days {
            if recentKeys.contains(d.day) {
                if let c = d.recovery { cR.append(c) }
                if let e = d.strain { eR.append(e) }
            } else if usualKeys.contains(d.day) {
                if let c = d.recovery { cU.append(c) }
                if let e = d.strain { eU.append(e) }
            }
        }
        guard cR.count >= 4, eR.count >= 4, cU.count >= 10, eU.count >= 10 else { return nil }
        func mean(_ a: [Double]) -> Double { a.reduce(0, +) / Double(a.count) }
        let p = (mean(cR), mean(cU), mean(eR), mean(eU))
        guard p.0 > 0, p.1 > 0 else { return nil }
        // +5 keeps a near-zero Effort week from swinging the ratio wildly.
        let s = log((p.2 + 5) / (p.3 + 5)) - log(p.0 / p.1)
        return Pacing(chargeRecent: p.0, chargeUsual: p.1, effortRecent: p.2, effortUsual: p.3,
                      balance: min(1, max(-1, s / 0.35)))
    }

    var body: some View {
        let pacing = Self.pacing(days: days, todayKey: Repository.localDayKey(Date()))
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                SectionHeader("Charge vs Effort", overline: "Pacing",
                              trailing: String(localized: "Last 7 days"))
                if let pacing {
                    PacingDial(balance: pacing.balance)
                        .frame(height: 120)
                        .frame(maxWidth: .infinity)
                    Text(headline(pacing))
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        figure(String(localized: "Charge"), now: "\(Int(pacing.chargeRecent.rounded()))",
                               usual: "\(Int(pacing.chargeUsual.rounded()))", tint: StrandPalette.chargeColor)
                        Spacer()
                        figure(String(localized: "Effort"),
                               now: UnitFormatter.effortDisplay(pacing.effortRecent, scale: effortScale),
                               usual: UnitFormatter.effortDisplay(pacing.effortUsual, scale: effortScale),
                               tint: StrandPalette.effortColor)
                    }
                    Text("Daily averages for the last 7 days against your previous 4 weeks.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                } else {
                    Text("Needs about 5 weeks of Charge and Effort to compare this week with your usual.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func headline(_ p: Pacing) -> String {
        switch p.state {
        case .recovering:
            return String(localized: "Charge is outpacing Effort. You're recovering, so there's room to train harder.")
        case .balanced:
            return String(localized: "Effort and Charge are in step.")
        case .overreaching:
            return String(localized: "Effort is outpacing Charge. Load is building faster than you recover. Ease off or sleep more.")
        }
    }

    private func figure(_ label: String, now: String, usual: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            Text(now).font(StrandFont.headline).foregroundStyle(tint)
            Text(String(localized: "usually \(usual)")).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
        }
    }
}

/// A half-circle dial, green on the left to red on the right, with a needle at `balance` (-1...1).
struct PacingDial: View {
    let balance: Double

    var body: some View {
        Canvas { ctx, size in
            let lineWidth: CGFloat = 14
            let radius = min(size.width / 2, size.height) - lineWidth / 2 - 2
            let center = CGPoint(x: size.width / 2, y: size.height - 4)
            let segments = 48
            func point(_ a: Double) -> CGPoint {
                CGPoint(x: center.x + CGFloat(cos(a)) * radius, y: center.y + CGFloat(sin(a)) * radius)
            }
            for i in 0..<segments {
                // Angles run from pi (left) over the top to 2 pi (right); y grows downward, so the
                // sine is negative across the top half.
                let a0 = Double.pi + Double.pi * Double(i) / Double(segments)
                let a1 = Double.pi + Double.pi * Double(i + 1) / Double(segments)
                var path = Path()
                path.move(to: point(a0))
                path.addLine(to: point((a0 + a1) / 2))
                path.addLine(to: point(min(2 * Double.pi, a1 + 0.004)))
                // Left end = full Charge colour (green), right end = depleted (red).
                let t = 1 - Double(i) / Double(segments - 1)
                ctx.stroke(path, with: .color(StrandPalette.recoveryColor(t * 100)),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            }
            let angle = Double.pi + Double.pi * (balance + 1) / 2
            let tip = CGPoint(x: center.x + CGFloat(cos(angle)) * (radius - lineWidth),
                              y: center.y + CGFloat(sin(angle)) * (radius - lineWidth))
            var needle = Path()
            needle.move(to: center)
            needle.addLine(to: tip)
            ctx.stroke(needle, with: .color(StrandPalette.textPrimary),
                       style: StrokeStyle(lineWidth: 3, lineCap: .round))
            let hub = CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12)
            ctx.fill(Path(ellipseIn: hub), with: .color(StrandPalette.textPrimary))
        }
        .overlay(alignment: .bottomLeading) {
            Text("Recovering").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
        .overlay(alignment: .bottomTrailing) {
            Text("Overreaching").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityLabel(Text("Pacing dial"))
        .accessibilityValue(Text(balance <= -PacingDialCard.Pacing.band ? "Recovering"
                                 : balance >= PacingDialCard.Pacing.band ? "Overreaching" : "In step"))
    }
}

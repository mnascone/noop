import SwiftUI
import StrandDesign
import WhoopStore

/// How Effort is keeping pace with Charge, each compared with your own recent normal.
///
/// Short term: the last 3 days against the 11 before. Long term: the last 7 days against the 4 weeks
/// before. The overall read leans on the long term once there's enough history for it (70/30), and uses
/// the short term alone until then.
enum PacingMath {
    struct Pacing: Equatable {
        var chargeRecent: Double
        var chargeUsual: Double
        var effortRecent: Double
        var effortUsual: Double
        /// -1 = Charge far ahead, 0 = in step, +1 = Effort far ahead.
        var balance: Double
    }

    enum State { case recovering, balanced, overreaching }

    static let band = 0.25

    static func state(_ balance: Double) -> State {
        balance <= -band ? .recovering : (balance >= band ? .overreaching : .balanced)
    }

    struct Window {
        let recentDays: Int
        let usualDays: Int
        let minRecent: Int
        let minUsual: Int
        static let short = Window(recentDays: 3, usualDays: 11, minRecent: 2, minUsual: 5)
        static let long = Window(recentDays: 7, usualDays: 28, minRecent: 4, minUsual: 10)
    }

    /// The change in Effort beyond the change in Charge (log ratios), so a 20% rise in Effort with Charge
    /// flat reads the same as Effort flat with Charge down 20%. ±0.35 fills the dial.
    static func pacing(days: [DailyMetric], todayKey: String, window w: Window) -> Pacing? {
        let span = w.recentDays - 1 + w.usualDays
        let past = RestDayRules.pastDayKeys(count: span, todayKey: todayKey)
        guard past.count == span else { return nil }
        let recentKeys = Set([todayKey] + past.prefix(w.recentDays - 1))
        let usualKeys = Set(past.dropFirst(w.recentDays - 1))
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
        guard cR.count >= w.minRecent, eR.count >= w.minRecent, cU.count >= w.minUsual, eU.count >= w.minUsual
        else { return nil }
        func mean(_ a: [Double]) -> Double { a.reduce(0, +) / Double(a.count) }
        let p = (mean(cR), mean(cU), mean(eR), mean(eU))
        guard p.0 > 0, p.1 > 0 else { return nil }
        // +5 keeps a near-zero Effort stretch from swinging the ratio wildly.
        let s = log((p.2 + 5) / (p.3 + 5)) - log(p.0 / p.1)
        return Pacing(chargeRecent: p.0, chargeUsual: p.1, effortRecent: p.2, effortUsual: p.3,
                      balance: min(1, max(-1, s / 0.35)))
    }

    /// Long term weighted 70/30 over short term when it exists, else the short term alone.
    static func overall(short: Pacing?, long: Pacing?) -> Double? {
        if let long { return 0.7 * long.balance + 0.3 * (short?.balance ?? long.balance) }
        return short?.balance
    }
}

/// The pacing card. `.short` is the speedometer for Today, `.both` shows both dials plus the overall read
/// for Performance.
struct PacingDialCard: View {
    enum Mode { case short, both }

    let days: [DailyMetric]
    let effortScale: EffortScale
    var mode: Mode = .both

    var body: some View {
        let today = Repository.localDayKey(Date())
        let short = PacingMath.pacing(days: days, todayKey: today, window: .short)
        let long = mode == .both ? PacingMath.pacing(days: days, todayKey: today, window: .long) : nil
        switch mode {
        case .short:
            compactCard(short)
        case .both:
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Charge vs Effort").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Text("Pacing").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                    if let overall = PacingMath.overall(short: short, long: long) {
                        Text(long == nil ? Self.shortHeadline(overall) : Self.longHeadline(overall))
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        paceRow(String(localized: "Short term"), String(localized: "3 days"), short)
                        Divider().overlay(StrandPalette.hairline.opacity(0.5))
                        paceRow(String(localized: "Long term"), String(localized: "7 vs 28 days"), long)
                    } else {
                        empty("Needs about 2 weeks of Charge and Effort to compare against your usual.")
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// One window: a small gauge, its name, a status chip, and the numbers against usual.
    private func paceRow(_ title: String, _ window: String, _ p: PacingMath.Pacing?) -> some View {
        HStack(alignment: .center, spacing: NoopMetrics.space3) {
            PacingDial(balance: p?.balance ?? 0, compact: true, showsLabels: false)
                .frame(width: 64, height: 38)
                .opacity(p == nil ? 0.3 : 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(StrandFont.subhead.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                    if let p {
                        Text(Self.stateWord(p.balance))
                            .font(StrandFont.caption.weight(.semibold))
                            .foregroundStyle(Self.stateColor(p.balance))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Self.stateColor(p.balance).opacity(0.15)))
                    }
                    Spacer(minLength: 0)
                    Text(window).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                }
                if let p {
                    Text(String(localized: "Effort \(UnitFormatter.effortDisplay(p.effortRecent, scale: effortScale)) vs \(UnitFormatter.effortDisplay(p.effortUsual, scale: effortScale)) · Charge \(Int(p.chargeRecent.rounded())) vs \(Int(p.chargeUsual.rounded()))"))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                } else {
                    Text("Needs about 5 weeks of data.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    /// Today's compact row: a small gauge, one status word, one line, one line of numbers.
    @ViewBuilder
    private func compactCard(_ p: PacingMath.Pacing?) -> some View {
        NoopCard {
            HStack(alignment: .center, spacing: NoopMetrics.space3) {
                PacingDial(balance: p?.balance ?? 0, compact: true, showsLabels: false)
                    .frame(width: 72, height: 42)
                    .opacity(p == nil ? 0.35 : 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Pace").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        if let p {
                            Text(Self.stateWord(p.balance))
                                .font(StrandFont.caption.weight(.semibold))
                                .foregroundStyle(Self.stateColor(p.balance))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(Self.stateColor(p.balance).opacity(0.15)))
                        }
                        Spacer(minLength: 0)
                        Text("3 days").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                    if let p {
                        Text(Self.compactLine(p.balance))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        Text(String(localized: "Effort \(UnitFormatter.effortDisplay(p.effortRecent, scale: effortScale)) vs \(UnitFormatter.effortDisplay(p.effortUsual, scale: effortScale)) usual · Charge \(Int(p.chargeRecent.rounded())) vs \(Int(p.chargeUsual.rounded()))"))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    } else {
                        Text("Needs about 2 weeks of data.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func stateWord(_ balance: Double) -> String {
        switch PacingMath.state(balance) {
        case .recovering: return String(localized: "Under")
        case .balanced: return String(localized: "On pace")
        case .overreaching: return String(localized: "Too hard")
        }
    }

    /// Green at the easy end, red at the hard end, on the same ramp as the dial.
    static func stateColor(_ balance: Double) -> Color {
        StrandPalette.recoveryColor((1 - (balance + 1) / 2) * 100)
    }

    static func compactLine(_ balance: Double) -> String {
        switch PacingMath.state(balance) {
        case .recovering: return String(localized: "Charge can take more.")
        case .balanced: return String(localized: "Effort matches your Charge.")
        case .overreaching: return String(localized: "Ease off for a day or two.")
        }
    }

    private func empty(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func shortHeadline(_ balance: Double) -> String {
        switch PacingMath.state(balance) {
        case .recovering: return String(localized: "You're under your pace. Charge can take more.")
        case .balanced: return String(localized: "On pace. Effort matches what your Charge supports.")
        case .overreaching: return String(localized: "You're outpacing your Charge. Ease off for a day or two.")
        }
    }

    static func longHeadline(_ balance: Double) -> String {
        switch PacingMath.state(balance) {
        case .recovering:
            return String(localized: "Charge is outpacing Effort. You're recovering, so there's room to train harder.")
        case .balanced:
            return String(localized: "Effort and Charge are in step.")
        case .overreaching:
            return String(localized: "Effort is outpacing Charge. Load is building faster than you recover. Ease off or sleep more.")
        }
    }

}

/// A speedometer: half circle from green (left) to red (right) with ticks and a needle at `balance`
/// (-1...1).
struct PacingDial: View {
    let balance: Double
    var leftLabel: LocalizedStringKey = "Recovering"
    var rightLabel: LocalizedStringKey = "Overreaching"
    var compact = false
    var showsLabels = true

    var body: some View {
        Canvas { ctx, size in
            let lineWidth: CGFloat = compact ? 9 : 14
            let radius = min(size.width / 2, size.height) - lineWidth / 2 - 2
            let center = CGPoint(x: size.width / 2, y: size.height - 4)
            let segments = 48
            func point(_ a: Double, _ r: CGFloat) -> CGPoint {
                CGPoint(x: center.x + CGFloat(cos(a)) * r, y: center.y + CGFloat(sin(a)) * r)
            }
            // Angles run from pi (left) over the top to 2 pi (right); y grows downward, so the sine is
            // negative across the top half.
            for i in 0..<segments {
                let a0 = Double.pi + Double.pi * Double(i) / Double(segments)
                let a1 = Double.pi + Double.pi * Double(i + 1) / Double(segments)
                var path = Path()
                path.move(to: point(a0, radius))
                path.addLine(to: point((a0 + a1) / 2, radius))
                path.addLine(to: point(min(2 * Double.pi, a1 + 0.004), radius))
                // Left end = full Charge colour (green), right end = depleted (red).
                let t = 1 - Double(i) / Double(segments - 1)
                ctx.stroke(path, with: .color(StrandPalette.recoveryColor(t * 100)),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            }
            // Speedometer ticks inside the arc, a longer one at the middle.
            let tickCount = compact ? 4 : 10
            for i in 0...tickCount {
                let a = Double.pi + Double.pi * Double(i) / Double(tickCount)
                let isMid = i * 2 == tickCount
                let inner = radius - lineWidth / 2 - (isMid ? (compact ? 6 : 11) : (compact ? 3 : 6))
                var tick = Path()
                tick.move(to: point(a, radius - lineWidth / 2 - 1))
                tick.addLine(to: point(a, inner))
                ctx.stroke(tick, with: .color(StrandPalette.textTertiary), lineWidth: isMid ? 2 : 1)
            }
            let angle = Double.pi + Double.pi * (balance + 1) / 2
            var needle = Path()
            needle.move(to: center)
            needle.addLine(to: point(angle, radius - lineWidth / 2 - 2))
            ctx.stroke(needle, with: .color(StrandPalette.textPrimary),
                       style: StrokeStyle(lineWidth: compact ? 2 : 3, lineCap: .round))
            let hubR: CGFloat = compact ? 4 : 6
            ctx.fill(Path(ellipseIn: CGRect(x: center.x - hubR, y: center.y - hubR, width: hubR * 2, height: hubR * 2)),
                     with: .color(StrandPalette.textPrimary))
        }
        .overlay(alignment: .bottomLeading) {
            if showsLabels {
                Text(leftLabel).font(compact ? .system(size: 9) : StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showsLabels {
                Text(rightLabel).font(compact ? .system(size: 9) : StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .accessibilityLabel(Text("Pacing dial"))
        .accessibilityValue(Text(PacingMath.state(balance) == .recovering ? leftLabel
                                 : PacingMath.state(balance) == .overreaching ? rightLabel : "On pace"))
    }
}

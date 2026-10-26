import SwiftUI
import StrandDesign
import WhoopStore

/// What's driving pace: for each window, how far Effort, Charge and stress each pushed the ring, then
/// the last week day by day. The pushes add up to the ring (before it's capped at full), using the same
/// maths as `PacingMath.pacing`.
struct PaceBreakdownView: View {
    let days: [DailyMetric]
    let effortScale: EffortScale
    var todayEffortFloor: Double? = nil
    var onOpenTrends: (() -> Void)? = nil

    /// One input's push on the ring, -1...1 of a full ring: + toward Heavy, - toward Light.
    struct Push: Identifiable {
        let id: String
        let title: String
        let detail: String
        let value: Double?
    }

    var body: some View {
        let today = Repository.localDayKey(Date())
        let stress = PacingDialCard.stressByDay(days)
        let short = PacingMath.pacing(days: days, todayKey: today, window: .short, stressByDay: stress,
                                      todayEffortFloor: todayEffortFloor)
        let long = PacingMath.pacing(days: days, todayKey: today, window: .long, stressByDay: stress,
                                     todayEffortFloor: todayEffortFloor)
        let overall = PacingMath.overall(short: short, long: long)
        ScreenScaffold(title: "Pace", subtitle: "What's pushing your load against your recovery") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                summaryCard(overall, hasLong: long != nil)
                if let long {
                    windowCard(String(localized: "Long term"), String(localized: "Last 7 days against the 4 weeks before"),
                               long, weight: short == nil ? 1 : 0.7)
                }
                if let short {
                    windowCard(String(localized: "Short term"), String(localized: "Last 3 days against the 11 before"),
                               short, weight: long == nil ? 1 : 0.3)
                }
                weekCard(stress, today: today)
                if let onOpenTrends {
                    Button(action: onOpenTrends) {
                        Label("Charge and Effort trends", systemImage: "chart.xyaxis.line")
                            .font(StrandFont.subhead.weight(.semibold))
                            .foregroundStyle(StrandPalette.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Summary

    private func summaryCard(_ overall: Double?, hasLong: Bool) -> some View {
        NoopCard {
            HStack(spacing: NoopMetrics.space4) {
                ArcGauge(from: 0.5, to: overall.map { ($0 + 1) / 2 } ?? 0.5,
                         color: overall.map(PacingDialCard.stateColor) ?? StrandPalette.textTertiary,
                         diameter: 96, tick: 0.5) {
                    Text(overall.map(PacingDialCard.stateWord) ?? "–")
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    Text(overall.map { PacingDialCard.compactLine($0, today: PacingDialCard.today(days)) }
                         ?? String(localized: "Pace needs about 2 weeks of Charge and Effort."))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(hasLong
                         ? String(localized: "Long term counts for 70% of the ring, short term 30%.")
                         : String(localized: "Short term only, until there are 4 weeks of history."))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: A window

    static func pushes(_ p: PacingMath.Pacing, effortScale: EffortScale) -> [Push] {
        let effort = log((p.effortRecent + 5) / (p.effortUsual + 5)) / 0.35
        let charge = -log(p.chargeRecent / p.chargeUsual) / 0.35
        let effortPct = Int(((p.effortRecent - p.effortUsual) / max(p.effortUsual, 1) * 100).rounded())
        let chargePct = Int(((p.chargeRecent - p.chargeUsual) / max(p.chargeUsual, 1) * 100).rounded())
        var out = [
            Push(id: "effort", title: String(localized: "Effort"),
                 detail: String(localized: "\(UnitFormatter.effortDisplay(p.effortRecent, scale: effortScale)) a day vs \(UnitFormatter.effortDisplay(p.effortUsual, scale: effortScale)) usual (\(Self.signed(effortPct))%)"),
                 value: effort),
            Push(id: "charge", title: String(localized: "Charge"),
                 detail: String(localized: "\(Int(p.chargeRecent.rounded())) vs \(Int(p.chargeUsual.rounded())) usual (\(Self.signed(chargePct))%)"),
                 value: charge),
        ]
        if let d = p.stressDelta {
            out.append(Push(id: "stress", title: String(localized: "Stress"),
                            detail: String(localized: "\(String(format: "%+.1f", d)) on the 0-3 scale against usual"),
                            value: 0.15 * d / 0.35))
        } else {
            out.append(Push(id: "stress", title: String(localized: "Stress"),
                            detail: String(localized: "Not enough daily stress yet to compare"), value: nil))
        }
        return out
    }

    private static func signed(_ n: Int) -> String { n > 0 ? "+\(n)" : "\(n)" }

    private func windowCard(_ title: String, _ sub: String, _ p: PacingMath.Pacing, weight: Double) -> some View {
        let pushes = Self.pushes(p, effortScale: effortScale)
        return NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).strandOverline()
                        Text(sub).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer()
                    Text(PacingDialCard.stateWord(p.balance))
                        .font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(PacingDialCard.stateColor(p.balance))
                }
                ForEach(pushes) { push in pushRow(push) }
                Divider().overlay(StrandPalette.hairline)
                HStack {
                    Text("Together")
                        .font(StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Text(Self.pushWords(p.balance))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Text(String(localized: "Counts for \(Int((weight * 100).rounded()))% of the ring."))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func pushRow(_ push: Push) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(push.title)
                    .font(StrandFont.footnote.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text(push.value.map(Self.pushWords) ?? "–")
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(push.value.map(Self.pushColor) ?? StrandPalette.textTertiary)
            }
            PushBar(value: push.value ?? 0, color: push.value.map(Self.pushColor) ?? StrandPalette.textTertiary)
                .frame(height: 6)
            Text(push.detail)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "32% toward Heavy", "15% toward Light", "No push".
    static func pushWords(_ v: Double) -> String {
        let pct = Int((min(1, abs(v)) * 100).rounded())
        if pct < 3 { return String(localized: "No real push") }
        return v > 0 ? String(localized: "\(pct)% toward Heavy") : String(localized: "\(pct)% toward Light")
    }

    static func pushColor(_ v: Double) -> Color {
        abs(v) < 0.03 ? StrandPalette.textTertiary : (v > 0 ? StrandPalette.recovery030 : StrandPalette.statusPositive)
    }

    // MARK: The week

    private func weekCard(_ stress: [String: Double], today: String) -> some View {
        let keys = ([today] + RestDayRules.pastDayKeys(count: 6, todayKey: today))
        let byDay = Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        return NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("Last 7 days").strandOverline()
                HStack {
                    Text("Day").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Charge").frame(width: 60, alignment: .trailing)
                    Text("Effort").frame(width: 60, alignment: .trailing)
                    Text("Stress").frame(width: 56, alignment: .trailing)
                }
                .font(StrandFont.caption.weight(.semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                ForEach(keys, id: \.self) { key in
                    weekRow(key, today: today, day: byDay[key], stress: stress[key])
                }
                Text("Stress is the daily 0-3 score from resting heart rate and HRV.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func weekRow(_ key: String, today: String, day: DailyMetric?, stress: Double?) -> some View {
        let charge: String = day?.recovery.map { "\(Int($0.rounded()))" } ?? "–"
        let e: Double? = key == today ? PacingMath.larger(day?.strain, todayEffortFloor) : day?.strain
        let effort: String = e.map { UnitFormatter.effortDisplay($0, scale: effortScale) } ?? "–"
        let stressText: String = stress.map { String(format: "%.1f", $0) } ?? "–"
        return HStack {
            Text(Self.dayLabel(key, today: today)).frame(maxWidth: .infinity, alignment: .leading)
            Text(charge).frame(width: 60, alignment: .trailing)
            Text(effort).frame(width: 60, alignment: .trailing)
            Text(stressText).frame(width: 56, alignment: .trailing)
        }
        .font(StrandFont.footnote)
        .monospacedDigit()
        .foregroundStyle(StrandPalette.textPrimary)
    }

    private static let keyParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayLabel(_ key: String, today: String) -> String {
        if key == today { return String(localized: "Today") }
        guard let d = keyParser.date(from: key) else { return key }
        return d.formatted(.dateTime.weekday(.abbreviated).day())
    }
}

/// A bar that fills out from its middle: right for a push toward Heavy, left toward Light.
private struct PushBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let half = w / 2
            let len = half * CGFloat(min(1, abs(value)))
            ZStack(alignment: .leading) {
                Capsule().fill(StrandPalette.textPrimary.opacity(0.08))
                Capsule()
                    .fill(color)
                    .frame(width: max(len, 2))
                    .offset(x: value >= 0 ? half : half - len)
                Rectangle()
                    .fill(StrandPalette.textPrimary.opacity(0.3))
                    .frame(width: 1)
                    .offset(x: half)
            }
        }
        .accessibilityHidden(true)
    }
}

import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Inputs the sleep score needs beyond the night itself. Resolved once, in one place, so Today, the
/// Sleep tab and the breakdown all score a night the same way.
@MainActor
enum SleepScoreInputs {
    /// Personal need and regularity: the latest scoring pass's values when there is one, else the same
    /// estimate derived from the banked nights.
    static func resolve(intelligence: IntelligenceEngine, days: [DailyMetric], age: Int?)
        -> (needHours: Double, consistency: Double?) {
        if let need = intelligence.lastSleepNeedHours {
            return (need, intelligence.lastSleepConsistency)
        }
        let nightly = days.compactMap { $0.totalSleepMin.map { $0 / 60 } }.filter { $0 > 0 }
        return (AnalyticsEngine.Rest.personalizedNeedHours(nightlyHours: nightly, age: age),
                VitalityEngine.sleepConsistency(nightlyHours: Array(nightly.suffix(28))))
    }
}

/// What made last night's sleep score what it is: each factor, the points it earned, the points it lost,
/// and what full marks takes.
struct SleepScoreBreakdownView: View {
    /// Wake-day key (YYYY-MM-DD). nil = the most recent scored night.
    var dayKey: String?

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var intelligence: IntelligenceEngine
    @EnvironmentObject private var profile: ProfileStore

    private var daily: DailyMetric? {
        if let dayKey { return repo.days.last { $0.day == dayKey } }
        return repo.days.last { ($0.totalSleepMin ?? 0) > 0 && $0.efficiency != nil }
    }

    private var breakdown: AnalyticsEngine.Rest.Breakdown? {
        guard let d = daily else { return nil }
        let inputs = SleepScoreInputs.resolve(intelligence: intelligence, days: repo.days, age: profile.age)
        return AnalyticsEngine.Rest.breakdown(daily: d, needHours: inputs.needHours,
                                              consistency: inputs.consistency)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                if let b = breakdown, let d = daily {
                    header(b, day: d.day)
                    if let imported = repo.importedSleep[d.day]?.performancePct {
                        Text("This night also has WHOOP's own score from your import: \(Int(imported.rounded())). The Sleep tab shows that one; the breakdown below is NOOP's scoring of the same night.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(b.factors, id: \.kind) { f in
                        factorCard(f, b)
                    }
                    Text("Stages come from heart rate and motion, not brain waves, so deep and REM are estimates. The score uses your personal sleep need, learned from your longer nights.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("No scored night yet. Wear the strap to bed and sync in the morning.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .padding(.horizontal, NoopMetrics.space4)
            .padding(.vertical, NoopMetrics.space4)
        }
        .background(StrandPalette.surfaceBase)
        .navigationTitle("Sleep score")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Header

    private func header(_ b: AnalyticsEngine.Rest.Breakdown, day: String) -> some View {
        NoopCard(tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    Text("\(Int(b.total.rounded()))")
                        .font(StrandFont.number(48))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("/ 100")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Spacer()
                    Text(Self.dayLabel(day))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                if let worst = b.factors.max(by: { $0.pointsLost < $1.pointsLost }), worst.pointsLost >= 1 {
                    Text("Biggest hit: \(Self.name(worst.kind)), \(Int(worst.pointsLost.rounded())) points.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                } else {
                    Text("Nothing held this one back.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
            }
        }
    }

    // MARK: - Factor rows

    private func factorCard(_ f: AnalyticsEngine.Rest.Factor, _ b: AnalyticsEngine.Rest.Breakdown) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HStack {
                    Text(Self.name(f.kind))
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Text("\(Int(f.points.rounded())) / \(Int(f.maxPoints.rounded()))")
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(StrandPalette.surfaceInset)
                        Capsule().fill(StrandPalette.restColor)
                            .frame(width: max(4, geo.size.width * f.subScore))
                    }
                }
                .frame(height: 6)
                .accessibilityHidden(true)
                Text(Self.detail(f.kind, b))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if f.pointsLost >= 1 {
                    Text(Self.fullMarks(f.kind, b))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Copy

    static func name(_ k: AnalyticsEngine.Rest.Factor.Kind) -> String {
        switch k {
        case .duration: return String(localized: "Hours slept")
        case .efficiency: return String(localized: "Time awake in bed")
        case .restorative: return String(localized: "Deep and REM")
        case .consistency: return String(localized: "Regular schedule")
        }
    }

    static func detail(_ k: AnalyticsEngine.Rest.Factor.Kind, _ b: AnalyticsEngine.Rest.Breakdown) -> String {
        switch k {
        case .duration:
            return String(localized: "Slept \(hm(b.asleepHours)) against a need of \(hm(b.needHours)).")
        case .efficiency:
            let awakeH = b.efficiency > 0 ? b.asleepHours / b.efficiency - b.asleepHours : 0
            return String(localized: "Asleep \(pct(b.efficiency)) of your time in bed, awake for about \(hm(awakeH)).")
        case .restorative:
            if let deep = b.deepShare {
                return String(localized: "Deep and REM made up \(pct(b.restorativeShare)) of your sleep. Deep alone was \(pct(deep)).")
            }
            return String(localized: "Deep and REM made up \(pct(b.restorativeShare)) of your sleep.")
        case .consistency:
            if let c = b.consistency {
                return String(localized: "How steady your sleep length has been over the last 4 weeks: \(Int((c * 100).rounded())) out of 100.")
            }
            return String(localized: "Not enough nights yet to judge, so this counts as average.")
        }
    }

    static func fullMarks(_ k: AnalyticsEngine.Rest.Factor.Kind, _ b: AnalyticsEngine.Rest.Breakdown) -> String {
        typealias R = AnalyticsEngine.Rest
        switch k {
        case .duration:
            let short = max(0, b.needHours - b.asleepHours)
            return String(localized: "Full points at \(hm(b.needHours)). You were \(hm(short)) short, and each missing hour costs more than the last.")
        case .efficiency:
            return String(localized: "Full points at \(pct(R.efficiencyFull)) or better. Zero at \(pct(R.efficiencyFloor)).")
        case .restorative:
            return String(localized: "Full points at \(pct(R.restorativeTarget)) deep and REM, with deep at \(pct(R.deepShareTarget)) or more.")
        case .consistency:
            return String(localized: "Full points for sleeping about the same amount every night.")
        }
    }

    static func hm(_ hours: Double) -> String {
        let total = max(0, Int((hours * 60).rounded()))
        let h = total / 60, m = total % 60
        if h == 0 { return String(localized: "\(m)m") }
        return m == 0 ? String(localized: "\(h)h") : String(localized: "\(h)h \(m)m")
    }

    static func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }

    static func dayLabel(_ day: String) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: day) else { return day }
        if Calendar.current.isDateInToday(d) { return String(localized: "Last night") }
        let out = DateFormatter()
        out.locale = AppLanguage.activeLocale
        out.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return out.string(from: d)
    }
}

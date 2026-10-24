import SwiftUI
import StrandDesign
import StrandAnalytics

/// Sleep cycles and REM for the shown night: how many cycles, how long they ran, when REM started, how it
/// built through the night, plus wake-ups and the longest unbroken stretch.
struct SleepCyclesCard: View {
    let intervals: [SleepInterval]
    /// False for nights whose stages were rebuilt from totals (imports), which have no real cycles.
    let staged: Bool

    private var result: SleepArchitecture.Result? {
        guard staged else { return nil }
        return SleepArchitecture.analyze(intervals.map {
            SleepArchitecture.Segment(stage: Self.stage($0.stage), start: $0.start, end: $0.end)
        })
    }

    static func stage(_ s: SleepStage) -> SleepArchitecture.Stage {
        switch s {
        case .awake: return .wake
        case .light: return .light
        case .deep: return .deep
        case .rem: return .rem
        }
    }

    var body: some View {
        NoopCard(tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("Cycles and REM").strandOverline()
                if let r = result {
                    HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space4) {
                        bigStat("\(r.cycles)", r.cycles == 1 ? String(localized: "cycle") : String(localized: "cycles"))
                        bigStat(r.averageCycleMinutes.map { "\(Int($0.rounded()))" } ?? "–", String(localized: "min each"))
                        bigStat(r.remLatencyMinutes.map { "\(Int($0.rounded()))" } ?? "–", String(localized: "min to first REM"))
                    }
                    cycleTimeline(r)
                    if r.cycleSpans.count >= 2 { remGrowth(r) }
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(insights(r).enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: line.good ? "checkmark.circle.fill" : "exclamationmark.circle")
                                    .foregroundStyle(line.good ? StrandPalette.statusPositive : StrandPalette.recovery055)
                                    .font(StrandFont.footnote)
                                Text(line.text)
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Text("A cycle is light and deep sleep ending in REM, about 90 minutes. Most nights run 4 to 6. Stages come from heart rate and motion, so treat these as estimates.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(staged
                         ? "Not enough staged sleep on this night to read cycles."
                         : "This night came from an import with totals only, so there are no cycles to read. Nights the strap stages itself show them.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The night as stage bands (deep low, REM high), cycle boundaries numbered above, wake-ups marked.
    private func cycleTimeline(_ r: SleepArchitecture.Result) -> some View {
        let span = max(1, r.sleepEnd - r.sleepOnset)
        let segs = intervals.filter { $0.end > r.sleepOnset && $0.start < r.sleepEnd }
        return VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .topLeading) {
                    // Alternating cycle shading with the cycle number.
                    ForEach(Array(r.cycleSpans.enumerated()), id: \.offset) { i, c in
                        let x = w * c.start / span
                        let cw = max(2, w * (c.end - c.start) / span)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(StrandPalette.restColor.opacity(i % 2 == 0 ? 0.10 : 0.18))
                            .frame(width: cw, height: 54)
                            .offset(x: x, y: 12)
                        Text("\(i + 1)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(c.interrupted ? StrandPalette.recovery030 : StrandPalette.textTertiary)
                            .frame(width: cw)
                            .offset(x: x, y: 0)
                    }
                    // Stages: REM on top, light in the middle, deep at the bottom.
                    ForEach(segs, id: \.id) { iv in
                        let a = max(iv.start, r.sleepOnset) - r.sleepOnset
                        let b = min(iv.end, r.sleepEnd) - r.sleepOnset
                        let lane = Self.lane(iv.stage)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(StrandPalette.sleepStageColor(iv.stage))
                            .frame(width: max(1, w * (b - a) / span), height: 11)
                            .offset(x: w * a / span, y: 14 + CGFloat(lane) * 13)
                    }
                }
            }
            .frame(height: 68)
            HStack {
                Text(Date(timeIntervalSince1970: r.sleepOnset), style: .time)
                Spacer()
                legendDot(.rem, "REM")
                legendDot(.light, "Light")
                legendDot(.deep, "Deep")
                legendDot(.awake, "Awake")
                Spacer()
                Text(Date(timeIntervalSince1970: r.sleepEnd), style: .time)
            }
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(r.cycles) cycles. \(r.awakenings) wake-ups."))
    }

    private static func lane(_ s: SleepStage) -> Int {
        switch s {
        case .awake: return 0
        case .rem: return 1
        case .light: return 2
        case .deep: return 3
        }
    }

    private func legendDot(_ s: SleepStage, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 2) {
            Circle().fill(StrandPalette.sleepStageColor(s)).frame(width: 6, height: 6)
            Text(label).font(.system(size: 9))
        }
    }

    /// REM and deep minutes in each cycle as paired bars, so REM building toward morning is plain to see.
    private func remGrowth(_ r: SleepArchitecture.Result) -> some View {
        let cycles = r.cycleSpans
        let top = max(10, cycles.map { max($0.remMinutes, $0.deepMinutes) }.max() ?? 10)
        return VStack(alignment: .leading, spacing: 4) {
            Text("REM and deep by cycle").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(cycles.enumerated()), id: \.offset) { i, c in
                    VStack(spacing: 2) {
                        Text("\(Int(c.remMinutes.rounded()))")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(StrandPalette.sleepStageColor(.rem))
                        HStack(alignment: .bottom, spacing: 2) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(StrandPalette.sleepStageColor(.deep))
                                .frame(width: 7, height: max(2, 44 * c.deepMinutes / top))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(StrandPalette.sleepStageColor(.rem))
                                .frame(width: 11, height: max(2, 44 * c.remMinutes / top))
                        }
                        Text("\(i + 1)").font(.system(size: 9)).foregroundStyle(StrandPalette.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 70, alignment: .bottom)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("REM by cycle: \(cycles.map { "\(Int($0.remMinutes.rounded()))" }.joined(separator: ", ")) minutes"))
    }

    private struct Insight { let good: Bool; let text: String }

    /// The few things that matter about this night's structure, each against the usual range.
    private func insights(_ r: SleepArchitecture.Result) -> [Insight] {
        var out: [Insight] = []
        if let l = r.remLatencyMinutes {
            let m = Int(l.rounded())
            if l < 50 {
                out.append(Insight(good: false, text: String(localized: "First REM came \(m) min after falling asleep, early against the usual 70 to 120. That tends to follow short or broken sleep the night before.")))
            } else if l > 120 {
                out.append(Insight(good: false, text: String(localized: "First REM took \(m) min, later than the usual 70 to 120. Alcohol, late caffeine, a late hard session or a warm room push it back.")))
            } else {
                out.append(Insight(good: true, text: String(localized: "First REM at \(m) min, inside the usual 70 to 120.")))
            }
        }
        let c = r.cycleSpans
        if c.count >= 2, let first = c.first, let peak = c.max(by: { $0.remMinutes < $1.remMinutes }),
           let peakIdx = c.firstIndex(of: peak) {
            let a = Int(first.remMinutes.rounded()), b = Int(peak.remMinutes.rounded())
            if peakIdx >= c.count - 2, b > a {
                out.append(Insight(good: true, text: String(localized: "REM built from \(a) min in the first cycle to \(b) min in cycle \(peakIdx + 1), the pattern a well-rested night shows.")))
            } else {
                out.append(Insight(good: false, text: String(localized: "REM peaked at \(b) min in cycle \(peakIdx + 1), then shortened. The longest REM usually comes last, so the end of the night was cut short or disturbed.")))
            }
        }
        if let d = r.deepFirstThirdShare {
            let p = Int((d * 100).rounded())
            out.append(d >= 0.5
                ? Insight(good: true, text: String(localized: "\(p)% of deep sleep came in the first third of the night, where it belongs."))
                : Insight(good: false, text: String(localized: "Only \(p)% of deep sleep came in the first third. A late meal, alcohol or a late workout can delay it.")))
        }
        let broken = c.enumerated().filter { $0.element.interrupted }.map { $0.offset + 1 }
        if !broken.isEmpty {
            let list = broken.map(String.init).joined(separator: ", ")
            out.append(Insight(good: false, text: String(localized: "Wake-ups broke cycle \(list) (\(r.awakenings) over 2 min, \(Self.minutes(r.wasoMinutes)) awake in all). Longest unbroken stretch \(Self.minutes(r.longestStretchMinutes)).")))
        } else if r.cycles > 0 {
            out.append(Insight(good: true, text: String(localized: "No cycle was broken by a wake-up. Longest unbroken stretch \(Self.minutes(r.longestStretchMinutes)).")))
        }
        if r.trailingMinutes >= 25, r.trailingMinutes <= 80 {
            out.append(Insight(good: false, text: String(localized: "You woke \(Int(r.trailingMinutes.rounded())) min into a new cycle, which can feel groggy. Waking about \(Int(r.trailingMinutes.rounded())) min earlier, or at the end of that cycle, lands between cycles.")))
        }
        if r.patterns.contains(.fragmentedRem) {
            out.append(Insight(good: false, text: Self.explain(.fragmentedRem)))
        }
        if r.patterns.contains(.fewCycles) {
            out.append(Insight(good: false, text: Self.explain(.fewCycles)))
        }
        return out
    }

    private func bigStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(StrandFont.number(28)).foregroundStyle(StrandPalette.textPrimary)
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    static func minutes(_ m: Double) -> String {
        let t = Int(m.rounded())
        return t >= 60 ? String(localized: "\(t / 60)h \(t % 60)m") : String(localized: "\(t) min")
    }

    static func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }

    static func explain(_ p: SleepArchitecture.Pattern) -> String {
        switch p {
        case .typical:
            return String(localized: "A healthy pattern: REM got longer through the night and most of it came late.")
        case .earlyRem:
            return String(localized: "REM came very early. That often follows short sleep the night before, or catching up after a rough stretch.")
        case .lateRem:
            return String(localized: "REM started late. Alcohol, late caffeine, a late hard session or a hot room can push it back.")
        case .fragmentedRem:
            return String(localized: "REM came in lots of short bits instead of a few long periods. Wake-ups and a restless room break it up.")
        case .fewCycles:
            return String(localized: "Fewer cycles than a night this long usually gives. Broken sleep cuts cycles short.")
        case .flatRem:
            return String(localized: "REM didn't build toward morning. Waking early or a disturbed last few hours takes the longest REM.")
        }
    }
}

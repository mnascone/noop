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
                        bigStat(r.remLatencyMinutes.map { "\(Int($0.rounded()))" } ?? "–", String(localized: "min to REM"))
                    }
                    cycleStrip(r)
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

    /// One strip for the night: each cycle a segment, REM in purple where it fell, wake-ups as dots above,
    /// and each cycle's REM minutes under it.
    private func cycleStrip(_ r: SleepArchitecture.Result) -> some View {
        let span = max(1, r.sleepEnd - r.sleepOnset)
        let rem = StrandPalette.sleepStageColor(.rem)
        let gap: CGFloat = 3
        let lastEnd = r.cycleSpans.last?.end ?? 0
        let tailShare: CGFloat = CGFloat((span - lastEnd) / span)
        let tailStart: CGFloat = CGFloat(lastEnd / span)
        let wakeShares: [CGFloat] = r.wakeBouts.map { CGFloat(($0.start + $0.end) / 2 / span) }
        let remList: String = r.cycleSpans.map { String(Int($0.remMinutes.rounded())) }.joined(separator: ", ")
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let w: CGFloat = geo.size.width
                ZStack(alignment: .topLeading) {
                    ForEach(Array(r.cycleSpans.enumerated()), id: \.offset) { _, c in
                        cycleSegment(c, r, width: w, span: span, gap: gap)
                    }
                    if span - lastEnd > 60 {
                        // Sleep after the last full cycle that didn't reach REM.
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(StrandPalette.restColor.opacity(0.45),
                                          style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .frame(width: max(4, w * tailShare), height: 22)
                            .offset(x: w * tailStart, y: 8)
                    }
                    ForEach(Array(wakeShares.enumerated()), id: \.offset) { _, share in
                        Circle().fill(StrandPalette.recovery055)
                            .frame(width: 4, height: 4)
                            .offset(x: w * share - 2, y: 0)
                    }
                }
            }
            .frame(height: 48)
            HStack(spacing: 4) {
                Text(Date(timeIntervalSince1970: r.sleepOnset), style: .time)
                Spacer()
                Circle().fill(rem).frame(width: 6, height: 6)
                Text("REM")
                Circle().fill(StrandPalette.recovery055).frame(width: 4, height: 4).padding(.leading, 6)
                Text("Woke up")
                Spacer()
                Text(Date(timeIntervalSince1970: r.sleepEnd), style: .time)
            }
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(r.cycles) cycles. REM per cycle: \(remList) minutes. \(r.awakenings) wake-ups."))
    }

    /// One cycle: a muted segment with its REM in purple, and its REM minutes under it.
    private func cycleSegment(_ c: SleepArchitecture.Cycle, _ r: SleepArchitecture.Result,
                              width w: CGFloat, span: Double, gap: CGFloat) -> some View {
        let x: CGFloat = w * CGFloat(c.start / span)
        let cw: CGFloat = max(4, w * CGFloat((c.end - c.start) / span) - gap)
        let rem = StrandPalette.sleepStageColor(.rem)
        let parts: [(x: CGFloat, w: CGFloat)] = r.remEpisodes.compactMap { e in
            let a = max(e.start, c.start), b = min(e.end, c.end)
            guard b > a else { return nil }
            return (w * CGFloat((a - c.start) / span), max(2, w * CGFloat((b - a) / span)))
        }
        return ZStack(alignment: .topLeading) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(StrandPalette.restColor.opacity(0.22))
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    Rectangle().fill(rem).frame(width: p.w).offset(x: p.x)
                }
            }
            .frame(width: cw, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .offset(y: 8)
            Text("\(Int(c.remMinutes.rounded()))m")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(cw >= 24 ? rem : Color.clear)
                .frame(width: cw)
                .offset(y: 34)
        }
        .offset(x: x)
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
        if !broken.isEmpty, broken.count == c.count, c.count >= 2 {
            out.append(Insight(good: false, text: String(localized: "Every cycle had a wake-up: \(r.awakenings) over 2 min, \(Self.minutes(r.wasoMinutes)) awake in all. Longest unbroken stretch \(Self.minutes(r.longestStretchMinutes)).")))
        } else if !broken.isEmpty {
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

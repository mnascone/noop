import SwiftUI
import StrandDesign
import StrandAnalytics

/// Sleep cycles and REM for the shown night: how many cycles, how long they ran, when REM started, how it
/// built through the night, plus wake-ups and the longest unbroken stretch.
struct SleepCyclesCard: View {
    let intervals: [SleepInterval]
    /// False for nights whose stages were rebuilt from totals (imports), which have no real cycles.
    let staged: Bool

    /// The tapped cycle (0-based), shown in detail under the strip.
    @State private var selected: Int?

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
                    if let i = selected, r.cycleSpans.indices.contains(i) {
                        cycleDetail(i, r)
                    } else {
                        Text("Tap a cycle to see its stages.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
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

    /// One strip for the night: a tappable segment per cycle with its REM in purple, wake-ups as dots
    /// above, each cycle's number and REM minutes under it.
    private func cycleStrip(_ r: SleepArchitecture.Result) -> some View {
        let span: Double = max(1, r.sleepEnd - r.sleepOnset)
        let lastEnd: Double = r.cycleSpans.last?.end ?? 0
        let tail: Double = span - lastEnd
        let wakeShares: [CGFloat] = r.wakeBouts.map { CGFloat(($0.start + $0.end) / 2 / span) }
        let remList: String = r.cycleSpans.map { String(Int($0.remMinutes.rounded())) }.joined(separator: ", ")
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let w: CGFloat = geo.size.width
                let gap: CGFloat = 3
                let count: CGFloat = CGFloat(r.cycleSpans.count + (tail > 60 ? 1 : 0))
                let usable: CGFloat = max(1, w - gap * max(0, count - 1))
                ZStack(alignment: .topLeading) {
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(Array(r.cycleSpans.enumerated()), id: \.offset) { i, c in
                            cycleSegment(i, c, r, width: usable * CGFloat((c.end - c.start) / span), span: span)
                        }
                        if tail > 60 {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(StrandPalette.restColor.opacity(0.45),
                                              style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .frame(width: max(4, usable * CGFloat(tail / span)), height: 30)
                                .padding(.top, 8)
                        }
                    }
                    ForEach(Array(wakeShares.enumerated()), id: \.offset) { _, share in
                        Circle().fill(StrandPalette.recovery055)
                            .frame(width: 4, height: 4)
                            .offset(x: w * share - 2, y: 0)
                    }
                    .allowsHitTesting(false)
                }
            }
            .frame(height: 70)
            HStack(spacing: 4) {
                Text(Date(timeIntervalSince1970: r.sleepOnset), style: .time)
                Spacer()
                Circle().fill(StrandPalette.sleepStageColor(.rem)).frame(width: 6, height: 6)
                Text("REM")
                Circle().fill(StrandPalette.recovery055).frame(width: 4, height: 4).padding(.leading, 6)
                Text("Woke up")
                Spacer()
                Text(Date(timeIntervalSince1970: r.sleepEnd), style: .time)
            }
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(r.cycles) cycles. REM per cycle: \(remList) minutes. \(r.awakenings) wake-ups."))
    }

    /// One cycle, tappable: a segment with its REM in purple at its real place, the cycle number and its REM
    /// minutes under it. The selected one is outlined and the others dim.
    private func cycleSegment(_ i: Int, _ c: SleepArchitecture.Cycle, _ r: SleepArchitecture.Result,
                              width cw: CGFloat, span: Double) -> some View {
        let len: Double = max(1, c.end - c.start)
        let rem = StrandPalette.sleepStageColor(.rem)
        let isSel: Bool = selected == i
        let dim: Bool = selected != nil && !isSel
        let parts: [(x: CGFloat, w: CGFloat)] = r.remEpisodes.compactMap { e in
            let a = max(e.start, c.start), b = min(e.end, c.end)
            guard b > a else { return nil }
            return (cw * CGFloat((a - c.start) / len), max(2, cw * CGFloat((b - a) / len)))
        }
        let showLabel: Bool = cw >= 22
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { selected = isSel ? nil : i }
        } label: {
            VStack(spacing: 3) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(StrandPalette.restColor.opacity(isSel ? 0.38 : 0.22))
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                        Rectangle().fill(rem).frame(width: p.w).offset(x: p.x)
                    }
                }
                .frame(width: cw, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(isSel ? StrandPalette.textPrimary : Color.clear, lineWidth: 1.5)
                )
                Text(showLabel ? "\(Int(c.remMinutes.rounded()))m" : " ")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(rem)
                Text(showLabel ? "\(i + 1)" : " ")
                    .font(.system(size: 9, weight: isSel ? .bold : .regular))
                    .foregroundStyle(isSel ? StrandPalette.textPrimary : StrandPalette.textTertiary)
            }
            .frame(width: cw)
            .padding(.top, 8)
            .opacity(dim ? 0.45 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Cycle \(i + 1), \(Int(c.minutes.rounded())) minutes, REM \(Int(c.remMinutes.rounded())) minutes"))
    }

    /// The tapped cycle: its clock times, minutes in each stage, a stage chart of just that stretch, and
    /// what interrupted it.
    private func cycleDetail(_ i: Int, _ r: SleepArchitecture.Result) -> some View {
        let c = r.cycleSpans[i]
        let a: Double = r.sleepOnset + c.start
        let b: Double = r.sleepOnset + c.end
        let segs: [SleepInterval] = intervals.filter { $0.end > a && $0.start < b }
        func minutes(_ s: SleepStage) -> Double {
            segs.filter { $0.stage == s }.reduce(0) { $0 + (min($1.end, b) - max($1.start, a)) } / 60
        }
        let awake = minutes(.awake), light = minutes(.light), deep = minutes(.deep), remM = minutes(.rem)
        let wakes = r.wakeBouts.filter { $0.start < c.end && $0.end > c.start }
        let firstRem: Double? = r.remEpisodes.first { $0.end > c.start && $0.start < c.end }
            .map { (max($0.start, c.start) - c.start) / 60 }
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "Cycle \(i + 1)"))
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(Date(timeIntervalSince1970: a), style: .time)
                Text("–")
                Text(Date(timeIntervalSince1970: b), style: .time)
                Spacer()
                Text(Self.minutes(c.minutes))
                    .font(StrandFont.captionNumber.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            CycleStages(segments: segs, start: a, end: b)
                .frame(height: 64)
            HStack(spacing: 0) {
                stageFigure(.deep, "Deep", deep)
                stageFigure(.light, "Light", light)
                stageFigure(.rem, "REM", remM)
                stageFigure(.awake, "Awake", awake)
            }
            Text(detailLine(firstRem: firstRem, wakes: wakes))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(NoopMetrics.space3)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StrandPalette.surfaceInset.opacity(0.6)))
        .transition(.opacity)
    }

    private func stageFigure(_ s: SleepStage, _ label: LocalizedStringKey, _ m: Double) -> some View {
        VStack(spacing: 1) {
            Text("\(Int(m.rounded()))m")
                .font(StrandFont.captionNumber.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
            HStack(spacing: 3) {
                Circle().fill(StrandPalette.sleepStageColor(s)).frame(width: 6, height: 6)
                Text(label).font(.system(size: 10)).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func detailLine(firstRem: Double?, wakes: [SleepArchitecture.Episode]) -> String {
        var parts: [String] = []
        if let f = firstRem {
            parts.append(String(localized: "REM began \(Int(f.rounded())) min into this cycle."))
        }
        if wakes.isEmpty {
            parts.append(String(localized: "No wake-ups over 2 min."))
        } else {
            let total = wakes.reduce(0) { $0 + $1.minutes }
            parts.append(wakes.count == 1
                ? String(localized: "One wake-up, \(Int(total.rounded())) min.")
                : String(localized: "\(wakes.count) wake-ups, \(Int(total.rounded())) min in all."))
        }
        return parts.joined(separator: " ")
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

/// A stage chart of one cycle: REM on top, then light, deep at the bottom, awake above REM.
private struct CycleStages: View {
    let segments: [SleepInterval]
    let start: Double
    let end: Double

    private static func lane(_ s: SleepStage) -> CGFloat {
        switch s {
        case .awake: return 0
        case .rem: return 1
        case .light: return 2
        case .deep: return 3
        }
    }

    var body: some View {
        GeometryReader { geo in
            let w: CGFloat = geo.size.width
            let laneH: CGFloat = geo.size.height / 4
            let span: Double = max(1, end - start)
            ZStack(alignment: .topLeading) {
                ForEach(segments, id: \.id) { iv in
                    let a: CGFloat = CGFloat((max(iv.start, start) - start) / span)
                    let b: CGFloat = CGFloat((min(iv.end, end) - start) / span)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(StrandPalette.sleepStageColor(iv.stage))
                        .frame(width: max(1.5, w * (b - a)), height: laneH - 4)
                        .offset(x: w * a, y: laneH * Self.lane(iv.stage) + 2)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

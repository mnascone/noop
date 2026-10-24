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
                        bigStat("\(r.remEpisodes.count)", String(localized: "REM periods"))
                    }
                    remStrip(r)
                    VStack(alignment: .leading, spacing: 6) {
                        row(String(localized: "First REM"), r.remLatencyMinutes.map { Self.minutes($0) + " " + String(localized: "after falling asleep") } ?? "–")
                        row(String(localized: "Longest REM"), r.longestRemMinutes.map(Self.minutes) ?? "–")
                        row(String(localized: "REM in the second half"), r.remSecondHalfShare.map(Self.pct) ?? "–")
                        row(String(localized: "Deep in the first third"), r.deepFirstThirdShare.map(Self.pct) ?? "–")
                        row(String(localized: "Wake-ups"), r.awakenings == 0
                            ? String(localized: "None over 2 min")
                            : String(localized: "\(r.awakenings), \(Self.minutes(r.wasoMinutes)) awake in total"))
                        row(String(localized: "Longest unbroken sleep"), Self.minutes(r.longestStretchMinutes))
                    }
                    ForEach(r.patterns, id: \.self) { p in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: p == .typical ? "checkmark.circle.fill" : "info.circle")
                                .foregroundStyle(p == .typical ? StrandPalette.statusPositive : StrandPalette.restColor)
                                .font(StrandFont.footnote)
                            Text(Self.explain(p))
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text("A cycle is a stretch of light and deep sleep that ends in REM. Most nights run 4 to 6 of them, about 90 minutes each. Stages here come from heart rate and motion, so treat these as estimates.")
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

    /// The night as a bar with each REM period marked where it fell.
    private func remStrip(_ r: SleepArchitecture.Result) -> some View {
        let span = max(1, r.sleepEnd - r.sleepOnset)
        return VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(StrandPalette.surfaceInset)
                    ForEach(Array(r.remEpisodes.enumerated()), id: \.offset) { _, e in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(StrandPalette.sleepStageColor(.rem))
                            .frame(width: max(3, geo.size.width * (e.end - e.start) / span))
                            .offset(x: geo.size.width * e.start / span)
                    }
                }
            }
            .frame(height: 12)
            HStack {
                Text("Asleep").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                Text("REM periods").font(StrandFont.caption).foregroundStyle(StrandPalette.sleepStageColor(.rem))
                Spacer()
                Text("Wake").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(r.remEpisodes.count) REM periods across the night"))
    }

    private func bigStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(StrandFont.number(28)).foregroundStyle(StrandPalette.textPrimary)
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 8)
            Text(value).font(StrandFont.footnote.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                .multilineTextAlignment(.trailing)
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

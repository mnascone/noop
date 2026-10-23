import SwiftUI
import StrandDesign
import StrandAnalytics

/// Live sets / intervals and the rest timer for the active workout. Renders nothing for sports that
/// aren't tracked.
struct LiveIntervalCard: View {
    @ObservedObject private var tracker = LiveIntervalTracker.shared

    var body: some View {
        if let mode = tracker.mode, let s = tracker.summary {
            NoopCard(tint: StrandPalette.accent) {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    HStack {
                        Text(phaseTitle(mode, s))
                            .font(StrandFont.overline)
                            .tracking(1.4)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Spacer()
                        Text("\(s.count) \(LiveIntervalModes.unitName(mode, count: s.count))")
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    Text(bigClock(s))
                        .font(StrandFont.number(44))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .contentTransition(.numericText())
                        .monospacedDigit()
                    HStack(spacing: NoopMetrics.space4) {
                        stat(String(localized: "Last rest"), s.lastRestS)
                        stat(String(localized: "Avg rest"), s.avgRestS)
                        stat(String(localized: "Longest"), s.longestRestS)
                    }
                    Text(mode == .lifting
                         ? "From heart rate. Rests under a minute can merge two sets into one."
                         : "From heart rate. Very short recoveries can merge two intervals.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func phaseTitle(_ mode: WorkRestSegmenter.Mode, _ s: WorkRestSegmenter.Summary) -> String {
        switch s.phase {
        case .warmingUp:
            return mode == .lifting ? String(localized: "WAITING FOR YOUR FIRST SET")
                                    : String(localized: "WAITING FOR THE FIRST INTERVAL")
        case .working:
            return mode == .lifting ? String(localized: "SET \(s.count + 1)")
                                    : String(localized: "INTERVAL \(s.count + 1)")
        case .resting:
            return String(localized: "RESTING")
        }
    }

    private func bigClock(_ s: WorkRestSegmenter.Summary) -> String {
        if let r = s.currentRestS { return LiveIntervalTracker.clock(r) }
        if let w = s.currentWorkS { return LiveIntervalTracker.clock(w) }
        return "–"
    }

    private func stat(_ label: String, _ seconds: Int?) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
            Text(label)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
            Text(seconds.map(LiveIntervalTracker.clock) ?? "–")
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textPrimary)
        }
    }
}

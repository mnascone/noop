import SwiftUI
import StrandDesign
import StrandAnalytics

/// Live sets / intervals and the rest timer for the active workout. Renders nothing for sports that
/// aren't tracked.
struct LiveIntervalCard: View {
    @ObservedObject private var tracker = LiveIntervalTracker.shared
    @ObservedObject private var reps = LiveRepTracker.shared

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
                    if mode == .lifting, reps.active || !reps.sets.isEmpty {
                        repRow
                    }
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

    /// Reps per finished set from wrist motion, plus the set in progress.
    private var repRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fingers.spread")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.accent)
                Text("Reps")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                if let now = reps.currentReps {
                    Text(String(localized: "this set: \(now)"))
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .contentTransition(.numericText())
                }
                Spacer()
            }
            if !reps.sets.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(reps.sets.enumerated()), id: \.offset) { i, set in
                            VStack(spacing: 0) {
                                Text("\(set.reps)")
                                    .font(StrandFont.headline)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text(String(localized: "set \(i + 1)"))
                                    .font(.system(size: 9))
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                            .frame(minWidth: 40)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 8).fill(StrandPalette.surfaceInset))
                        }
                    }
                }
            } else {
                Text("Counting from your strap's motion. Finished sets show here.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
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

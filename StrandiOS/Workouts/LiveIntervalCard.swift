import SwiftUI
import StrandDesign
import StrandAnalytics

/// Live sets / intervals and the rest timer for the active workout. Renders nothing for sports that
/// aren't tracked.
struct LiveIntervalCard: View {
    @ObservedObject private var tracker = LiveIntervalTracker.shared
    @ObservedObject private var reps = LiveRepTracker.shared
    @AppStorage(LiveRepTracker.enabledKey) private var repCounting = false
    @AppStorage(SetReadyPrefs.targetRestKey) private var targetRest = 120
    @State private var showSettings = false

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
                        if mode == .lifting {
                            Button { showSettings = true } label: {
                                Image(systemName: "slider.horizontal.3")
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.accent)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Sets and rest settings")
                        }
                    }
                    HStack(alignment: .center, spacing: NoopMetrics.space3) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bigClock(s))
                                .font(StrandFont.number(44))
                                .foregroundStyle(StrandPalette.textPrimary)
                                .contentTransition(.numericText())
                                .monospacedDigit()
                            if mode == .lifting, let rest = s.currentRestS {
                                restTarget(rest)
                            }
                        }
                        Spacer(minLength: 0)
                        if let r = tracker.readiness {
                            readyLight(r)
                        }
                    }
                    if mode == .lifting {
                        if reps.active || !reps.sets.isEmpty {
                            repRow
                        }
                        Toggle(isOn: $repCounting) {
                            Text("Count reps from wrist motion")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        .tint(StrandPalette.accent)
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
            .accessibilityElement(children: .contain)
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    SetReadySettingsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } }
                        }
                }
            }
        }
    }

    /// Rest against the target: a thin bar and "1:10 of 2:00", or "+0:20 over".
    private func restTarget(_ rest: Int) -> some View {
        let target = max(1, targetRest)
        let frac = min(1, Double(rest) / Double(target))
        return VStack(alignment: .leading, spacing: 3) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(StrandPalette.surfaceInset)
                    Capsule().fill(rest >= target ? StrandPalette.statusPositive : StrandPalette.accent)
                        .frame(width: g.size.width * frac)
                }
            }
            .frame(width: 140, height: 5)
            Text(rest >= target
                 ? String(localized: "Target \(LiveIntervalTracker.clock(target)) reached, +\(LiveIntervalTracker.clock(rest - target))")
                 : String(localized: "\(LiveIntervalTracker.clock(target - rest)) to target rest"))
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .monospacedDigit()
        }
    }

    /// Green / yellow / red for the next set, with the heart rate it's waiting for.
    private func readyLight(_ r: SetReadiness.Reading) -> some View {
        let color: Color = r.light == .green ? StrandPalette.statusPositive
            : (r.light == .yellow ? StrandPalette.recovery055 : StrandPalette.recovery000)
        let word: String = r.light == .green ? String(localized: "Go")
            : (r.light == .yellow ? String(localized: "Almost") : String(localized: "Rest"))
        return VStack(spacing: 4) {
            ZStack {
                Circle().fill(color.opacity(0.2)).frame(width: 64, height: 64)
                Circle().fill(color).frame(width: 40, height: 40)
                    .shadow(color: color.opacity(0.6), radius: 8)
                Text(word)
                    .font(StrandFont.caption.weight(.bold))
                    .foregroundStyle(Color.black.opacity(0.75))
            }
            Text(String(localized: "Go under \(r.thresholds.greenBpm)"))
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .animation(.easeInOut(duration: 0.3), value: r.light)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Next set: \(word). Ready under \(r.thresholds.greenBpm) beats per minute."))
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

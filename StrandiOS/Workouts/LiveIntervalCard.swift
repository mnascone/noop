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
    /// The workout so far, open in the editor.
    @State private var editorTimeline: SetTimeline?
    @AppStorage(SetReadyPrefs.panelKey) private var showPanel = true
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // The settings sheet hangs off this always-present container, not the card, so switching the
        // panel off from inside the sheet can't pull the sheet's anchor out from under it (which could
        // close the whole workout screen with it).
        VStack(spacing: 0) { content }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    SetReadySettingsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } }
                        }
                }
            }
            .sheet(item: $editorTimeline) { t in
                NavigationStack {
                    SetTimelineEditorView(title: String(localized: "Edit sets"), timeline: t,
                                          exercises: tracker.exerciseNames?() ?? []) { updated in
                        tracker.applyEdits(updated.sets, log: updated.history)
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if !showPanel {
            // Hidden in settings: keep one small way back while a workout runs.
            if model.activeWorkout != nil {
                Button { showPanel = true } label: {
                    Label("Show sets and rest", systemImage: "eye")
                        .font(StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        } else if tracker.mode == nil, model.activeWorkout != nil {
            // A sport that isn't tracked by default: offer it, rather than showing nothing.
            Button { tracker.trackAsLifting() } label: {
                Label("Track sets and rest", systemImage: "dumbbell")
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, NoopMetrics.space3)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(StrandPalette.surfaceInset.opacity(0.7)))
            }
            .buttonStyle(.plain)
        } else if let mode = tracker.mode, let s = tracker.summary {
            NoopCard(tint: StrandPalette.accent) {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(headerLine(mode, s))
                            .font(StrandFont.overline)
                            .tracking(1.2)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .lineLimit(1)
                        Spacer()
                        Button { showSettings = true } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.accent)
                                .frame(width: 32, height: 24)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Sets and rest settings")
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
                            } else if let now = reps.currentReps, mode == .lifting {
                                Text(String(localized: "\(now) reps so far"))
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                        Spacer(minLength: 0)
                        if let r = tracker.readiness {
                            readyLight(r)
                        } else if mode == .lifting, SetReadyPrefs.enabled {
                            idleLight(s)
                        }
                    }
                    setStrip(mode)
                    if let line = restLine(s) {
                        Text(line)
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .monospacedDigit()
                    }
                    if let line = recoveryLine {
                        Text(line.text)
                            .font(StrandFont.caption)
                            .foregroundStyle(line.slowing ? StrandPalette.recovery030 : StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if mode == .lifting, reps.active, let a = reps.analysis {
                        MotionMapView(analysis: a)
                    }
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    /// "STRENGTH · SET 4" or "STRENGTH · RESTING".
    private func headerLine(_ mode: WorkRestSegmenter.Mode, _ s: WorkRestSegmenter.Summary) -> String {
        let sport = model.activeWorkout?.sport.uppercased()
        return [sport, phaseTitle(mode, s)].compactMap { $0 }.joined(separator: " · ")
    }

    /// The automatic count and the way into the editor: nothing to confirm, nothing per set.
    private func setStrip(_ mode: WorkRestSegmenter.Mode) -> some View {
        let counted = tracker.sets.filter { !$0.uncertain }.count
        let uncertain = tracker.sets.count - counted
        return HStack(spacing: 8) {
            Text("\(counted) \(LiveIntervalModes.unitName(mode, count: counted))")
                .font(StrandFont.footnote.weight(.semibold))
                .foregroundStyle(StrandPalette.textSecondary)
                .monospacedDigit()
                .contentTransition(.numericText())
            if uncertain > 0 {
                Text(String(localized: "+\(uncertain) uncertain"))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 0)
            Button { editorTimeline = tracker.timelineSnapshot() } label: {
                Label("Edit sets", systemImage: "waveform.path.ecg")
                    .font(StrandFont.footnote.weight(.semibold))
                    .foregroundStyle(StrandPalette.accent)
            }
            .buttonStyle(.plain)
        }
    }

    /// "Rest last 1:45 · avg 1:52 · longest 3:10", or nil before there are two sets.
    private func restLine(_ s: WorkRestSegmenter.Summary) -> String? {
        guard let last = s.lastRestS else { return nil }
        var parts = [String(localized: "Rest last \(LiveIntervalTracker.clock(last))")]
        if let a = s.avgRestS { parts.append(String(localized: "avg \(LiveIntervalTracker.clock(a))")) }
        if let l = s.longestRestS { parts.append(String(localized: "longest \(LiveIntervalTracker.clock(l))")) }
        return parts.joined(separator: " · ")
    }

    /// Heart-rate recovery after the last set in one line, flagged when it's slowing.
    private var recoveryLine: (text: String, slowing: Bool)? {
        let recs = tracker.recoveries
        guard let last = recs.last else { return nil }
        let drops60 = recs.compactMap(\.drop60)
        let avg: Int? = drops60.count >= 2 ? drops60.reduce(0, +) / drops60.count : nil
        let value: String
        if let d = last.drop60 { value = String(localized: "-\(d) bpm in 60 s") }
        else if let d = last.drop30 { value = String(localized: "-\(d) bpm in 30 s") }
        else { return nil }
        var text = String(localized: "Recovery \(value)")
        if let avg { text += " · " + String(localized: "avg -\(avg)") }
        let slowing = avg.map { a in a > 0 && Double(last.drop60 ?? a) < Double(a) * 0.7 } ?? false
        if slowing { text += ". " + String(localized: "Slowing: rest a little longer.") }
        return (text, slowing)
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

    /// The light between readings: grey while a set is on, or before the first one. The word sits under
    /// the light, like the coloured one, so it never has to squeeze inside the circle.
    private func idleLight(_ s: WorkRestSegmenter.Summary) -> some View {
        let word: String = {
            switch s.phase {
            case .working: return String(localized: "Lifting")
            case .warmingUp: return String(localized: "Ready")
            case .resting: return String(localized: "Resting")
            }
        }()
        return VStack(spacing: 4) {
            ZStack {
                Circle().fill(StrandPalette.surfaceInset).frame(width: 64, height: 64)
                Circle().fill(StrandPalette.textTertiary.opacity(0.5)).frame(width: 40, height: 40)
                Image(systemName: s.phase == .warmingUp ? "light.beacon.min" : "figure.strengthtraining.traditional")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            Text(word)
                .font(StrandFont.caption.weight(.semibold))
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// Green / yellow / red for the next set, with the heart rate it's waiting for.
    private func readyLight(_ r: SetReadiness.Reading) -> some View {
        let color: Color = r.light == .green ? StrandPalette.statusPositive
            : (r.light == .yellow ? StrandPalette.recovery055 : StrandPalette.recovery000)
        let word: String = r.light == .green ? String(localized: "Go")
            : (r.light == .yellow ? String(localized: "Almost") : String(localized: "Rest"))
        let icon = r.light == .green ? "checkmark" : (r.light == .yellow ? "hourglass" : "pause.fill")
        return VStack(spacing: 3) {
            ZStack {
                Circle().fill(color.opacity(0.2)).frame(width: 64, height: 64)
                Circle().fill(color).frame(width: 40, height: 40)
                    .shadow(color: color.opacity(0.6), radius: 8)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.7))
            }
            Text(word)
                .font(StrandFont.caption.weight(.bold))
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize()
            Text(String(localized: "Go under \(r.thresholds.greenBpm)"))
                .font(.system(size: 10))
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
                .fixedSize()
        }
        .animation(.easeInOut(duration: 0.3), value: r.light)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Next set: \(word). Ready under \(r.thresholds.greenBpm) beats per minute."))
    }

    private func phaseTitle(_ mode: WorkRestSegmenter.Mode, _ s: WorkRestSegmenter.Summary) -> String {
        switch s.phase {
        case .warmingUp:
            return mode == .lifting ? String(localized: "READY FOR SET 1")
                                    : String(localized: "READY FOR INTERVAL 1")
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
}

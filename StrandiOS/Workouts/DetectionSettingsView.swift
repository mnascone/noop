import SwiftUI
import StrandDesign
import StrandAnalytics

/// Optional controls for set and interval detection, per sport. Changes are previewed on a previous
/// workout before they're applied, and once applied they're used from the next workout on: past
/// workouts keep their sets. What detection has learned from your corrections is listed here too.
struct DetectionSettingsView: View {
    let mode: WorkRestSegmenter.Mode
    /// The workout to preview on first, when opened from one.
    let preview: SetTimeline?

    @State private var sport: String
    @State private var draft: StrengthTuning
    @State private var inUse: StrengthTuning
    @State private var hasOverride: Bool
    @State private var samples: [SetTimeline] = []
    @State private var sampleId: String?
    @State private var proposed: [TimelineSet] = []
    @State private var current: [TimelineSet] = []
    @State private var learned: [(context: String, fit: StrengthFit)] = []

    init(sport: String, mode: WorkRestSegmenter.Mode, preview: SetTimeline?) {
        self.mode = mode
        self.preview = preview
        let t = StrengthTuningStore.effective(sport: sport, exercise: nil, mode: mode)
        _sport = State(initialValue: sport)
        _draft = State(initialValue: t)
        _inUse = State(initialValue: t)
        _hasOverride = State(initialValue: StrengthTuningStore.override(sport: sport) != nil)
        _sampleId = State(initialValue: preview?.id)
    }

    private var sample: SetTimeline? { samples.first { $0.id == sampleId } ?? samples.first }
    private var sports: [String] {
        var seen = Set<String>()
        return ([sport] + samples.map(\.sport)).filter { seen.insert($0.lowercased()).inserted }
    }

    var body: some View {
        Form {
            previewSection
            Section {
                slider("Heart rate rises at least", value: $draft.riseBPM, in: 4...30, step: 1, unit: "bpm")
                Stepper("At least \(draft.minReps) reps from motion", value: $draft.minReps, in: 2...20)
            } header: { Text("Minimum evidence") } footer: {
                Text("How much a stretch must show before it counts. Below it, a stretch is left uncertain rather than counted.")
            }
            Section {
                seconds("Shortest set", value: $draft.minWorkS, in: 3...90, step: 1)
                seconds("Longest set", value: $draft.maxWorkS, in: 30...600, step: 10)
                seconds("Shortest rest", value: $draft.minRestS, in: 5...180, step: 5)
            } header: { Text("Set and rest length") }
            Section {
                seconds("Pause still inside a set", value: $draft.maxPauseS, in: 0...120, step: 5)
                slider("…when heart rate falls under", value: $draft.pauseFallBPM, in: 1...20, step: 1, unit: "bpm")
            } header: { Text("Allowable pauses") } footer: {
                Text("A stop this short, with heart rate staying up, is a pause in one set (re-gripping, a breath), not a rest. A clean HRV reading in the break can still say it was a rest.")
            }
            Section {
                slider("Rep gaps can stretch to", value: $draft.rhythmTolerance, in: 1.2...3.5, step: 0.1, unit: "×", digits: 1)
                slider("Motion at least", value: $draft.motionMinG, in: 0.01...0.4, step: 0.01, unit: "g", digits: 2)
            } header: { Text("Rep rhythm and motion strength") } footer: {
                Text("Reps that keep a steady rhythm count as stronger evidence. Smaller wrist swings than the motion floor are ignored.")
            }
            Section {
                seconds("Heart rate lags movement by", value: $draft.hrDelayS, in: 0...40, step: 1)
                seconds("Heart rate starts rising after", value: $draft.hrLeadS, in: 0...15, step: 1)
            } header: { Text("Heart-rate response delay") } footer: {
                Text("Heart rate keeps rising for a while after a set ends. Set edges found from heart rate alone are moved back by this much.")
            }
            Section {
                slider("Count a stretch at confidence", value: $draft.confidenceThreshold, in: 0.2...0.9, step: 0.05,
                       unit: "", digits: 2)
            } header: { Text("Confidence threshold") }

            Section {
                Button("Apply to \(sport) from the next workout") {
                    StrengthTuningStore.setOverride(draft, sport: sport)
                    inUse = draft
                    hasOverride = true
                }
                .disabled(draft == inUse)
                if draft != inUse {
                    Button("Discard changes") { draft = inUse }
                }
                if hasOverride {
                    Button("Go back to what detection learned") {
                        StrengthTuningStore.setOverride(nil, sport: sport)
                        reloadTuning()
                    }
                }
                Button("Start from the defaults") { draft = .defaults(mode) }
            } footer: {
                Text("Past workouts keep their sets. Settings you apply here take the place of learning for this sport until you go back.")
            }

            learnedSection
        }
        .navigationTitle("Detection settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            var all = WorkoutSetsStore.all().filter { !$0.hr.isEmpty }
            if let p = preview, !all.contains(where: { $0.id == p.id }) { all.insert(p, at: 0) }
            samples = Array(all.prefix(30))
            learned = StrengthTuningStore.learnedContexts()
            recompute()
        }
        .onChange(of: draft) { _, _ in recompute() }
        .onChange(of: sampleId) { _, _ in recompute() }
        .onChange(of: sport) { _, _ in reloadTuning() }
    }

    // MARK: Preview

    @ViewBuilder
    private var previewSection: some View {
        Section {
            if sports.count > 1 {
                Picker("Sport", selection: $sport) {
                    ForEach(sports, id: \.self) { Text($0).tag($0) }
                }
            }
            if let s = sample {
                Picker("Preview on", selection: Binding(get: { sampleId ?? s.id }, set: { sampleId = $0 })) {
                    ForEach(samples) { t in Text(label(t)).tag(t.id) }
                }
                SetTimelineChart(timeline: s, sets: proposed,
                                 window: Double(s.startTs)...Double(Swift.max(s.endTs, s.startTs + 60)))
                    .frame(height: 120)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                previewNumbers(s)
            } else {
                Text("No saved workout to preview on yet. After a tracked workout, changes here are shown on it before you apply them.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        } header: {
            Text("Preview")
        }
    }

    private func previewNumbers(_ s: SetTimeline) -> some View {
        let now = current.filter { !$0.uncertain }.count
        let then = proposed.filter { !$0.uncertain }.count
        let unit = LiveIntervalModes.unitName(mode, count: 2)
        return VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Now \(now) \(unit) · with these \(then) \(unit)"))
                .font(StrandFont.subhead.weight(.semibold))
                .monospacedDigit()
            if let truth = s.edited {
                let t = truth.filter { !$0.uncertain }.map(\.span)
                let a = SetCalibration.errors(current.filter { !$0.uncertain }.map(\.span), t).count
                let b = SetCalibration.errors(proposed.filter { !$0.uncertain }.map(\.span), t).count
                Text(String(localized: "Your corrected count is \(t.count). Off by \(a) now, \(b) with these."))
                    .font(StrandFont.caption)
                    .foregroundStyle(b < a ? StrandPalette.statusPositive : (b > a ? StrandPalette.statusWarning : StrandPalette.textSecondary))
            }
            let uncertain = proposed.filter(\.uncertain).count
            if uncertain > 0 {
                Text(String(localized: "\(uncertain) left uncertain, shown outlined"))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func recompute() {
        guard let s = sample else { proposed = []; current = []; return }
        let m = s.segmenterMode
        let bounds = s.startTs...Swift.max(s.endTs, s.startTs + 1)
        proposed = StrengthSetDetector.detect(hr: s.hr, beats: s.beats, motion: s.motion, mode: m, tuning: draft, bounds: bounds)
        current = StrengthSetDetector.detect(hr: s.hr, beats: s.beats, motion: s.motion, mode: m, tuning: inUse, bounds: bounds)
    }

    private func reloadTuning() {
        let t = StrengthTuningStore.effective(sport: sport, exercise: nil, mode: mode)
        inUse = t
        draft = t
        hasOverride = StrengthTuningStore.override(sport: sport) != nil
        recompute()
    }

    private func label(_ t: SetTimeline) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(t.startTs))
        return "\(t.sport) · " + d.formatted(.dateTime.month(.abbreviated).day().hour().minute())
            + (t.isCorrected ? " ✓" : "")
    }

    // MARK: Learned

    @ViewBuilder
    private var learnedSection: some View {
        Section {
            if learned.isEmpty {
                Text("Nothing yet. Each workout you correct teaches detection how your sets look, for the sport and, after two workouts, for each exercise.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            ForEach(learned.indices, id: \.self) { i in
                let item = learned[i]
                VStack(alignment: .leading, spacing: 4) {
                    Text(contextName(item.context))
                        .font(StrandFont.subhead.weight(.semibold))
                    Text(String(localized: "From \(item.fit.examples) corrected: \(item.fit.errorsBefore) misses and extras with the defaults, \(item.fit.errorsAfter) now. Exact on \(item.fit.exactAfter) of \(item.fit.examples)."))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Forget", role: .destructive) {
                        StrengthTuningStore.forget(item.context)
                        learned = StrengthTuningStore.learnedContexts()
                        if item.context == StrengthTuningStore.sportKey(sport) { reloadTuning() }
                    }
                    .font(StrandFont.caption)
                }
            }
        } header: {
            Text("Learned from your corrections")
        }
    }

    private func contextName(_ c: String) -> String {
        if c.hasPrefix("sport:") { return String(c.dropFirst(6)).capitalized }
        if c.hasPrefix("exercise:") { return String(c.dropFirst(9)).capitalized + " " + String(localized: "(exercise)") }
        return c
    }

    // MARK: Rows

    private func slider(_ title: LocalizedStringKey, value: Binding<Double>, in range: ClosedRange<Double>,
                        step: Double, unit: String, digits: Int = 0) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue.formatted(.number.precision(.fractionLength(digits))) + (unit.isEmpty ? "" : " \(unit)"))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private func seconds(_ title: LocalizedStringKey, value: Binding<Int>, in range: ClosedRange<Int>, step: Int) -> some View {
        let d = Binding<Double>(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) })
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(LiveIntervalTracker.clock(value.wrappedValue))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .monospacedDigit()
            }
            Slider(value: d, in: Double(range.lowerBound)...Double(range.upperBound), step: Double(step))
        }
    }
}

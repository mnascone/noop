import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// On a workout's detail screen: the sets it counted, drawn over the session's heart rate, and the way
/// into correcting them. Shown for workouts whose sport counts sets or intervals.
struct WorkoutSetsCard: View {
    let row: WorkoutRow
    @EnvironmentObject private var repo: Repository
    @State private var record: WorkoutSetsRecord?
    @State private var loaded = false
    @State private var editing = false

    var body: some View {
        Group {
            if let r = record {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    SectionHeader(LocalizedStringKey(LiveIntervalModes.unitName(r.segmenterMode, count: 2).capitalized),
                                  overline: overline(r), trailing: "\(r.sets.count)")
                    NoopCard(tint: StrandPalette.effortColor) {
                        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                            SetsChart(record: r, sets: r.sets, selected: nil)
                                .frame(height: 110)
                            Text(WorkoutSetsStore.notesLine(r).components(separatedBy: "\n").first ?? "")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                editing = true
                            } label: {
                                Label(r.edited == nil ? "Review and correct" : "Edit sets", systemImage: "slider.horizontal.3")
                                    .font(StrandFont.subhead.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(StrandPalette.accent)
                        }
                    }
                }
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            if let saved = WorkoutSetsStore.load(startTs: row.startTs, sport: row.sport) {
                record = saved
            } else {
                record = await WorkoutSetsStore.build(row: row, repo: repo)
            }
        }
        .sheet(isPresented: $editing) {
            if let r = record {
                NavigationStack {
                    WorkoutSetsEditor(record: r, row: row) { updated in record = updated }
                }
            }
        }
    }

    private func overline(_ r: WorkoutSetsRecord) -> LocalizedStringKey {
        if r.edited != nil { return "Corrected by you" }
        return r.detectedFrom == "motion" ? "From wrist motion and heart rate" : "Estimated from heart rate"
    }
}

/// Correct a workout's sets: delete one that wasn't a set, join two that were one, add one it missed,
/// and nudge where each starts and ends. Saving teaches set detection how your sets look.
struct WorkoutSetsEditor: View {
    let row: WorkoutRow
    let onSave: (WorkoutSetsRecord) -> Void
    @State private var record: WorkoutSetsRecord
    @State private var sets: [WorkoutSetsRecord.SetSpan]
    @State private var selected: Int?
    /// A tapped spot on the chart outside any set: offered as a new set.
    @State private var addAt: Int?
    @State private var saving = false
    @State private var fitNote: String?
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss

    init(record: WorkoutSetsRecord, row: WorkoutRow, onSave: @escaping (WorkoutSetsRecord) -> Void) {
        self.row = row
        self.onSave = onSave
        _record = State(initialValue: record)
        _sets = State(initialValue: record.sets.sorted { $0.start < $1.start })
    }

    private var mode: WorkRestSegmenter.Mode { record.segmenterMode }
    private var unit: String { LiveIntervalModes.unitName(mode, count: 1) }

    var body: some View {
        List {
            Section {
                SetsChart(record: record, sets: sets, selected: selected, marker: addAt) { ts in tapped(ts) }
                    .frame(height: 150)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                if let t = addAt {
                    Button {
                        add(at: t)
                    } label: {
                        Label(String(localized: "Add a \(unit) at \(offset(t))"), systemImage: "plus.circle.fill")
                    }
                }
            } footer: {
                Text("Tap a shaded \(unit) to select it, or a gap to add one there.")
            }

            Section {
                ForEach(Array(sets.enumerated()), id: \.element.id) { i, s in
                    setRow(i, s)
                        .contentShape(Rectangle())
                        .onTapGesture { selected = selected == i ? nil : i; addAt = nil }
                        .listRowBackground(selected == i ? StrandPalette.accent.opacity(0.12) : nil)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { delete(i) } label: { Label("Delete", systemImage: "trash") }
                            if i + 1 < sets.count {
                                Button { merge(i) } label: { Label("Join next", systemImage: "arrow.down.to.line") }
                                    .tint(StrandPalette.accent)
                            }
                        }
                }
            } header: {
                Text("\(sets.count) \(LiveIntervalModes.unitName(mode, count: sets.count))")
            } footer: {
                Text("Swipe left to delete one that wasn't real, or join it with the next when two were one.")
            }

            if let i = selected, i < sets.count {
                Section(String(localized: "Selected \(unit)")) {
                    edgeStepper(String(localized: "Starts"), value: sets[i].start, lo: i > 0 ? sets[i - 1].end + 1 : record.startTs,
                                hi: sets[i].end - 5) { sets[i].start = $0 }
                    edgeStepper(String(localized: "Ends"), value: sets[i].end, lo: sets[i].start + 5,
                                hi: i + 1 < sets.count ? sets[i + 1].start - 1 : record.endTs) { sets[i].end = $0 }
                    if mode == .lifting {
                        Stepper(value: Binding(get: { sets[i].reps ?? 0 }, set: { sets[i].reps = $0 > 0 ? $0 : nil }),
                                in: 0...100) {
                            Text(sets[i].reps.map { String(localized: "Reps: \($0)") } ?? String(localized: "Reps: not set"))
                        }
                    }
                }
            }

            Section {
                if record.edited != nil || sets != record.detected.sorted(by: { $0.start < $1.start }) {
                    Button("Back to what was counted") {
                        sets = record.detected.sorted { $0.start < $1.start }
                        selected = nil
                    }
                }
            } footer: {
                Text(learningNote)
            }
        }
        .navigationTitle(String(localized: "Correct \(LiveIntervalModes.unitName(mode, count: 2))"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? String(localized: "Saving…") : String(localized: "Save")) { Task { await save() } }
                    .disabled(saving)
            }
        }
    }

    // MARK: Rows

    private func setRow(_ i: Int, _ s: WorkoutSetsRecord.SetSpan) -> some View {
        let rest = i > 0 ? s.start - sets[i - 1].end : nil
        let peak = record.hr.filter { $0.ts >= s.start && $0.ts <= s.end + 20 }.map(\.bpm).max()
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(unit.capitalized) \(i + 1)")
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(detailLine(s, rest: rest, peak: peak))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer()
            if let reps = s.reps {
                Text(String(localized: "\(reps) reps"))
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    private func detailLine(_ s: WorkoutSetsRecord.SetSpan, rest: Int?, peak: Int?) -> String {
        var parts = ["\(offset(s.start))–\(offset(s.end))", LiveIntervalTracker.clock(s.end - s.start)]
        if let rest { parts.append(String(localized: "rest \(LiveIntervalTracker.clock(rest)) before")) }
        if let peak { parts.append(String(localized: "peak \(peak) bpm")) }
        return parts.joined(separator: " · ")
    }

    private func edgeStepper(_ label: String, value: Int, lo: Int, hi: Int, set: @escaping (Int) -> Void) -> some View {
        Stepper {
            HStack {
                Text(label)
                Spacer()
                Text(offset(value)).monospacedDigit().foregroundStyle(StrandPalette.textSecondary)
            }
        } onIncrement: {
            set(min(hi, value + 5))
        } onDecrement: {
            set(max(lo, value - 5))
        }
    }

    /// "12:34" into the workout.
    private func offset(_ ts: Int) -> String { LiveIntervalTracker.clock(ts - record.startTs) }

    // MARK: Edits

    private func tapped(_ ts: Int) {
        if let i = sets.firstIndex(where: { ts >= $0.start && ts <= $0.end }) {
            selected = selected == i ? nil : i
            addAt = nil
        } else {
            selected = nil
            addAt = ts
        }
    }

    private func add(at ts: Int) {
        // About 40 s, centred on the tap, kept clear of the sets either side.
        let before = sets.last { $0.end < ts }?.end ?? record.startTs
        let after = sets.first { $0.start > ts }?.start ?? record.endTs
        let start = max(before + 1, ts - 20)
        let end = min(after - 1, start + 40)
        guard end - start >= 5 else { return }
        sets.append(.init(start: start, end: end, reps: nil))
        sets.sort { $0.start < $1.start }
        selected = sets.firstIndex { $0.start == start }
        addAt = nil
    }

    private func delete(_ i: Int) {
        sets.remove(at: i)
        selected = nil
    }

    private func merge(_ i: Int) {
        guard i + 1 < sets.count else { return }
        let a = sets[i], b = sets[i + 1]
        let reps: Int? = (a.reps ?? 0) + (b.reps ?? 0) > 0 ? (a.reps ?? 0) + (b.reps ?? 0) : nil
        sets[i] = .init(start: a.start, end: b.end, reps: reps)
        sets.remove(at: i + 1)
        selected = i
    }

    // MARK: Save

    private var learningNote: String {
        if let fitNote { return fitNote }
        guard let f = SetTuningStore.fit(for: mode) else {
            return String(localized: "Saving teaches NOOP how your sets look in heart rate and HRV: how far heart rate rises and falls, how long a set and a rest last, and how much HRV drops. Each correction refines all of them.")
        }
        return Self.fitSummary(f, unit: LiveIntervalModes.unitName(mode, count: 2))
    }

    static func fitSummary(_ f: SetCalibration.Fit, unit: String) -> String {
        let t = f.tuning
        var s = String(localized: "Learned from \(f.examples) corrected workouts: counts match yours on \(f.exactAfter) of \(f.examples) (\(f.exactBefore) before learning).")
        s += " " + String(localized: "Now: heart rate up \(Int(t.riseBPM)) and down \(Int(t.fallBPM)) bpm, at least \(t.minWorkS) s of work, rests under \(t.minRestS) s join \(unit)")
        s += t.hrvDrop > 0 ? ", " + String(localized: "HRV at least \(Int((t.hrvDrop * 100).rounded()))% lower during one.") : "."
        return s
    }

    private func save() async {
        saving = true
        var r = record
        r.edited = sets.sorted { $0.start < $1.start }
        WorkoutSetsStore.save(r)
        record = r
        onSave(r)
        // The workout's notes follow your sets. Only rows NOOP saved itself are rewritten.
        if WorkoutSource.classify(row.source) == .manual {
            let kept = (row.notes ?? "").components(separatedBy: "\n").filter { $0.hasPrefix("HR recovery") }
            let notes = ([WorkoutSetsStore.notesLine(r)] + kept).joined(separator: "\n")
            await repo.saveManualWorkout(WorkoutRow(
                startTs: row.startTs, endTs: row.endTs, sport: row.sport, source: row.source,
                durationS: row.durationS, energyKcal: row.energyKcal, avgHr: row.avgHr, maxHr: row.maxHr,
                strain: row.strain, distanceM: row.distanceM, zonesJSON: row.zonesJSON, notes: notes,
                steps: row.steps))
            await repo.refresh()
        }
        if let f = await SetTuningStore.refit(mode) {
            fitNote = Self.fitSummary(f, unit: LiveIntervalModes.unitName(mode, count: 2))
        }
        saving = false
        dismiss()
    }
}

/// The session's heart rate with its sets shaded. Tapping reports the time tapped.
struct SetsChart: View {
    let record: WorkoutSetsRecord
    let sets: [WorkoutSetsRecord.SetSpan]
    let selected: Int?
    var marker: Int? = nil
    var onTap: ((Int) -> Void)? = nil

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let t0 = Double(record.startTs), t1 = Double(max(record.endTs, record.startTs + 1))
            let bpms = record.hr.map(\.bpm)
            let lo = Double((bpms.min() ?? 60) - 5), hi = Double((bpms.max() ?? 180) + 5)
            Canvas { ctx, size in
                func x(_ ts: Int) -> CGFloat { CGFloat((Double(ts) - t0) / (t1 - t0)) * size.width }
                func y(_ bpm: Int) -> CGFloat { size.height - CGFloat((Double(bpm) - lo) / max(hi - lo, 1)) * size.height }
                for (i, s) in sets.enumerated() {
                    let r = CGRect(x: x(s.start), y: 0, width: max(2, x(s.end) - x(s.start)), height: size.height)
                    ctx.fill(Path(roundedRect: r, cornerRadius: 3),
                             with: .color(StrandPalette.accent.opacity(i == selected ? 0.45 : 0.18)))
                }
                var line = Path()
                var started = false
                var lastTs = 0
                for s in record.hr {
                    let p = CGPoint(x: x(s.ts), y: y(s.bpm))
                    if !started || s.ts - lastTs > 30 { line.move(to: p); started = true } else { line.addLine(to: p) }
                    lastTs = s.ts
                }
                ctx.stroke(line, with: .color(StrandPalette.metricRose), lineWidth: 1.5)
                if let m = marker {
                    var p = Path()
                    p.move(to: CGPoint(x: x(m), y: 0))
                    p.addLine(to: CGPoint(x: x(m), y: size.height))
                    ctx.stroke(p, with: .color(StrandPalette.textPrimary.opacity(0.6)),
                               style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { loc in
                guard let onTap, w > 0 else { return }
                onTap(Int(t0 + Double(loc.x / w) * (t1 - t0)))
            }
            .overlay(alignment: .topLeading) {
                Text("\(Int(hi)) bpm").font(.system(size: 9)).foregroundStyle(StrandPalette.textTertiary)
            }
            .frame(width: w, height: h)
        }
        .accessibilityLabel(Text(String(localized: "\(sets.count) shaded over the workout's heart rate")))
    }
}

import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

extension SetTimeline {
    var segmenterMode: WorkRestSegmenter.Mode { WorkRestSegmenter.Mode(rawValue: mode) ?? .lifting }
}

/// On a workout's detail screen: its sets over the session's heart rate, what they add up to (with push /
/// pull / legs), and the way into the editor. Shown for workouts whose sport counts sets or intervals,
/// and for any workout you've entered sets for.
struct WorkoutSetsCard: View {
    let row: WorkoutRow
    /// Raised by the detail screen's Edit sets button too.
    @Binding var editing: Bool
    @EnvironmentObject private var repo: Repository
    @ObservedObject private var categories = ExerciseCategoryStore.shared
    @ObservedObject private var workoutCategories = WorkoutCategoryStore.shared
    @State private var timeline: SetTimeline?
    @State private var lift = WorkoutSetsStore.LiftContext()
    @State private var loadedSeq: Int?
    @State private var notesTask: Task<Void, Never>?

    private var countsSets: Bool { LiveIntervalModes.mode(forSport: row.sport) != nil }

    var body: some View {
        // Always in the hierarchy (a zero-height stand-in when hidden) so the editor sheet can still open
        // from the toolbar for a workout that doesn't show the card.
        VStack(spacing: 0) {
            if let t = timeline, countsSets || t.isCorrected {
                content(t)
            } else {
                Color.clear.frame(height: 0)
            }
        }
        // Reload when data lands: a workout saved before the strap synced gets its heart rate later.
        .task(id: repo.refreshSeq) { await load() }
        .sheet(isPresented: $editing, onDismiss: finishedEditing) {
            NavigationStack {
                if let t = timeline {
                    SetTimelineEditorView(title: String(localized: "Edit sets"), timeline: t,
                                          exercises: lift.names) { updated in changed(updated) }
                } else {
                    ProgressView().task { await load() }
                }
            }
        }
    }

    private func content(_ t: SetTimeline) -> some View {
        let mode = t.segmenterMode
        let sum = SetSummary(t, workout: workoutCategories.fallback(startTs: t.startTs)) { categories.category(for: $0) }
        let uncertain = t.sets.count - t.counted.count
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader(LocalizedStringKey(LiveIntervalModes.unitName(mode, count: 2).capitalized),
                          overline: overline(t), trailing: "\(sum.count)")
            NoopCard(tint: StrandPalette.effortColor) {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    if t.hr.isEmpty && t.sets.isEmpty {
                        Text("No heart rate is stored for this workout yet, so nothing was counted. It fills in after the strap syncs, or you can enter your sets now.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        SetTimelineChart(timeline: t, sets: t.sets,
                                         window: Double(t.startTs)...Double(Swift.max(t.endTs, t.startTs + 60)),
                                         compact: true)
                            .frame(height: 90)
                            .allowsHitTesting(false)
                    }
                    if !t.sets.isEmpty {
                        Text(WorkoutSetsStore.notes(t).components(separatedBy: "\n").first ?? "")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !sum.byCategory.isEmpty {
                        CategoryCounts(counts: sum.byCategory)
                    }
                    if uncertain > 0 {
                        Text(String(localized: "\(uncertain) uncertain, not counted"))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Button { editing = true } label: {
                        Label(t.sets.isEmpty ? "Enter sets" : "Edit sets", systemImage: "waveform.path.ecg")
                            .font(StrandFont.subhead.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.accent)
                }
            }
        }
    }

    private func load() async {
        guard loadedSeq != repo.refreshSeq || timeline == nil else { return }
        loadedSeq = repo.refreshSeq
        lift = await WorkoutSetsStore.liftContext(row: row, repo: repo)
        if var saved = WorkoutSetsStore.load(startTs: row.startTs, sport: row.sport),
           !(saved.hr.isEmpty && saved.edited == nil) {
            // Label detected sets with what the Lift Log logged, without touching your corrections.
            let labelled = WorkoutSetsStore.label(saved.detected, with: lift)
            if labelled != saved.detected { saved.detected = labelled; WorkoutSetsStore.save(saved) }
            timeline = saved
            return
        }
        var built = await WorkoutSetsStore.build(row: row, repo: repo)
        built.detected = WorkoutSetsStore.label(built.detected, with: lift)
        // Keep your entered sets if heart rate arrives after them.
        if let saved = WorkoutSetsStore.load(startTs: row.startTs, sport: row.sport), saved.edited != nil {
            built.edited = saved.edited
            built.history = saved.history
            WorkoutSetsStore.save(built)
        } else if !built.hr.isEmpty {
            WorkoutSetsStore.save(built)
        }
        timeline = built
    }

    /// Every edit: saved at once, the workout's notes rewritten shortly after the last one.
    private func changed(_ t: SetTimeline) {
        timeline = t
        WorkoutSetsStore.save(t)
        notesTask?.cancel()
        notesTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await WorkoutSetsStore.syncNotes(t, row: row, repo: repo)
        }
    }

    /// Leaving the editor: notes now. (Detection has already learned from the edits, in the editor.)
    private func finishedEditing() {
        guard let t = timeline else { return }
        notesTask?.cancel()
        Task { await WorkoutSetsStore.syncNotes(t, row: row, repo: repo) }
    }

    private func overline(_ t: SetTimeline) -> LocalizedStringKey {
        if t.isCorrected { return "Corrected by you" }
        if t.hr.isEmpty { return "Not counted yet" }
        return t.detectedFrom.contains("motion") ? "From wrist motion and heart rate" : "Estimated from heart rate"
    }
}

// MARK: - The chart

/// Heart rate over a stretch of a workout, sets as lightly shaded spans and rests as the gaps between.
/// Uncertain segments are outlined, not filled. Reps and motion runs are drawn only when asked.
struct SetTimelineChart: View {
    let timeline: SetTimeline
    let sets: [TimelineSet]
    /// The stretch shown, unix seconds.
    let window: ClosedRange<Double>
    var selected: String? = nil
    var selectedGap: String? = nil
    var drawing: ClosedRange<Int>? = nil
    /// Rests heart rate says were probably pauses (by the set before), and sets it barely rose for: a
    /// small dot each, never a prompt.
    var likelyPauses: Set<String> = []
    var doubtful: Set<String> = []
    var showMarks = false
    var compact = false

    var body: some View {
        Canvas { ctx, size in
            draw(in: &ctx, size: size)
        }
    }

    private func x(_ ts: Double, _ w: CGFloat) -> CGFloat {
        CGFloat((ts - window.lowerBound) / Swift.max(1, window.upperBound - window.lowerBound)) * w
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize) {
        let w = size.width
        let axisH: CGFloat = compact ? 0 : 16
        let marksH: CGFloat = showMarks ? 14 : 0
        let plotH = size.height - axisH - marksH
        let counted = sets.filter { !$0.uncertain }
        // Sets.
        for s in sets {
            let x0 = x(Double(s.start), w), x1 = x(Double(s.end), w)
            guard x1 >= 0, x0 <= w else { continue }
            let r = CGRect(x: x0, y: 0, width: Swift.max(1, x1 - x0), height: plotH)
            let isSel = s.id == selected
            if s.uncertain {
                ctx.fill(Path(r), with: .color(StrandPalette.accent.opacity(isSel ? 0.16 : 0.05)))
                ctx.stroke(Path(r.insetBy(dx: 0.5, dy: 0.5)), with: .color(StrandPalette.accent.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            } else {
                ctx.fill(Path(r), with: .color(StrandPalette.accent.opacity(isSel ? 0.32 : 0.15)))
            }
            if isSel {
                ctx.stroke(Path(r.insetBy(dx: 0.75, dy: 0.75)), with: .color(StrandPalette.accent), lineWidth: 1.5)
            }
            if !compact, let n = counted.firstIndex(where: { $0.id == s.id }), x1 - x0 >= 12 {
                ctx.draw(Text("\(n + 1)").font(.system(size: 10, weight: .bold)).foregroundColor(StrandPalette.textSecondary),
                         at: CGPoint(x: (x0 + x1) / 2, y: 9))
            }
        }
        // The rest chosen to join.
        if let g = selectedGap, let i = sets.firstIndex(where: { $0.id == g }), i + 1 < sets.count {
            let x0 = x(Double(sets[i].end), w), x1 = x(Double(sets[i + 1].start), w)
            let r = CGRect(x: x0, y: 0, width: Swift.max(2, x1 - x0), height: plotH)
            ctx.fill(Path(r), with: .color(StrandPalette.statusWarning.opacity(0.18)))
            ctx.stroke(Path(r.insetBy(dx: 0.5, dy: 0.5)), with: .color(StrandPalette.statusWarning),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        }
        // Quiet hints from heart rate.
        if !compact {
            for (i, a) in sets.enumerated() where i + 1 < sets.count && likelyPauses.contains(a.id) {
                let cx = (x(Double(a.end), w) + x(Double(sets[i + 1].start), w)) / 2
                guard cx >= 0, cx <= w else { continue }
                ctx.fill(Path(ellipseIn: CGRect(x: cx - 3, y: 6, width: 6, height: 6)),
                         with: .color(StrandPalette.statusWarning))
            }
            for s in sets where doubtful.contains(s.id) {
                let cx = x(Double(s.end), w) - 5
                guard cx >= 0, cx <= w else { continue }
                ctx.fill(Path(ellipseIn: CGRect(x: cx - 2.5, y: 4, width: 5, height: 5)),
                         with: .color(StrandPalette.statusWarning.opacity(0.8)))
            }
        }
        // A set being drawn.
        if let d = drawing {
            let x0 = x(Double(d.lowerBound), w), x1 = x(Double(d.upperBound), w)
            let r = CGRect(x: x0, y: 0, width: Swift.max(2, x1 - x0), height: plotH)
            ctx.fill(Path(r), with: .color(StrandPalette.accent.opacity(0.28)))
            ctx.stroke(Path(r), with: .color(StrandPalette.accent), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
        }
        // Heart rate, with its scale.
        if !compact { drawHeartRateScale(in: &ctx, w: w, h: plotH) }
        drawHeartRate(in: &ctx, w: w, h: plotH)
        // Reps and motion, on request.
        if showMarks {
            let y = plotH + 2
            for m in timeline.motion {
                let x0 = x(Double(m.start), w), x1 = x(Double(m.end), w)
                guard x1 >= 0, x0 <= w else { continue }
                ctx.fill(Path(roundedRect: CGRect(x: x0, y: y + 7, width: Swift.max(2, x1 - x0), height: 4), cornerRadius: 2),
                         with: .color(StrandPalette.metricAmber.opacity(0.6)))
                for t in m.repTimes {
                    let rx = x(t, w)
                    guard rx >= 0, rx <= w else { continue }
                    var p = Path()
                    p.move(to: CGPoint(x: rx, y: y))
                    p.addLine(to: CGPoint(x: rx, y: y + 6))
                    ctx.stroke(p, with: .color(StrandPalette.metricAmber), lineWidth: 1)
                }
            }
        }
        // Time since the start.
        if !compact { drawAxis(in: &ctx, w: w, y: size.height - axisH) }
    }

    /// The bpm range drawn: the whole workout's (so it doesn't jump as you pan), low end clear of spikes.
    private var bpmRange: (lo: Double, hi: Double)? {
        let all = timeline.hr.map(\.bpm).sorted()
        guard all.count >= 2 else { return nil }
        return (Double(all[all.count / 50]) - 4, Double(all.last!) + 4)
    }

    private func y(_ bpm: Double, h: CGFloat, range r: (lo: Double, hi: Double)) -> CGFloat {
        h - CGFloat((bpm - r.lo) / Swift.max(1, r.hi - r.lo)) * (h - 18) - 4
    }

    /// Faint lines at round heart rates, labelled at the left: 10 bpm apart, or 20 over a wide range.
    private func drawHeartRateScale(in ctx: inout GraphicsContext, w: CGFloat, h: CGFloat) {
        guard let r = bpmRange else { return }
        let step = r.hi - r.lo > 70 ? 20.0 : 10.0
        var b = (r.lo / step).rounded(.up) * step
        while b <= r.hi {
            let py = y(b, h: h, range: r)
            if py > 14, py < h - 4 {
                var line = Path()
                line.move(to: CGPoint(x: 28, y: py))
                line.addLine(to: CGPoint(x: w, y: py))
                ctx.stroke(line, with: .color(StrandPalette.hairline), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                ctx.draw(Text("\(Int(b))").font(.system(size: 9, weight: .medium)).foregroundColor(StrandPalette.textTertiary),
                         at: CGPoint(x: 3, y: py), anchor: .leading)
            }
            b += step
        }
        ctx.draw(Text("bpm").font(.system(size: 8)).foregroundColor(StrandPalette.textTertiary),
                 at: CGPoint(x: 3, y: 8), anchor: .leading)
    }

    private func drawHeartRate(in ctx: inout GraphicsContext, w: CGFloat, h: CGFloat) {
        let hr = timeline.hr
        guard hr.count >= 2, let r = bpmRange else { return }
        func y(_ bpm: Int) -> CGFloat { self.y(Double(bpm), h: h, range: r) }
        // Only the samples in view, thinned to about two per point.
        let lower = Int(window.lowerBound) - 5, upper = Int(window.upperBound) + 5
        var first = 0, last = hr.count
        var a = 0, b = hr.count
        while a < b { let m = (a + b) / 2; if hr[m].ts < lower { a = m + 1 } else { b = m } }
        first = a
        a = first; b = hr.count
        while a < b { let m = (a + b) / 2; if hr[m].ts <= upper { a = m + 1 } else { b = m } }
        last = a
        guard last - first >= 2 else { return }
        let step = Swift.max(1, (last - first) / Swift.max(1, Int(w * 2)))
        var path = Path()
        var started = false
        var prevTs = Int.min
        for i in stride(from: first, to: last, by: step) {
            let p = CGPoint(x: x(Double(hr[i].ts), w), y: y(hr[i].bpm))
            // A gap in the data is a gap in the line.
            if !started || hr[i].ts - prevTs > 30 * step { path.move(to: p); started = true } else { path.addLine(to: p) }
            prevTs = hr[i].ts
        }
        ctx.stroke(path, with: .color(StrandPalette.metricRose), style: StrokeStyle(lineWidth: compact ? 1.2 : 1.6, lineJoin: .round))
    }

    private func drawAxis(in ctx: inout GraphicsContext, w: CGFloat, y: CGFloat) {
        let span = window.upperBound - window.lowerBound
        let steps: [Double] = [10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        let step = steps.first { Double(w) / (span / $0) >= 56 } ?? 3600
        let t0 = Double(timeline.startTs)
        var t = (floor((window.lowerBound - t0) / step) + 1) * step
        while t0 + t < window.upperBound {
            let px = x(t0 + t, w)
            ctx.draw(Text(LiveIntervalTracker.clock(Int(t))).font(.system(size: 9)).foregroundColor(StrandPalette.textTertiary),
                     at: CGPoint(x: px, y: y + 8))
            t += step
        }
    }
}

// MARK: - The editor

/// The sets editor, the same during the workout and afterwards: one zoomable heart-rate timeline with
/// sets shaded and rests as gaps. Hold a rest to remove it (the sets either side join); hold a set and
/// drag to move its nearer edge; hold empty time and drag to add a set; tap to select and use the
/// actions (delete, split, join, exercise). Every edit is saved as you make it (`onChange`), with undo
/// and redo here, and detection refits from it a moment later.
struct SetTimelineEditorView: View {
    let title: String
    let exercises: [String]
    let onChange: (SetTimeline) -> Void

    @State private var timeline: SetTimeline
    @State private var editor: SetTimelineEditor
    private let baseHistory: [SetEditRecord]
    @State private var selection: Selection?
    @State private var window: ClosedRange<Double>
    @State private var pinchStart: (window: ClosedRange<Double>, x: CGFloat)?
    /// The finger on the timeline: a tap, a pan, or (after a hold) drawing a set, moving an edge, or a
    /// join already made.
    @State private var touch: Touch?
    @State private var touchToken = 0
    @State private var holdFired = 0
    /// The options shown where you held: for a rest, a set or empty time.
    @State private var bubble: Bubble?
    /// What detection learned from the latest edits, shown under the summary.
    @State private var learnedNote: String?
    @State private var learnTask: Task<Void, Never>?
    @State private var dragging: TimelineSet?
    @State private var drawing: ClosedRange<Int>?
    @AppStorage("noop.setsEditor.marks") private var showMarks = false
    @State private var showDetection = false
    @State private var naming = false
    @State private var newName = ""
    @ObservedObject private var categories = ExerciseCategoryStore.shared
    @ObservedObject private var workoutCategories = WorkoutCategoryStore.shared
    @Environment(\.dismiss) private var dismiss

    struct Touch {
        enum Mode: Equatable {
            case pending, pan, draw, held
            /// Holding a set: its options on release, or its nearer edge once you drag.
            case onSet(id: String, isStart: Bool)
            case edge(id: String, isStart: Bool)
        }
        var startX: CGFloat
        var startWindow: ClosedRange<Double>
        var mode: Mode = .pending
    }

    enum Bubble: Equatable {
        case gap(after: String)
        case set(String)
        case empty(Int)
    }

    enum Selection: Equatable {
        case set(String)
        case gap(after: String)
        /// Empty time, where a set could be added.
        case empty(at: Int)
    }

    init(title: String, timeline: SetTimeline, exercises: [String], onChange: @escaping (SetTimeline) -> Void) {
        self.title = title
        self.exercises = exercises
        self.onChange = onChange
        let end = Swift.max(timeline.endTs, (timeline.hr.last?.ts ?? 0), timeline.startTs + 60)
        _timeline = State(initialValue: timeline)
        _editor = State(initialValue: SetTimelineEditor(sets: timeline.sets, bounds: timeline.startTs...end))
        _window = State(initialValue: Double(timeline.startTs)...Double(end))
        baseHistory = timeline.history
    }

    private var full: ClosedRange<Double> { Double(editor.bounds.lowerBound)...Double(editor.bounds.upperBound) }
    private var mode: WorkRestSegmenter.Mode { timeline.segmenterMode }
    private var unit: String { LiveIntervalModes.unitName(mode, count: 1) }
    private var tuning: StrengthTuning {
        StrengthTuningStore.effective(sport: timeline.sport, exercise: nil, mode: mode)
    }

    /// The sets as drawn: with the one being dragged in its new place.
    private var shown: [TimelineSet] {
        guard let d = dragging else { return editor.sets }
        return editor.sets.map { $0.id == d.id ? d : $0 }
    }

    private var selectedSetId: String? { if case .set(let id) = selection { return id }; return nil }
    private var selectedGapId: String? { if case .gap(let id) = selection { return id }; return nil }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            summaryLine
            timelineSurface
                .frame(height: 230)
            overview
                .frame(height: 26)
            actions
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.top, NoopMetrics.space2)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button { editor.undo(now: now); afterEdit() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!editor.canUndo)
                    .accessibilityLabel("Undo")
                Button { editor.redo(now: now); afterEdit() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!editor.canRedo)
                    .accessibilityLabel("Redo")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Toggle(isOn: $showMarks) { Label("Show reps and motion", systemImage: "waveform") }
                    Button { zoom(to: full) } label: { Label("Show whole workout", systemImage: "arrow.left.and.right") }
                    Button(role: .destructive) {
                        editor.reset(to: timeline.detected, now: now)
                        selection = nil
                        afterEdit()
                    } label: { Label("Back to detected", systemImage: "arrow.counterclockwise") }
                    .disabled(editor.sets == timeline.detected.sorted { $0.start < $1.start })
                    Divider()
                    Button { showDetection = true } label: { Label("Detection settings", systemImage: "slider.horizontal.3") }
                } label: { Image(systemName: "ellipsis.circle") }
                Button("Done") { dismiss() }.fontWeight(.semibold)
            }
        }
        .sheet(isPresented: $showDetection) {
            NavigationStack {
                DetectionSettingsView(sport: timeline.sport, mode: mode, preview: timeline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { showDetection = false } }
                    }
            }
        }
        .alert("Exercise", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Set") { if let id = selectedSetId { setExercise(newName, for: id) } }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: holdFired)
    }

    private var now: Int { Int(Date().timeIntervalSince1970) }

    // MARK: Summary

    private var summaryLine: some View {
        var t = timeline
        t.edited = editor.sets
        let sum = SetSummary(t, workout: workoutCategories.fallback(startTs: t.startTs)) { categories.category(for: $0) }
        let uncertain = editor.sets.count - editor.counted.count
        var parts = ["\(sum.count) \(LiveIntervalModes.unitName(mode, count: sum.count))",
                     String(localized: "\(LiveIntervalTracker.clock(sum.workS)) working")]
        if let a = sum.avgRestS { parts.append(String(localized: "avg rest \(LiveIntervalTracker.clock(a))")) }
        if let d = sum.avgDrop60 { parts.append(String(localized: "recovery -\(d) bpm/60 s")) }
        return VStack(alignment: .leading, spacing: 4) {
            if mode == .lifting {
                HStack(spacing: 8) {
                    Text("Workout")
                        .font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                    WorkoutCategoryPicker(selection: Binding(
                        get: { workoutCategories.categories(startTs: timeline.startTs) },
                        set: { workoutCategories.set($0, startTs: timeline.startTs); onChange(timeline) }))
                }
            }
            Text(parts.joined(separator: " · "))
                .font(StrandFont.footnote.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
            HStack(spacing: 8) {
                if !sum.byCategory.isEmpty { CategoryCounts(counts: sum.byCategory) }
                if uncertain > 0 {
                    Text(String(localized: "\(uncertain) uncertain"))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            if let note = learnedNote {
                Label(note, systemImage: "brain")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
    }

    // MARK: Timeline

    private var timelineSurface: some View {
        GeometryReader { g in
            let w = g.size.width
            let hint = hints
            ZStack(alignment: .topLeading) {
                SetTimelineChart(timeline: timeline, sets: shown, window: window, selected: selectedSetId,
                                 selectedGap: selectedGapId, drawing: drawing,
                                 likelyPauses: hint.pauses, doubtful: hint.doubtful, showMarks: showMarks)
                    .background(RoundedRectangle(cornerRadius: 10).fill(StrandPalette.surfaceInset.opacity(0.5)))
                    .contentShape(Rectangle())
                    .gesture(touchGesture(w))
                    .simultaneousGesture(pinchGesture(w))
                if let id = selectedSetId, let s = shown.first(where: { $0.id == id }) {
                    handle(for: s, isStart: true, w: w, h: g.size.height)
                    handle(for: s, isStart: false, w: w, h: g.size.height)
                }
                if let b = bubble {
                    bubbleView(b, w: w)
                        .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Heart-rate timeline"))
    }

    private func ts(_ x: CGFloat, _ w: CGFloat) -> Int {
        Int((window.lowerBound + Double(x / Swift.max(1, w)) * (window.upperBound - window.lowerBound)).rounded())
    }

    private func px(_ ts: Int, _ w: CGFloat) -> CGFloat {
        CGFloat((Double(ts) - window.lowerBound) / Swift.max(1, window.upperBound - window.lowerBound)) * w
    }

    /// Seconds one point of the timeline covers.
    private func secondsPerPoint(_ w: CGFloat) -> Double { (window.upperBound - window.lowerBound) / Double(Swift.max(1, w)) }

    /// One finger, read by hand so a tap, a pan and a hold never fight: move first and it pans; lift
    /// without moving and it's a tap; hold still for a moment and it acts on what's under the finger.
    private func touchGesture(_ w: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                guard pinchStart == nil else { touch = nil; return }
                if touch == nil {
                    touch = Touch(startX: v.startLocation.x, startWindow: window)
                    touchToken &+= 1
                    let token = touchToken
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 380_000_000)
                        guard token == touchToken, touch?.mode == .pending else { return }
                        hold(w)
                    }
                }
                guard var t = touch else { return }
                if t.mode == .pending, abs(v.translation.width) > 8 || abs(v.translation.height) > 8 { t.mode = .pan }
                switch t.mode {
                case .pan:
                    let span = t.startWindow.upperBound - t.startWindow.lowerBound
                    setWindow(lower: t.startWindow.lowerBound - Double(v.translation.width / Swift.max(1, w)) * span, span: span)
                case .onSet(let id, let isStart):
                    // Held, then dragged: the edge follows.
                    if abs(v.location.x - t.startX) > 6 { t.mode = .edge(id: id, isStart: isStart); bubble = nil }
                case .draw:
                    let a = ts(t.startX, w), b = ts(Swift.min(w, Swift.max(0, v.location.x)), w)
                    drawing = Swift.min(a, b)...Swift.max(a, b)
                case .edge(let id, let isStart):
                    guard let s = dragging ?? editor.sets.first(where: { $0.id == id }) else { break }
                    var d = s
                    let x = ts(Swift.min(w, Swift.max(0, v.location.x)), w)
                    if isStart { d.start = Swift.min(x, d.end - SetTimelineEditor.minSetS) }
                    else { d.end = Swift.max(x, d.start + SetTimelineEditor.minSetS) }
                    dragging = d
                case .pending, .held:
                    break
                }
                touch = t
            }
            .onEnded { _ in
                guard let t = touch else { return }
                touch = nil
                touchToken &+= 1
                switch t.mode {
                case .pending: tap(at: t.startX, w)
                case .draw:
                    // Held and let go without drawing: offer to place one from the evidence instead.
                    if let d = drawing, d.upperBound - d.lowerBound < SetTimelineEditor.minSetS {
                        drawing = nil
                        bubble = .empty(d.lowerBound)
                    } else {
                        commitDrawing(w)
                    }
                case .onSet(let id, _): bubble = .set(id)
                case .edge(let id, let isStart): commitEdge(id, isStart: isStart, w)
                case .pan, .held: break
                }
            }
    }

    /// A tap selects what's under it: a set, the rest between two, or empty time.
    private func tap(at x: CGFloat, _ w: CGFloat) {
        if bubble != nil { withAnimation(.easeOut(duration: 0.15)) { bubble = nil }; return }
        switch target(at: x, w) {
        case .set(let id): selection = selectedSetId == id ? nil : .set(id)
        case .gap(let id): selection = .gap(after: id)
        case .empty(let t): selection = .empty(at: t)
        }
    }

    /// Holding still brings up the options for what's under the finger, with what heart rate says
    /// about it; nothing changes until you choose. On a rest: remove it (the two sets and the pause become
    /// one) or keep it. On a set: delete, split or count it, or drag on to move its nearer edge. On empty
    /// time: drag to draw the set you did, or let go to place one from the evidence.
    private func hold(_ w: CGFloat) {
        guard var t = touch else { return }
        holdFired &+= 1
        switch target(at: t.startX, w) {
        case .gap(let id):
            selection = .gap(after: id)
            withAnimation(.spring(duration: 0.25)) { bubble = .gap(after: id) }
            t.mode = .held
        case .set(let id):
            selection = .set(id)
            bubble = nil
            if let s = editor.sets.first(where: { $0.id == id }) {
                let at = ts(t.startX, w)
                t.mode = .onSet(id: id, isStart: abs(at - s.start) <= abs(at - s.end))
            }
        case .empty(let at):
            bubble = nil
            drawing = at...at
            t.mode = .draw
        }
        touch = t
    }

    // MARK: Hold options

    /// Rests you've kept, from the whole history, so their hint doesn't come back.
    private var keptRests: [ClosedRange<Int>] {
        (baseHistory + editor.log).filter { $0.kind == .keepRest }.compactMap { r in
            r.after.first.flatMap { $0.count == 2 ? $0[0]...$0[1] : nil }
        }
    }

    /// What heart rate says about the sets as they are now, against your tuning.
    private var hints: (pauses: Set<String>, doubtful: Set<String>) {
        let sets = editor.sets
        let kept = keptRests
        var pauses = Set<String>(), doubtful = Set<String>()
        for sug in SetCalibration.suggestions(sets.map(\.span), hr: timeline.hr, tuning: tuning) {
            switch sug {
            case .join(let i, _, _) where i + 1 < sets.count:
                let gap = sets[i].end...sets[i + 1].start
                if !kept.contains(where: { $0.overlaps(gap) }) { pauses.insert(sets[i].id) }
            case .delete(let i, _, _) where i < sets.count:
                if sets[i].confidence != nil { doubtful.insert(sets[i].id) }
            default: break
            }
        }
        return (pauses, doubtful)
    }

    private func bubbleView(_ b: Bubble, w: CGFloat) -> some View {
        let anchor: Int
        var title = "", detail = ""
        var buttons: [(label: LocalizedStringKey, icon: String, tint: Color, action: () -> Void)] = []
        switch b {
        case .gap(let id):
            let g = editor.gap(after: id) ?? 0...0
            anchor = (g.lowerBound + g.upperBound) / 2
            title = String(localized: "Rest \(LiveIntervalTracker.clock(g.upperBound - g.lowerBound))")
            if let d = heartRateDrop(g) {
                detail = d < Int(tuning.pauseFallBPM)
                    ? String(localized: "Heart rate only fell \(d) bpm: likely a pause")
                    : String(localized: "Heart rate fell \(d) bpm: looks like a real rest")
            }
            buttons = [
                ("Remove rest", "arrow.left.and.right", StrandPalette.accent, {
                    if editor.joinWithNext(id, now: now) { selection = .set(id); afterEdit() }
                    bubble = nil
                }),
                ("Keep rest", "checkmark", StrandPalette.textPrimary, {
                    if editor.keepRest(after: id, now: now) { afterEdit() }
                    bubble = nil
                    selection = nil
                }),
            ]
        case .set(let id):
            let s = editor.sets.first { $0.id == id }
            anchor = s.map { ($0.start + $0.end) / 2 } ?? 0
            let n = editor.counted.firstIndex { $0.id == id }.map { $0 + 1 }
            title = (n.map { "\(unit.capitalized) \($0)" } ?? String(localized: "Uncertain"))
                + " · " + LiveIntervalTracker.clock(s?.duration ?? 0)
            if let s, let rise = heartRateRise(s) {
                detail = rise < Int(tuning.riseBPM)
                    ? String(localized: "Heart rate rose only \(rise) bpm")
                    : String(localized: "Heart rate rose \(rise) bpm")
                if let r = s.reps { detail += " · " + String(localized: "\(r) reps") }
            }
            if s?.uncertain == true {
                buttons.append(("Count it", "checkmark", StrandPalette.statusPositive, {
                    if editor.confirm(id, now: now) { afterEdit() }
                    bubble = nil
                }))
            }
            buttons.append(("Split", "scissors", StrandPalette.textPrimary, {
                if let s {
                    let at = SetCalibration.splitPoint(start: s.start, end: s.end, hr: timeline.hr,
                                                       motion: timeline.motion, hrDelayS: tuning.hrDelayS)
                    if editor.split(id, at: at, now: now) { afterEdit() }
                }
                bubble = nil
            }))
            buttons.append(("Delete", "trash", StrandPalette.statusCritical, {
                editor.delete(id, now: now)
                selection = nil
                bubble = nil
                afterEdit()
            }))
        case .empty(let t):
            anchor = t
            title = String(localized: "No \(unit) here")
            if let rise = heartRateRise(TimelineSet(start: t - 20, end: t + 20)), rise > 0 {
                detail = String(localized: "Heart rate rose \(rise) bpm around here")
            }
            buttons = [("Add a \(unit) here", "plus", StrandPalette.accent, {
                let before = editor.sets.last { $0.end < t }?.end ?? editor.bounds.lowerBound
                let after = editor.sets.first { $0.start > t }?.start ?? editor.bounds.upperBound
                addSet(around: t, within: before...after)
                bubble = nil
            })]
        }
        let width: CGFloat = Swift.min(w - 16, 250)
        let cx = Swift.min(w - width / 2 - 8, Swift.max(width / 2 + 8, px(anchor, w)))
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(StrandFont.subhead.weight(.bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .monospacedDigit()
                if !detail.isEmpty {
                    Text(detail)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 6) {
                ForEach(buttons.indices, id: \.self) { i in
                    let bt = buttons[i]
                    Button(action: bt.action) {
                        Label(bt.label, systemImage: bt.icon)
                            .labelStyle(.titleAndIcon)
                            .font(StrandFont.caption.weight(.semibold))
                            .foregroundStyle(bt.tint)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(StrandPalette.surfaceInset))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(StrandPalette.surfaceOverlay))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(StrandPalette.hairline, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.25), radius: 10, y: 4)
        .position(x: cx, y: 62)
    }

    private enum Target { case set(String), gap(after: String), empty(Int) }

    private func target(at x: CGFloat, _ w: CGFloat) -> Target {
        let t = ts(x, w)
        // A little slack for thin sets when zoomed out.
        let slack = Int(secondsPerPoint(w) * 8)
        let sets = editor.sets
        if let s = sets.first(where: { t >= $0.start && t <= $0.end }) { return .set(s.id) }
        if let i = sets.indices.dropLast().first(where: { sets[$0].end < t && sets[$0 + 1].start > t }) {
            // A thin set beside the touch still wins over the gap when zoomed out.
            if let s = [sets[i], sets[i + 1]].first(where: { t >= $0.start - slack && t <= $0.end + slack }),
               sets[i + 1].start - sets[i].end > 3 * slack { return .set(s.id) }
            return .gap(after: sets[i].id)
        }
        if let s = sets.first(where: { t >= $0.start - slack && t <= $0.end + slack }) { return .set(s.id) }
        return .empty(t)
    }

    private func pinchGesture(_ w: CGFloat) -> some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if pinchStart == nil { pinchStart = (window, v.startLocation.x) }
                guard let g = pinchStart else { return }
                let span0 = g.window.upperBound - g.window.lowerBound
                let span = Swift.min(full.upperBound - full.lowerBound, Swift.max(30, span0 / Double(v.magnification)))
                let frac = Double(g.x / Swift.max(1, w))
                let anchor = g.window.lowerBound + frac * span0
                setWindow(lower: anchor - frac * span, span: span)
            }
            .onEnded { _ in pinchStart = nil }
    }

    /// The set you drew, its edges snapped to the evidence.
    private func commitDrawing(_ w: CGFloat) {
        defer { drawing = nil }
        guard let d = drawing else { return }
        let reach = snapReach(w)
        let s = snapEdge(d.lowerBound, isStart: true, reach: reach)
        let e = snapEdge(d.upperBound, isStart: false, reach: reach)
        if let id = editor.add(start: s, end: Swift.max(e, s + SetTimelineEditor.minSetS), now: now) {
            if let ex = previousExercise(before: s) { editor.setExercise([id], to: ex, now: now) }
            selection = .set(id)
            afterEdit()
        }
    }

    /// A moved edge lands snapped to the evidence. Dragged into a neighbour, the two join.
    private func commitEdge(_ id: String, isStart: Bool, _ w: CGFloat) {
        guard let d = dragging else { return }
        dragging = nil
        let reach = snapReach(w)
        if isStart { editor.move(id, start: snapEdge(d.start, isStart: true, reach: reach), now: now) }
        else { editor.move(id, end: snapEdge(d.end, isStart: false, reach: reach), now: now) }
        if editor.index(of: id) == nil { selection = nil }
        afterEdit()
    }

    /// A draggable edge of the selected set.
    private func handle(for s: TimelineSet, isStart: Bool, w: CGFloat, h: CGFloat) -> some View {
        let x = px(isStart ? s.start : s.end, w)
        return Capsule()
            .fill(StrandPalette.accent)
            .frame(width: 6, height: 40)
            .overlay(Capsule().stroke(StrandPalette.surfaceBase, lineWidth: 1.5))
            .frame(width: 36, height: h)
            .contentShape(Rectangle())
            .position(x: x, y: h / 2)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        // The edge follows the finger; landing is snapped to the evidence.
                        var d = dragging ?? s
                        let t = ts(Swift.min(w, Swift.max(0, v.location.x)), w)
                        if isStart { d.start = Swift.min(t, d.end - SetTimelineEditor.minSetS) }
                        else { d.end = Swift.max(t, d.start + SetTimelineEditor.minSetS) }
                        dragging = d
                    }
                    .onEnded { _ in commitEdge(s.id, isStart: isStart, w) })
            .accessibilityLabel(Text(isStart ? String(localized: "Start of \(unit)") : String(localized: "End of \(unit)")))
            .accessibilityAdjustableAction { dir in
                let delta = dir == .increment ? 2 : -2
                if isStart { editor.move(s.id, start: s.start + delta, now: now) }
                else { editor.move(s.id, end: s.end + delta, now: now) }
                afterEdit()
            }
    }

    private func snapReach(_ w: CGFloat) -> Int { Swift.max(2, Swift.min(12, Int(secondsPerPoint(w) * 10))) }

    /// Where a dragged or drawn edge lands: the edge of the nearest rep run when motion recorded one close
    /// by (motion is exact), else heart rate leaving its low for a start or topping out for an end, moved
    /// earlier by heart rate's delay; else where you put it.
    private func snapEdge(_ t: Int, isStart: Bool, reach: Int) -> Int {
        let edges = timeline.motion.map { isStart ? $0.start : $0.end }
        if let m = edges.min(by: { abs($0 - t) < abs($1 - t) }), abs(m - t) <= reach { return m }
        if isStart { return SetCalibration.snap(t, isStart: true, hr: timeline.hr, reach: reach) }
        let delay = tuning.hrDelayS
        let peak = SetCalibration.snap(t + delay, isStart: false, hr: timeline.hr, reach: reach)
        return peak == t + delay ? t : peak - delay
    }

    private func setWindow(lower: Double, span: Double) {
        let span = Swift.min(full.upperBound - full.lowerBound, span)
        let lo = Swift.min(full.upperBound - span, Swift.max(full.lowerBound, lower))
        window = lo...(lo + span)
    }

    private func zoom(to r: ClosedRange<Double>) {
        withAnimation(.easeInOut(duration: 0.25)) { setWindow(lower: r.lowerBound, span: r.upperBound - r.lowerBound) }
    }

    // MARK: Overview

    /// The whole workout in miniature with the stretch in view outlined. Drag or tap to move there.
    private var overview: some View {
        GeometryReader { g in
            let w = g.size.width
            let f = full
            let span = f.upperBound - f.lowerBound
            ZStack(alignment: .topLeading) {
                SetTimelineChart(timeline: timeline, sets: shown, window: f, compact: true)
                    .opacity(0.8)
                let x0 = CGFloat((window.lowerBound - f.lowerBound) / span) * w
                let x1 = CGFloat((window.upperBound - f.lowerBound) / span) * w
                RoundedRectangle(cornerRadius: 4)
                    .stroke(StrandPalette.accent, lineWidth: 1.5)
                    .frame(width: Swift.max(8, x1 - x0), height: g.size.height)
                    .offset(x: x0)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(StrandPalette.surfaceInset.opacity(0.4)))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let mid = f.lowerBound + Double(v.location.x / Swift.max(1, w)) * span
                let s = window.upperBound - window.lowerBound
                setWindow(lower: mid - s / 2, span: s)
            })
        }
        .accessibilityHidden(true)
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        switch selection {
        case .set(let id):
            if let i = editor.index(of: id) { setActions(editor.sets[i]) } else { hint }
        case .gap(let id):
            if let g = editor.gap(after: id) { gapActions(id, g) } else { hint }
        case .empty(let t):
            emptyActions(t)
        case nil:
            hint
        }
    }

    private var hint: some View {
        Text("Hold a rest, a \(unit) or empty time for its options. Hold a \(unit) and drag to move its edge, or empty time and drag to draw one. A dot marks a rest heart rate says was probably a pause.")
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func setActions(_ s: TimelineSet) -> some View {
        let number = editor.counted.firstIndex { $0.id == s.id }.map { $0 + 1 }
        var detail = [LiveIntervalTracker.clock(s.duration)]
        if let r = s.reps { detail.append(String(localized: "\(r) reps")) }
        if let rise = heartRateRise(s) { detail.append(String(localized: "HR +\(rise)")) }
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(spacing: 6) {
                Text(number.map { "\(unit.capitalized) \($0)" } ?? String(localized: "Uncertain"))
                    .font(StrandFont.subhead.weight(.bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(detail.joined(separator: " · "))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                if s.uncertain {
                    actionButton("Count it", "checkmark", tint: StrandPalette.statusPositive) {
                        editor.confirm(s.id, now: now); afterEdit()
                    }
                }
                actionButton("Split", "scissors") {
                    let at = SetCalibration.splitPoint(start: s.start, end: s.end, hr: timeline.hr,
                                                       motion: timeline.motion, hrDelayS: tuning.hrDelayS)
                    if editor.split(s.id, at: at, now: now) { afterEdit() }
                }
                .disabled(s.duration < 2 * SetTimelineEditor.minSetS + 2)
                actionButton("Delete", "trash", tint: StrandPalette.statusCritical) {
                    editor.delete(s.id, now: now)
                    selection = nil
                    afterEdit()
                }
            }
            if mode == .lifting { exerciseRow(s) }
        }
    }

    private func exerciseRow(_ s: TimelineSet) -> some View {
        let names = exerciseNames
        let previous = previousExercise(before: s.start)
        return VStack(alignment: .leading, spacing: 6) {
            Menu {
                if let p = previous, p != s.exercise {
                    Button { setExercise(p, for: s.id) } label: { Label("Same as previous: \(p)", systemImage: "arrow.turn.down.right") }
                }
                ForEach(names, id: \.self) { n in
                    Button { setExercise(n, for: s.id) } label: {
                        if n == s.exercise { Label(n, systemImage: "checkmark") } else { Text(n) }
                    }
                }
                Button { newName = ""; naming = true } label: { Label("New exercise…", systemImage: "plus") }
                if s.exercise != nil {
                    Button(role: .destructive) { setExercise(nil, for: s.id) } label: { Label("No exercise", systemImage: "xmark") }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "dumbbell")
                    Text(s.exercise ?? String(localized: "Exercise"))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                }
                .font(StrandFont.footnote.weight(.semibold))
                .foregroundStyle(s.exercise == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
            }
            setCategoryRow(s)
        }
    }

    /// The set's type: tap one to set it for this set alone, tap it again to go back to its exercise's
    /// or the workout's, which shows lighter.
    private func setCategoryRow(_ s: TimelineSet) -> some View {
        let inherited = s.exercise.flatMap { categories.category(for: $0) } ?? workoutCategories.fallback(startTs: timeline.startTs)
        return VStack(alignment: .leading, spacing: 3) {
            StrengthTypeChips(chosen: Set([s.category].compactMap { $0 }), shaded: s.category == nil ? inherited : nil,
                              small: true,
                              onTap: { c in if editor.setCategory([s.id], to: s.category == c ? nil : c, now: now) { afterEdit() } },
                              onAdd: { c in if editor.setCategory([s.id], to: c, now: now) { afterEdit() } })
            if s.category == nil, inherited != nil {
                Text(s.exercise != nil ? "Type from the exercise" : "Type from the workout")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func gapActions(_ id: String, _ g: ClosedRange<Int>) -> some View {
        let drop = heartRateDrop(g)
        var detail = [String(localized: "Rest \(LiveIntervalTracker.clock(g.upperBound - g.lowerBound))")]
        if let d = drop { detail.append(d > 0 ? String(localized: "HR fell \(d) bpm") : String(localized: "HR didn't fall")) }
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text(detail.joined(separator: " · "))
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
            HStack(spacing: 8) {
                actionButton("Remove rest", "arrow.left.and.right", tint: StrandPalette.accent) {
                    editor.joinWithNext(id, now: now)
                    selection = .set(id)
                    afterEdit()
                }
                actionButton("Keep rest", "checkmark") {
                    if editor.keepRest(after: id, now: now) { afterEdit() }
                    selection = nil
                }
                if g.upperBound - g.lowerBound >= 3 * SetTimelineEditor.minSetS + 4 {
                    actionButton("Add a set here", "plus") { addSet(around: (g.lowerBound + g.upperBound) / 2, within: g) }
                }
            }
            Text("Joining makes the two and the pause one set and keeps the readings. Either choice teaches detection how your rests look.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func emptyActions(_ t: Int) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(spacing: 8) {
                actionButton("Add a set here", "plus", tint: StrandPalette.accent) {
                    let before = editor.sets.last { $0.end < t }?.end ?? editor.bounds.lowerBound
                    let after = editor.sets.first { $0.start > t }?.start ?? editor.bounds.upperBound
                    addSet(around: t, within: before...after)
                }
            }
            Text("Or hold and drag across the time it took.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func actionButton(_ title: LocalizedStringKey, _ icon: String, tint: Color = StrandPalette.textPrimary,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(StrandFont.footnote.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(StrandPalette.surfaceInset))
        }
        .buttonStyle(.plain)
    }

    // MARK: Edits

    private var exerciseNames: [String] {
        var seen = Set<String>()
        return (editor.sets.compactMap(\.exercise) + exercises + categories.recentNames)
            .filter { seen.insert($0.lowercased()).inserted }
            .prefix(25).map { $0 }
    }

    private func previousExercise(before t: Int) -> String? {
        editor.sets.last { $0.end <= t && $0.exercise != nil }?.exercise
    }

    private func setExercise(_ name: String?, for id: String) {
        if let n = name { categories.note(n) }
        if editor.setExercise([id], to: name, now: now) { afterEdit() }
    }

    /// A set placed from the evidence around a tap: the motion run there if there is one, else heart
    /// rate's climb ending at its peak, else your typical set length; always inside the free time.
    private func addSet(around t: Int, within free: ClosedRange<Int>) {
        let lo = free.lowerBound + 1, hi = free.upperBound - 1
        var span: (Int, Int)
        if let m = timeline.motion.first(where: { t >= $0.start - 10 && t <= $0.end + 10 }) {
            span = (m.start, m.end)
        } else {
            let typical = SetCalibration.typical(editor.counted.map(\.span)).work ?? 40
            let peak = SetCalibration.snap(t + tuning.hrDelayS, isStart: false, hr: timeline.hr, reach: 30)
            let end = peak - tuning.hrDelayS
            let start = SetCalibration.snap(end - typical, isStart: true, hr: timeline.hr, reach: 12)
            span = end - start >= SetTimelineEditor.minSetS ? (start, end) : (t - typical / 2, t + typical / 2)
        }
        let s = Swift.max(lo, span.0), e = Swift.min(hi, span.1)
        guard e - s >= SetTimelineEditor.minSetS, let id = editor.add(start: s, end: e, now: now) else { return }
        if let ex = previousExercise(before: s) { editor.setExercise([id], to: ex, now: now) }
        selection = .set(id)
        afterEdit()
    }

    /// Recalculate and save: the timeline's sets become yours, with the history so far.
    private func afterEdit() {
        if case .set(let id) = selection, editor.index(of: id) == nil { selection = nil }
        if case .gap(let id) = selection, editor.gap(after: id) == nil { selection = nil }
        let detected = timeline.detected.sorted { $0.start < $1.start }
        // A rest you kept is your call on this workout too, so it counts as corrected (and teaches).
        let kept = (baseHistory + editor.log).contains { $0.kind == .keepRest || $0.kind == .confirm }
        timeline.edited = editor.sets == detected && !kept ? nil : editor.sets
        timeline.history = baseHistory + editor.log
        onChange(timeline)
        learnSoon()
    }

    /// A moment after the last edit, detection refits from every corrected workout of this sport, this
    /// one as it is now, so the rest of a live workout and every later one are found your way. This
    /// workout keeps your sets either way.
    private func learnSoon() {
        learnTask?.cancel()
        let t = timeline
        let m = mode
        learnTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, t.isCorrected, StrengthTuningStore.override(sport: t.sport) == nil else { return }
            let before = StrengthTuningStore.learned(sport: t.sport, mode: m)
            guard let fit = await StrengthTuningStore.refit(sport: t.sport, mode: m, including: [t]),
                  !Task.isCancelled else { return }
            withAnimation { learnedNote = Self.describe(from: before, to: fit.tuning, unit: unit) }
        }
    }

    /// What changed, in your terms: at most two of the changes that move set counts most.
    static func describe(from a: StrengthTuning, to b: StrengthTuning, unit: String) -> String {
        var out: [String] = []
        if b.maxPauseS != a.maxPauseS || b.pauseFallBPM != a.pauseFallBPM {
            out.append(b.maxPauseS > a.maxPauseS || b.pauseFallBPM > a.pauseFallBPM
                ? String(localized: "pauses up to \(LiveIntervalTracker.clock(b.maxPauseS)) now stay inside one \(unit)")
                : String(localized: "shorter pauses now count as rests"))
        }
        if b.riseBPM != a.riseBPM {
            out.append(String(localized: "a \(unit) needs heart rate to rise \(Int(b.riseBPM)) bpm (was \(Int(a.riseBPM)))"))
        }
        if b.minWorkS != a.minWorkS {
            out.append(String(localized: "shortest \(unit) \(LiveIntervalTracker.clock(b.minWorkS)) (was \(LiveIntervalTracker.clock(a.minWorkS)))"))
        }
        if b.minRestS != a.minRestS {
            out.append(String(localized: "shortest rest \(LiveIntervalTracker.clock(b.minRestS)) (was \(LiveIntervalTracker.clock(a.minRestS)))"))
        }
        if b.hrDelayS != a.hrDelayS {
            out.append(String(localized: "heart rate lag \(b.hrDelayS) s (was \(a.hrDelayS) s)"))
        }
        if b.confidenceThreshold != a.confidenceThreshold || b.minReps != a.minReps {
            out.append(b.confidenceThreshold > a.confidenceThreshold || b.minReps > a.minReps
                ? String(localized: "weak stretches are now left uncertain more often")
                : String(localized: "weaker stretches now count"))
        }
        guard !out.isEmpty else {
            return String(localized: "Detection checked your edits: its settings already fit them.")
        }
        return String(localized: "Detection learned: ") + out.prefix(2).joined(separator: ", ") + "."
    }

    private func heartRateRise(_ s: TimelineSet) -> Int? {
        let before = timeline.hr.filter { $0.ts >= s.start - 30 && $0.ts <= s.start + 3 }.map(\.bpm).min()
        let peak = timeline.hr.filter { $0.ts >= s.start && $0.ts <= s.end + tuning.hrDelayS + 10 }.map(\.bpm).max()
        guard let b = before, let p = peak else { return nil }
        return Swift.max(0, p - b)
    }

    private func heartRateDrop(_ g: ClosedRange<Int>) -> Int? {
        let peak = timeline.hr.filter { $0.ts >= g.lowerBound - 5 && $0.ts <= g.lowerBound + tuning.hrDelayS }.map(\.bpm).max()
        let low = timeline.hr.filter { $0.ts >= g.lowerBound && $0.ts <= g.upperBound + 3 }.map(\.bpm).min()
        guard let p = peak, let l = low else { return nil }
        return Swift.max(0, p - l)
    }
}

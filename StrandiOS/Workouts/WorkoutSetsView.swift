import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// On a workout's detail screen: the sets it counted, drawn over the session's heart rate, and the way
/// into correcting them. Shown for workouts whose sport counts sets or intervals.
struct WorkoutSetsCard: View {
    let row: WorkoutRow
    /// Raised by the detail screen's Edit sets button too.
    @Binding var editing: Bool
    @EnvironmentObject private var repo: Repository
    @State private var record: WorkoutSetsRecord?
    @State private var loadedSeq: Int?

    private var countsSets: Bool { LiveIntervalModes.mode(forSport: row.sport) != nil }

    var body: some View {
        // Always in the hierarchy (a zero-height stand-in when hidden) so the editor sheet can still open
        // from the toolbar for a workout that doesn't show the card.
        VStack(spacing: 0) {
            if let r = record, countsSets || r.edited != nil {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    SectionHeader(LocalizedStringKey(LiveIntervalModes.unitName(r.segmenterMode, count: 2).capitalized),
                                  overline: overline(r), trailing: "\(r.sets.count)")
                    NoopCard(tint: StrandPalette.effortColor) {
                        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                            if r.hr.isEmpty {
                                Text("No heart rate is stored for this workout yet, so nothing was counted. It fills in after the strap syncs, or you can enter your sets now.")
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                SetsChart(record: r, sets: r.sets, selected: nil)
                                    .frame(height: 110)
                            }
                            if !r.sets.isEmpty {
                                Text(WorkoutSetsStore.notesLine(r).components(separatedBy: "\n").first ?? "")
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let n = Self.likelyFixes(r), n > 0 {
                                Label(String(localized: "\(n) suggested fixes: short breaks or very short sets"),
                                      systemImage: "exclamationmark.circle")
                                    .font(StrandFont.caption.weight(.semibold))
                                    .foregroundStyle(StrandPalette.statusWarning)
                            }
                            Button {
                                editing = true
                            } label: {
                                Label(r.edited == nil ? (r.sets.isEmpty ? "Enter sets" : "Review and correct") : "Edit sets",
                                      systemImage: "slider.horizontal.3")
                                    .font(StrandFont.subhead.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(StrandPalette.accent)
                        }
                    }
                }
            } else {
                Color.clear.frame(height: 0)
            }
        }
        // Reload when data lands: a workout saved before the strap synced gets its heart rate later.
        .task(id: repo.refreshSeq) { await load() }
        .sheet(isPresented: $editing) {
            NavigationStack {
                if let r = record {
                    WorkoutSetsEditor(record: r, row: row) { updated in record = updated }
                } else {
                    ProgressView().task { await load() }
                }
            }
        }
    }

    private func load() async {
        guard loadedSeq != repo.refreshSeq || record == nil else { return }
        loadedSeq = repo.refreshSeq
        if let saved = WorkoutSetsStore.load(startTs: row.startTs, sport: row.sport),
           !(saved.hr.isEmpty && saved.edited == nil) {
            record = saved
            return
        }
        let built = await WorkoutSetsStore.build(row: row, repo: repo)
        // Keep your entered sets if heart rate arrives after them.
        if let saved = WorkoutSetsStore.load(startTs: row.startTs, sport: row.sport), let edited = saved.edited {
            var merged = built
            merged.edited = edited
            WorkoutSetsStore.save(merged)
            record = merged
        } else {
            record = built
        }
    }

    /// How many fixes the editor would suggest, for a record you haven't corrected yet.
    static func likelyFixes(_ r: WorkoutSetsRecord) -> Int? {
        guard r.edited == nil else { return nil }
        let s = r.sets.sorted { $0.start < $1.start }
        let short = s.filter { $0.end - $0.start < WorkoutSetsEditor.shortSetS }.count
        let breaks = s.count > 1 ? (1..<s.count).filter { s[$0].start - s[$0 - 1].end < WorkoutSetsEditor.shortBreakS }.count : 0
        return short + breaks
    }

    private func overline(_ r: WorkoutSetsRecord) -> LocalizedStringKey {
        if r.edited != nil { return "Corrected by you" }
        if r.hr.isEmpty { return "Not counted yet" }
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
    /// What a drag on the chart is doing.
    private enum DragMode { case moveStart(Int), moveEnd(Int), paint(from: Int) }
    @State private var dragMode: DragMode?
    /// The span a drag across the chart covers so far.
    @State private var paint: ClosedRange<Int>?
    @State private var saving = false
    @State private var fitNote: String?
    /// Earlier versions of `sets`, for Undo.
    @State private var history: [[WorkoutSetsRecord.SetSpan]] = []
    /// Starts of sets you made by splitting: the break before them isn't suggested for joining.
    @State private var userSplits: Set<Int> = []
    @State private var showFixes = false
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

    /// A break this short between two sets is suggested for joining; a set this short for deleting.
    static let shortBreakS = 45
    static let shortSetS = 12

    var body: some View {
        List {
            Section {
                editableChart
                    .frame(height: 180)
                    .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 6, trailing: 12))
                actionBar
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 10, trailing: 12))
            } footer: {
                Text(record.hr.isEmpty
                     ? "No heart rate for this workout yet. Add your \(LiveIntervalModes.unitName(mode, count: 2)) with +."
                     : "Drag an edge to move it, drag over a gap to join or add, tap to select.")
            }

            let fixes = suggestions
            if !fixes.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showFixes) {
                        ForEach(fixes) { f in
                            HStack(spacing: 10) {
                                Text(f.text)
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 4)
                                Button(f.verb) { apply([f]) }
                                    .font(StrandFont.footnote.weight(.semibold))
                                    .buttonStyle(.borderless)
                            }
                        }
                    } label: {
                        HStack {
                            Label(String(localized: "\(fixes.count) look off"), systemImage: "wand.and.stars")
                                .font(StrandFont.subhead.weight(.semibold))
                                .foregroundStyle(StrandPalette.statusWarning)
                            Spacer()
                            Button(String(localized: "Fix all")) { apply(fixes) }
                                .font(StrandFont.subhead.weight(.semibold))
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Section {
                ForEach(Array(sets.enumerated()), id: \.element.id) { i, s in
                    setRow(i, s)
                        .contentShape(Rectangle())
                        .onTapGesture { selected = selected == i ? nil : i; addAt = nil }
                        .listRowBackground(selected == i ? StrandPalette.accent.opacity(0.12) : nil)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { delete(i) } label: { Label("Delete", systemImage: "trash") }
                        }
                }
            } header: {
                Text("\(sets.count) \(LiveIntervalModes.unitName(mode, count: sets.count))")
            } footer: {
                Text(learningNote)
            }
        }
        .navigationTitle(String(localized: "Edit \(LiveIntervalModes.unitName(mode, count: 2))"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? String(localized: "Saving…") : String(localized: "Save")) { Task { await save() } }
                    .disabled(saving)
            }
            if record.edited != nil || sets != record.detected.sorted(by: { $0.start < $1.start }) {
                ToolbarItem(placement: .bottomBar) {
                    Button(String(localized: "Back to what was counted")) {
                        change { sets = record.detected.sorted { $0.start < $1.start } }
                        selected = nil
                    }
                    .font(StrandFont.footnote)
                }
            }
        }
    }

    /// Under the chart: what you can do right now. With a set selected, its reps and its actions; else
    /// add and undo.
    @ViewBuilder
    private var actionBar: some View {
        if let i = selected, i < sets.count {
            HStack(spacing: 8) {
                Text("\(i + 1)")
                    .font(StrandFont.subhead.weight(.bold))
                    .foregroundStyle(StrandPalette.accent)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(StrandPalette.accent.opacity(0.12)))
                if mode == .lifting {
                    Stepper(value: Binding(get: { sets[i].reps ?? 0 },
                                           set: { v in change { sets[i].reps = v > 0 ? v : nil } }),
                            in: 0...100) {
                        Text(sets[i].reps.map { String(localized: "\($0) reps") } ?? String(localized: "Reps"))
                            .font(StrandFont.footnote.weight(.semibold))
                            .monospacedDigit()
                    }
                    .fixedSize()
                }
                Spacer(minLength: 0)
                if sets[i].end - sets[i].start >= 20 {
                    iconButton("scissors", label: "Split") { split(i) }
                }
                if i + 1 < sets.count {
                    iconButton("arrow.down.to.line", label: "Join with next") { merge(i) }
                }
                iconButton("trash", label: "Delete", destructive: true) { delete(i) }
            }
        } else {
            HStack(spacing: 10) {
                actionButton(addAt.map { String(localized: "Add at \(offset($0))") } ?? String(localized: "Add a \(unit)"),
                             icon: "plus") {
                    if let t = addAt { add(at: t) } else { addAfterLast() }
                }
                Spacer(minLength: 0)
                iconButton("arrow.uturn.backward", label: "Undo", enabled: !history.isEmpty) { undo() }
            }
        }
    }

    private func iconButton(_ icon: String, label: LocalizedStringKey, enabled: Bool = true, destructive: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(StrandPalette.surfaceInset))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(!enabled ? StrandPalette.textTertiary : (destructive ? StrandPalette.statusCritical : StrandPalette.accent))
        .disabled(!enabled)
        .accessibilityLabel(Text(label))
    }

    private func actionButton(_ title: String, icon: String, enabled: Bool = true,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(StrandFont.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(StrandPalette.accent.opacity(enabled ? 0.12 : 0.05)))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(enabled ? StrandPalette.accent : StrandPalette.textTertiary)
        .disabled(!enabled)
    }

    // MARK: Suggestions

    struct Fix: Identifiable {
        enum Kind { case join(start: Int), delete(start: Int) }
        let kind: Kind
        let text: String
        let verb: String
        let icon: String
        var id: String {
            switch kind {
            case .join(let s): return "j\(s)"
            case .delete(let s): return "d\(s)"
            }
        }
    }

    /// Short breaks inside what looks like one set, and sets too short to be real. Keyed by set start, so
    /// applying one doesn't shift the others. Breaks you made by splitting aren't suggested back.
    private var suggestions: [Fix] {
        var out: [Fix] = []
        for i in sets.indices {
            let s = sets[i]
            if s.end - s.start < Self.shortSetS {
                out.append(Fix(kind: .delete(start: s.start),
                               text: String(localized: "\(unit.capitalized) \(i + 1) lasts \(LiveIntervalTracker.clock(s.end - s.start)). Probably not a real one."),
                               verb: String(localized: "Delete"), icon: "minus.circle"))
            }
            if i + 1 < sets.count {
                let gap = sets[i + 1].start - s.end
                if gap < Self.shortBreakS, !userSplits.contains(sets[i + 1].start) {
                    out.append(Fix(kind: .join(start: s.start),
                                   text: String(localized: "Only \(LiveIntervalTracker.clock(gap)) between \(i + 1) and \(i + 2). Probably one \(unit)."),
                                   verb: String(localized: "Join"), icon: "arrow.left.and.right"))
                }
            }
        }
        return out
    }

    private func apply(_ fixes: [Fix]) {
        change {
            // Joins first, latest first, so earlier starts stay put; then deletes.
            let joins = fixes.compactMap { f -> Int? in if case .join(let s) = f.kind { return s } else { return nil } }
            for start in joins.sorted(by: >) {
                if let i = sets.firstIndex(where: { $0.start == start }), i + 1 < sets.count { joinRaw(i) }
            }
            let deletes = fixes.compactMap { f -> Int? in if case .delete(let s) = f.kind { return s } else { return nil } }
            for start in deletes {
                // A short set that a join above swallowed is gone already, and that's fine.
                sets.removeAll { $0.start == start && $0.end - $0.start < Self.shortSetS }
            }
        }
        selected = nil
    }

    // MARK: Undo

    private func change(_ edit: () -> Void) {
        history.append(sets)
        if history.count > 50 { history.removeFirst() }
        edit()
    }

    private func undo() {
        guard let last = history.popLast() else { return }
        sets = last
        selected = nil
        addAt = nil
    }

    // MARK: Rows

    private func setRow(_ i: Int, _ s: WorkoutSetsRecord.SetSpan) -> some View {
        let rest = i > 0 ? s.start - sets[i - 1].end : nil
        let peak = record.hr.filter { $0.ts >= s.start && $0.ts <= s.end + 20 }.map(\.bpm).max()
        return HStack(alignment: .center) {
            Text("\(i + 1)")
                .font(StrandFont.subhead.weight(.bold))
                .foregroundStyle(StrandPalette.accent)
                .frame(width: 28, height: 28)
                .background(Circle().fill(StrandPalette.accent.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(LiveIntervalTracker.clock(s.end - s.start) + (s.reps.map { " · " + String(localized: "\($0) reps") } ?? ""))
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(detailLine(s, rest: rest, peak: peak))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer()
        }
    }

    private func detailLine(_ s: WorkoutSetsRecord.SetSpan, rest: Int?, peak: Int?) -> String {
        var parts = ["\(offset(s.start))–\(offset(s.end))"]
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

    // MARK: Chart gestures

    private var editableChart: some View {
        GeometryReader { g in
            let w = Swift.max(g.size.width, 1)
            let t0 = record.startTs, t1 = Swift.max(record.endTs, record.startTs + 1)
            let toTs: (CGFloat) -> Int = { x in
                t0 + Int((Double(Swift.min(w, Swift.max(0, x)) / w) * Double(t1 - t0)).rounded())
            }
            let toX: (Int) -> CGFloat = { ts in CGFloat(Double(ts - t0) / Double(t1 - t0)) * w }
            SetsChart(record: record, sets: sets, selected: selected, marker: addAt, paint: paint,
                      labelled: true, flagBreaksUnder: Self.shortBreakS)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged { v in dragChanged(v, toTs: toTs, toX: toX) }
                        .onEnded { v in dragEnded(v, toTs: toTs) }
                )
                .simultaneousGesture(SpatialTapGesture().onEnded { v in tapped(toTs(v.location.x)) })
        }
    }

    private func dragChanged(_ v: DragGesture.Value, toTs: (CGFloat) -> Int, toX: (Int) -> CGFloat) {
        if dragMode == nil {
            // Grab the nearest edge within a finger's width, else draw a span.
            let x = v.startLocation.x
            var best: (mode: DragMode, d: CGFloat)?
            for (i, s) in sets.enumerated() {
                let ds = abs(toX(s.start) - x), de = abs(toX(s.end) - x)
                if ds < 16, ds < (best?.d ?? .infinity) { best = (.moveStart(i), ds) }
                if de < 16, de < (best?.d ?? .infinity) { best = (.moveEnd(i), de) }
            }
            dragMode = best?.mode ?? .paint(from: toTs(x))
            addAt = nil
            history.append(sets)
        }
        let ts = toTs(v.location.x)
        switch dragMode {
        case .moveStart(let i)?:
            selected = i
            sets[i].start = Swift.max(record.startTs, Swift.min(ts, sets[i].end - 5))
        case .moveEnd(let i)?:
            selected = i
            sets[i].end = Swift.min(record.endTs, Swift.max(ts, sets[i].start + 5))
        case .paint(let from)?:
            paint = Swift.min(from, ts)...Swift.max(from, ts)
        case nil:
            break
        }
    }

    private func dragEnded(_ v: DragGesture.Value, toTs: (CGFloat) -> Int) {
        if case .paint? = dragMode, let r = paint, r.upperBound - r.lowerBound >= 5 {
            // Everything the span touches becomes one set: joins a split set, or adds a missed one.
            let touched = sets.filter { $0.end >= r.lowerBound && $0.start <= r.upperBound }
            let start = ([r.lowerBound] + touched.map(\.start)).min()!
            let end = ([r.upperBound] + touched.map(\.end)).max()!
            let reps = touched.compactMap(\.reps).reduce(0, +)
            sets.removeAll { $0.end >= r.lowerBound && $0.start <= r.upperBound }
            userSplits.subtract(touched.map(\.start))
            sets.append(.init(start: start, end: end, reps: reps > 0 ? reps : nil))
            sets.sort { $0.start < $1.start }
            selected = sets.firstIndex { $0.start == start }
        } else if case .paint? = dragMode {
            // A tiny drag that changed nothing shouldn't take an Undo step.
            if history.last == sets { history.removeLast() }
        } else {
            normalize()
        }
        dragMode = nil
        paint = nil
    }

    /// After moving an edge: in order, and overlapping or touching sets joined.
    private func normalize() {
        let keep = selected.flatMap { $0 < sets.count ? sets[$0].start : nil }
        var out: [WorkoutSetsRecord.SetSpan] = []
        for s in sets.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, s.start <= last.end + 2 {
                let reps = (last.reps ?? 0) + (s.reps ?? 0)
                out[out.count - 1] = .init(start: last.start, end: Swift.max(last.end, s.end), reps: reps > 0 ? reps : nil)
            } else {
                out.append(s)
            }
        }
        sets = out
        selected = keep.flatMap { k in out.firstIndex { k >= $0.start && k <= $0.end } }
    }

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
        change {
            sets.append(.init(start: start, end: end, reps: nil))
            sets.sort { $0.start < $1.start }
        }
        selected = sets.firstIndex { $0.start == start }
        addAt = nil
    }

    /// A new one after the last, about 40 s of work after 90 s of rest, inside the workout.
    private func addAfterLast() {
        let start = min(record.endTs - 10, (sets.last?.end ?? record.startTs) + (sets.isEmpty ? 60 : 90))
        let end = min(record.endTs, start + 40)
        guard end - start >= 5 else { return }
        change {
            sets.append(.init(start: start, end: end, reps: nil))
            sets.sort { $0.start < $1.start }
        }
        selected = sets.firstIndex { $0.start == start }
    }

    private func delete(_ i: Int) {
        change { sets.remove(at: i) }
        selected = nil
    }

    private func merge(_ i: Int) {
        guard i + 1 < sets.count else { return }
        change { joinRaw(i) }
        selected = i
    }

    /// Set `i` and the next become one, reps added.
    private func joinRaw(_ i: Int) {
        let a = sets[i], b = sets[i + 1]
        let reps: Int? = (a.reps ?? 0) + (b.reps ?? 0) > 0 ? (a.reps ?? 0) + (b.reps ?? 0) : nil
        sets[i] = .init(start: a.start, end: b.end, reps: reps)
        sets.remove(at: i + 1)
        userSplits.remove(b.start)
    }

    /// Two sets where heart rate dips lowest in the middle of this one (or at its middle without heart
    /// rate), with a short break between.
    private func split(_ i: Int) {
        let s = sets[i]
        let lo = s.start + (s.end - s.start) / 5, hi = s.end - (s.end - s.start) / 5
        let inside = record.hr.filter { $0.ts >= lo && $0.ts <= hi }
        let cut = inside.min(by: { $0.bpm < $1.bpm })?.ts ?? (s.start + s.end) / 2
        let first = WorkoutSetsRecord.SetSpan(start: s.start, end: max(s.start + 5, cut - 3), reps: nil)
        let second = WorkoutSetsRecord.SetSpan(start: min(s.end - 5, cut + 3), end: s.end, reps: nil)
        guard second.start > first.end else { return }
        change {
            sets[i] = first
            sets.insert(second, at: i + 1)
        }
        userSplits.insert(second.start)
        selected = i + 1
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
    /// A span being drawn, outlined.
    var paint: ClosedRange<Int>? = nil
    /// Number each set at its top.
    var labelled = false
    /// Mark breaks shorter than this (seconds) in amber.
    var flagBreaksUnder: Int? = nil
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
                if labelled {
                    for (i, s) in sets.enumerated() where x(s.end) - x(s.start) >= 12 {
                        ctx.draw(Text("\(i + 1)").font(.system(size: 10, weight: .bold))
                                    .foregroundColor(StrandPalette.accent),
                                 at: CGPoint(x: (x(s.start) + x(s.end)) / 2, y: 8))
                    }
                }
                if let limit = flagBreaksUnder, sets.count > 1 {
                    for i in 0..<(sets.count - 1) where sets[i + 1].start - sets[i].end < limit {
                        let mid = (x(sets[i].end) + x(sets[i + 1].start)) / 2
                        let r = CGRect(x: mid - 7, y: size.height - 7, width: 14, height: 5)
                        ctx.fill(Path(roundedRect: r, cornerRadius: 2.5), with: .color(StrandPalette.statusWarning))
                    }
                }
                if let i = selected, i < sets.count {
                    // Handles on the selected set's edges, to drag.
                    for edge in [sets[i].start, sets[i].end] {
                        let r = CGRect(x: x(edge) - 3, y: size.height / 2 - 14, width: 6, height: 28)
                        ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(StrandPalette.accent))
                    }
                }
                if let p = paint {
                    let r = CGRect(x: x(p.lowerBound), y: 1, width: max(2, x(p.upperBound) - x(p.lowerBound)),
                                   height: size.height - 2)
                    ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(StrandPalette.accent.opacity(0.15)))
                    ctx.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(StrandPalette.accent),
                               style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                }
                if let m = marker {
                    var p = Path()
                    p.move(to: CGPoint(x: x(m), y: 0))
                    p.addLine(to: CGPoint(x: x(m), y: size.height))
                    ctx.stroke(p, with: .color(StrandPalette.textPrimary.opacity(0.6)),
                               style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
            .contentShape(Rectangle())
            // Only when the caller wants taps here; the editor handles its own taps and drags.
            .gesture(SpatialTapGesture().onEnded { v in
                guard let onTap, w > 0 else { return }
                onTap(Int(t0 + Double(v.location.x / w) * (t1 - t0)))
            }, including: onTap == nil ? .none : .all)
            .overlay(alignment: .topLeading) {
                Text("\(Int(hi)) bpm").font(.system(size: 9)).foregroundStyle(StrandPalette.textTertiary)
            }
            .frame(width: w, height: h)
        }
        .accessibilityLabel(Text(String(localized: "\(sets.count) shaded over the workout's heart rate")))
    }
}

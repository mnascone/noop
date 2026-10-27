import SwiftUI
import Combine
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore

/// One strength workout as a lift day: what kind it was, what was in it, and its numbers, from its set
/// timeline (sets, rests, recovery) and the Lift Log (exercises, reps, volume).
struct LiftDay: Identifiable {
    let row: WorkoutRow
    var id: String { "\(row.startTs)-\(row.source)" }
    /// What it was, in your types' order: set on the workout, else every type with at least a quarter
    /// of its typed sets.
    let types: [StrengthCategory]
    let typesChosen: Bool
    let exercises: [String]
    let sets: Int?
    let workS: Int?
    let avgRestS: Int?
    let avgDrop60: Int?
    let reps: Int?
    let volumeKg: Double?
    var date: Date { Date(timeIntervalSince1970: TimeInterval(row.startTs)) }
}

@MainActor
enum LiftDays {
    /// Lift days among `rows`: strength workouts, and any workout you've entered sets for.
    static func build(rows: [WorkoutRow], repo: Repository) async -> [LiftDay] {
        let timelines = await WorkoutSetsStore.readAll()
        var byStart: [Int: SetTimeline] = [:]
        for t in timelines { byStart[t.startTs] = t }
        let strength = rows.filter { WorkoutCategoryStore.isStrength($0.sport) || byStart[$0.startTs] != nil }
        guard !strength.isEmpty else { return [] }

        // The Lift Log's sets, matched to workouts by time.
        var liftSets: [Int: [LiftSetRow]] = [:]
        if let store = await repo.storeHandle(), let lo = strength.map(\.startTs).min(), let hi = strength.map(\.endTs).max() {
            let sessions = (try? await store.liftSessions(deviceId: repo.deviceId, fromTs: lo - 3 * 3600, toTs: hi)) ?? []
            for sess in sessions {
                guard let row = strength.first(where: { sess.startTs >= $0.startTs - 1800 && sess.startTs <= $0.endTs })
                else { continue }
                let sets = (try? await store.liftSets(sessionId: sess.id)) ?? []
                for s in sets { ExerciseCategoryStore.shared.note(s.exercise, region: s.primaryMuscle?.region.rawValue) }
                liftSets[row.startTs, default: []] += sets
            }
        }

        let workoutTypes = WorkoutCategoryStore.shared
        let exerciseTypes = ExerciseCategoryStore.shared
        let order = StrengthTypeStore.shared.types
        return strength.map { row in
            let t = byStart[row.startTs]
            let logged = (liftSets[row.startTs] ?? []).filter { !$0.isWarmup && LiftMetrics.isPerformed(reps: $0.reps) }
            let sum = t.map { SetSummary($0) { exerciseTypes.category(for: $0) } }
            // Types: chosen for the workout, else the ones with a fair share of its typed sets.
            let chosen = workoutTypes.categories(startTs: row.startTs)
            var types: [StrengthCategory]
            if !chosen.isEmpty {
                types = order.filter(chosen.contains)
            } else {
                var counts = sum?.byCategory ?? [:]
                if counts.isEmpty {
                    for s in logged {
                        if let c = exerciseTypes.category(for: s.exercise, primaryRegion: s.primaryMuscle?.region.rawValue) {
                            counts[c, default: 0] += 1
                        }
                    }
                }
                let total = counts.values.reduce(0, +)
                types = order.filter { total > 0 && Double(counts[$0] ?? 0) / Double(total) >= 0.25 }
            }
            var seen = Set<String>()
            let exercises = ((t?.counted.compactMap(\.exercise) ?? []) + logged.map(\.exercise))
                .filter { seen.insert($0.lowercased()).inserted }
            let timelineReps = t?.counted.compactMap(\.reps) ?? []
            let loggedReps = logged.compactMap(\.reps)
            let volume = logged.compactMap { s -> Double? in
                guard let w = s.weightKg, let r = s.reps, w > 0, r > 0 else { return nil }
                return w * Double(r)
            }
            return LiftDay(row: row, types: types, typesChosen: !chosen.isEmpty, exercises: exercises,
                           sets: sum.map(\.count) ?? (logged.isEmpty ? nil : logged.count),
                           workS: sum.flatMap { $0.count > 0 ? $0.workS : nil },
                           avgRestS: sum?.avgRestS, avgDrop60: sum?.avgDrop60,
                           reps: !loggedReps.isEmpty ? loggedReps.reduce(0, +)
                               : (timelineReps.isEmpty ? nil : timelineReps.reduce(0, +)),
                           volumeKg: volume.isEmpty ? nil : volume.reduce(0, +))
        }
        .sorted { $0.row.startTs > $1.row.startTs }
    }
}

/// The figures lift days are compared on.
enum LiftMetric: String, CaseIterable, Identifiable {
    case sets, working, rest, recovery, effort, duration, avgHr, reps, volume
    var id: String { rawValue }

    var title: String {
        switch self {
        case .sets: return String(localized: "Sets")
        case .working: return String(localized: "Working time")
        case .rest: return String(localized: "Average rest")
        case .recovery: return String(localized: "HR recovery in 60 s")
        case .effort: return String(localized: "Effort")
        case .duration: return String(localized: "Duration")
        case .avgHr: return String(localized: "Average HR")
        case .reps: return String(localized: "Reps")
        case .volume: return String(localized: "Volume")
        }
    }

    func value(_ d: LiftDay) -> Double? {
        switch self {
        case .sets: return d.sets.map(Double.init)
        case .working: return d.workS.map(Double.init)
        case .rest: return d.avgRestS.map(Double.init)
        case .recovery: return d.avgDrop60.map(Double.init)
        case .effort: return d.row.strain
        case .duration: return d.row.durationS ?? Double(Swift.max(0, d.row.endTs - d.row.startTs))
        case .avgHr: return d.row.avgHr.map(Double.init)
        case .reps: return d.reps.map(Double.init)
        case .volume: return d.volumeKg
        }
    }

    func format(_ v: Double, effort: EffortScale, units: UnitSystem) -> String {
        switch self {
        case .sets, .reps: return String(Int(v.rounded()))
        case .working, .rest, .duration: return LiveIntervalTracker.clock(Int(v.rounded()))
        case .recovery: return String(localized: "-\(Int(v.rounded())) bpm")
        case .effort: return UnitFormatter.effortDisplay(v, scale: effort)
        case .avgHr: return String(localized: "\(Int(v.rounded())) bpm")
        case .volume:
            let kg = units == .imperial ? v * 2.20462 : v
            return "\(Int(kg.rounded()).formatted()) \(units == .imperial ? "lb" : "kg")"
        }
    }
}

/// Lift days compared by type: push against pull against legs and the rest, and each type over time.
struct LiftDaysView: View {
    let rows: [WorkoutRow]
    @EnvironmentObject private var repo: Repository
    @ObservedObject private var types = StrengthTypeStore.shared
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @State private var days: [LiftDay] = []
    @State private var loaded = false
    @State private var rangeDays = 90
    @State private var focus: StrengthCategory?
    @State private var metric: LiftMetric = .sets
    @State private var detail: LiftDay?

    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }
    private var units: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    private var inRange: [LiftDay] {
        let from = Int(Date().timeIntervalSince1970) - rangeDays * 86_400
        return days.filter { rangeDays == 0 || $0.row.startTs >= from }
    }
    private var present: [StrengthCategory] { types.types.filter { c in inRange.contains { $0.types.contains(c) } } }
    private var focused: StrengthCategory? { focus.flatMap { present.contains($0) ? $0 : nil } ?? present.first }

    var body: some View {
        ScreenScaffold(title: "Lift days") {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                Picker("Range", selection: $rangeDays) {
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                    Text("All").tag(0)
                }
                .pickerStyle(.segmented)
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity)
                } else if present.isEmpty {
                    NoopCard {
                        Text("No typed lift days here yet. Give a strength workout a type (Push, Pull, Legs, Abs, Accessory or your own) in its details or when you edit it, or name its exercises, and it shows up here.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    compareCard
                    trendCard
                    daysCard
                }
            }
        }
        .task(id: repo.refreshSeq) {
            days = await LiftDays.build(rows: rows, repo: repo)
            loaded = true
        }
        .onReceive(WorkoutCategoryStore.shared.$stored.dropFirst().map { _ in () }
            .merge(with: ExerciseCategoryStore.shared.$stored.dropFirst().map { _ in () })
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)) { _ in
            Task { days = await LiftDays.build(rows: rows, repo: repo) }
        }
        .sheet(item: $detail) { d in
            NavigationStack { WorkoutDetailView(row: d.row).environmentObject(repo) }
                .noopSheetPresentation(largeFirst: true)
        }
    }

    private func average(_ m: LiftMetric, _ c: StrengthCategory) -> Double? {
        let v = inRange.filter { $0.types.contains(c) }.compactMap(m.value)
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }

    // MARK: Compare

    private var compareCard: some View {
        let cols = present
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Compare", overline: "Average per day")
            NoopCard {
                ScrollView(.horizontal, showsIndicators: false) {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                        GridRow {
                            Text("")
                            ForEach(cols, id: \.self) { c in StrengthCategoryTag(category: c) }
                        }
                        GridRow {
                            Text("Days").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            ForEach(cols, id: \.self) { c in
                                Text("\(inRange.filter { $0.types.contains(c) }.count)")
                                    .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                            }
                        }
                        ForEach(LiftMetric.allCases) { m in
                            GridRow {
                                Text(m.title).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                                    .lineLimit(1)
                                ForEach(cols, id: \.self) { c in
                                    Text(average(m, c).map { m.format($0, effort: effortScale, units: units) } ?? "–")
                                        .font(StrandFont.captionNumber)
                                        .foregroundStyle(StrandPalette.textPrimary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            Text("A day with more than one type counts in each. Sets, rests and recovery come from the sets timeline. Reps and volume come from the Lift Log.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Trend

    private var trendCard: some View {
        let c = focused
        let series = inRange.filter { d in c.map { d.types.contains($0) } ?? false }
            .compactMap { d in metric.value(d).map { (d.date, $0) } }
            .sorted { $0.0 < $1.0 }
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Over time", overline: "One type, one figure")
            NoopCard(tint: c?.color) {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    typeChooser
                    Menu {
                        ForEach(LiftMetric.allCases) { m in
                            Button { metric = m } label: {
                                if m == metric { Label(m.title, systemImage: "checkmark") } else { Text(m.title) }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(metric.title)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                        }
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    }
                    if series.count >= 2 {
                        Chart {
                            ForEach(series.indices, id: \.self) { i in
                                LineMark(x: .value("Day", series[i].0), y: .value(metric.title, series[i].1))
                                    .foregroundStyle(c?.color ?? StrandPalette.accent)
                                PointMark(x: .value("Day", series[i].0), y: .value(metric.title, series[i].1))
                                    .foregroundStyle(c?.color ?? StrandPalette.accent)
                            }
                        }
                        .chartYAxis {
                            AxisMarks { v in
                                AxisGridLine()
                                AxisValueLabel {
                                    if let d = v.as(Double.self) { Text(metric.format(d, effort: effortScale, units: units)) }
                                }
                            }
                        }
                        .frame(height: 170)
                        if let last = series.last, let prev = series.dropLast().last {
                            Text(deltaLine(last.1, prev.1))
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    } else {
                        Text(series.isEmpty ? "No \(metric.title.lowercased()) for these days yet."
                             : "One day so far. A second shows the trend.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
        }
    }

    private var typeChooser: some View {
        ChipFlow(spacing: 6) {
            ForEach(present, id: \.self) { c in
                let on = c == focused
                Button { focus = c } label: {
                    Text(c.displayName)
                        .font(StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(on ? Color.white : StrandPalette.textSecondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(on ? c.color : StrandPalette.surfaceInset))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func deltaLine(_ now: Double, _ before: Double) -> String {
        let name = focused?.displayName ?? ""
        let diff = now - before
        guard abs(diff) > 0.0001 else { return String(localized: "Same as the \(name) day before.") }
        let sign = diff > 0 ? "+" : "-"
        let mag = metric == .recovery
            ? String(localized: "\(Int(abs(diff).rounded())) bpm")
            : metric.format(abs(diff), effort: effortScale, units: units)
        return String(localized: "Last \(name) day: \(sign)\(mag) on the one before.")
    }

    // MARK: Days

    private var daysCard: some View {
        let c = focused
        let list = inRange.filter { d in c.map { d.types.contains($0) } ?? false }
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader(LocalizedStringKey("\(c?.displayName ?? "") days"), trailing: "\(list.count)")
            NoopCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, d in
                        if i > 0 { Divider().overlay(StrandPalette.hairline.opacity(0.5)) }
                        Button { detail = d } label: { dayRow(d, previous: i + 1 < list.count ? list[i + 1] : nil) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func dayRow(_ d: LiftDay, previous: LiftDay?) -> some View {
        var parts: [String] = []
        if let s = d.sets { parts.append(String(localized: "\(s) sets")) }
        if let r = d.avgRestS { parts.append(String(localized: "rest \(LiveIntervalTracker.clock(r))")) }
        if let v = d.volumeKg { parts.append(LiftMetric.volume.format(v, effort: effortScale, units: units)) }
        let delta: String? = {
            guard let p = previous, let a = metric.value(d), let b = metric.value(p), abs(a - b) > 0.0001 else { return nil }
            let mag = metric == .recovery ? String(localized: "\(Int(abs(a - b).rounded())) bpm")
                : metric.format(abs(a - b), effort: effortScale, units: units)
            return (a > b ? "+" : "-") + mag
        }()
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(d.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                    ForEach(d.types, id: \.self) { StrengthCategoryTag(category: $0) }
                }
                Text(parts.isEmpty ? WorkoutSource.displaySport(d.row.sport) : parts.joined(separator: " · "))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                if !d.exercises.isEmpty {
                    Text(d.exercises.prefix(4).joined(separator: ", ") + (d.exercises.count > 4 ? "…" : ""))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let delta {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(delta).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
                    Text(metric.title.lowercased()).font(.system(size: 9)).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, NoopMetrics.cardPadding)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

/// What the workout calendar shows: everything, one type of lift day, one sport, or days with one
/// exercise.
enum CalendarFilter: Hashable {
    case all
    case type(StrengthCategory)
    case sport(String)
    case exercise(String)

    var label: String {
        switch self {
        case .all: return String(localized: "All")
        case .type(let c): return c.displayName
        case .sport(let s): return WorkoutSource.displaySport(s)
        case .exercise(let e): return e
        }
    }

    var color: Color? { if case .type(let c) = self { return c.color }; return nil }
}

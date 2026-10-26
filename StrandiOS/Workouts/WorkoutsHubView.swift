import SwiftUI
import Combine
import StrandDesign
import StrandAnalytics
import WhoopStore

/// The Workouts tab: what's running now, the day's log, a month of training vs rest days, auto-tracking,
/// and the full history.
struct WorkoutsHubView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var intelligence: IntelligenceEngine
    @AppStorage(WorkoutCalendarPrefs.iconCountKey) private var iconCount = WorkoutCalendarPrefs.defaultIconCount
    @AppStorage(WorkoutCalendarPrefs.priorityKey) private var priorityRaw = ""
    @ObservedObject private var tracker = AutoWorkoutTracker.shared
    @AppStorage(AutoTrackingPrefs.placesEnabledKey) private var placesEnabled = false
    @AppStorage(AutoTrackingPrefs.walkEnabledKey) private var walkEnabled = false
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue

    @State private var rows: [WorkoutRow] = []
    /// Day key → that day's workouts, newest first. Built once per load.
    @State private var byDay: [String: [WorkoutRow]] = [:]
    @State private var rules = RestDayRules.Snapshot.current()
    @State private var trained: [String: [WorkoutRow]] = [:]
    @State private var week = RestDayRules.Week(restDays: 0, trainingStreak: 0, trainedToday: false)
    /// Days run from waking to the next sleep, so the log is "since you last slept".
    @State private var wakeDays = RestDayRules.WakeDays.calendar
    /// A calendar day opened in its own sheet.
    @State private var dayTarget: DayTarget?
    @State private var addTarget: AddTarget?
    @State private var monthStart = MonthMath.startOfMonth(Date())
    @State private var detail: WorkoutDetailTarget?
    /// Lift days, for the calendar's type and exercise filters and the tags on strength rows.
    @State private var liftDays: [LiftDay] = []
    @State private var filter: CalendarFilter = .all
    @ObservedObject private var strengthTypes = StrengthTypeStore.shared
    @ObservedObject private var workoutTypes = WorkoutCategoryStore.shared

    private struct DayTarget: Identifiable { let key: String; var id: String { key } }
    private struct AddTarget: Identifiable { let id = UUID(); let endingAt: Date? }

    private struct WorkoutDetailTarget: Identifiable {
        let row: WorkoutRow
        var id: String { "\(row.startTs)-\(row.source)" }
    }

    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }
    private var priorityList: [String] { WorkoutCalendarPrefs.priority(priorityRaw) }
    /// The day you're in now: since your last sleep.
    private var todayKey: String { wakeDays.currentDayKey() }

    var body: some View {
        ScreenScaffold(title: "Workouts") {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                WorkoutStartControl()
                LiveSessionCard()
                LiveIntervalCard()
                dayLog
                // A tapped day opens in a sheet, so the page never jumps.
                calendarCard { key in dayTarget = DayTarget(key: key) }
                liftDaysCard
                autoTrackingCard
                historyCard
            }
        }
        .task(id: repo.refreshSeq) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)) { _ in reapplyRules() }
        .sheet(item: $dayTarget) { target in
            NavigationStack {
                ScrollView {
                    dayLogCard(target.key, pushDetail: true)
                        .padding(NoopMetrics.space4)
                }
                .background(StrandPalette.surfaceBase)
                .navigationTitle(target.key == todayKey ? String(localized: "Today") : Self.dayTitle(target.key))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dayTarget = nil }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { addTarget = AddTarget(endingAt: endTime(forDay: target.key)) } label: {
                            Label("Add workout", systemImage: "plus")
                        }
                    }
                }
                .sheet(item: $addTarget) { add in addSheet(add) }
            }
            .noopSheetPresentation(largeFirst: false)
        }
        .sheet(item: dayTarget == nil ? $addTarget : .constant(nil)) { add in addSheet(add) }
        .sheet(item: $detail) { target in
            NavigationStack {
                WorkoutDetailView(row: target.row)
                    .environmentObject(repo)
            }
            .noopSheetPresentation(largeFirst: true)
        }
    }

    // MARK: - Data

    private func load() async {
        let loaded = await repo.workoutRows(days: 400)
        let now = Int(Date().timeIntervalSince1970)
        let from = now - 400 * 86_400
        // Main sleeps only (3 h or more), so a nap doesn't start a new day.
        var sleeps = await repo.sleepSessions(from: from, to: now, limit: 1000)
        if sleeps.isEmpty { sleeps = await repo.computedSleepSessions(from: from, to: now, limit: 1000) }
        let wakes = sleeps.filter { $0.endTs - $0.effectiveStartTs >= 3 * 3600 && $0.endTs <= now }.map(\.endTs)
        wakeDays = RestDayRules.WakeDays(wakes: wakes)
        rows = loaded
        var grouped: [String: [WorkoutRow]] = [:]
        for r in loaded {
            grouped[wakeDays.dayKey(r.startTs), default: []].append(r)
        }
        for k in grouped.keys { grouped[k]?.sort { $0.startTs > $1.startTs } }
        byDay = grouped
        reapplyRules(force: true)
        liftDays = await LiftDays.build(rows: loaded, repo: repo)
    }

    // MARK: - Filter

    private var liftDayByStart: [Int: LiftDay] {
        Dictionary(liftDays.map { ($0.row.startTs, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// The day's trained workouts that pass the filter.
    private func matching(_ dayRows: [WorkoutRow]) -> [WorkoutRow] {
        let lifts = liftDayByStart
        switch filter {
        case .all: return dayRows
        case .type(let c):
            return dayRows.filter { r in
                lifts[r.startTs]?.types.contains(c) ?? workoutTypes.categories(startTs: r.startTs).contains(c)
            }
        case .sport(let sp): return dayRows.filter { $0.sport.lowercased() == sp.lowercased() }
        case .exercise(let e):
            return dayRows.filter { r in lifts[r.startTs]?.exercises.contains { $0.lowercased() == e.lowercased() } ?? false }
        }
    }

    private var filterSports: [String] {
        var seen = Set<String>()
        return rows.map(\.sport).filter { seen.insert($0.lowercased()).inserted }.sorted()
    }

    private var filterExercises: [String] {
        var count: [String: (name: String, n: Int)] = [:]
        for d in liftDays { for e in d.exercises { count[e.lowercased(), default: (e, 0)].n += 1 } }
        return count.values.sorted { $0.n > $1.n }.map(\.name)
    }

    private var filterTypes: [StrengthCategory] {
        strengthTypes.types.filter { c in liftDays.contains { $0.types.contains(c) } }
    }

    /// All, then your lift-day types, then a menu for one sport or one exercise.
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterChip(.all)
                ForEach(filterTypes, id: \.self) { filterChip(.type($0)) }
                Menu {
                    if !filterExercises.isEmpty {
                        Section("Exercise") {
                            ForEach(filterExercises.prefix(30), id: \.self) { e in
                                Button(e) { filter = .exercise(e) }
                            }
                        }
                    }
                    Section("Sport") {
                        ForEach(filterSports, id: \.self) { sp in
                            Button(WorkoutSource.displaySport(sp)) { filter = .sport(sp) }
                        }
                    }
                } label: {
                    let specific: Bool = { if case .sport = filter { return true }; if case .exercise = filter { return true }; return false }()
                    HStack(spacing: 4) {
                        Text(specific ? filter.label : String(localized: "Specific"))
                            .lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .font(StrandFont.footnote.weight(.semibold))
                    .foregroundStyle(specific ? Color.white : StrandPalette.textSecondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(specific ? StrandPalette.accent : StrandPalette.surfaceInset))
                }
            }
        }
    }

    private func filterChip(_ f: CalendarFilter) -> some View {
        let on = filter == f
        let tint = f.color ?? StrandPalette.accent
        return Button { filter = f } label: {
            Text(f.label)
                .font(StrandFont.footnote.weight(.semibold))
                .foregroundStyle(on ? Color.white : StrandPalette.textSecondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Capsule().fill(on ? tint : StrandPalette.surfaceInset))
        }
        .buttonStyle(.plain)
    }

    private var liftDaysCard: some View {
        NavigationLink {
            LiftDaysView(rows: rows).environmentObject(repo)
        } label: {
            linkCard(icon: "chart.bar.xaxis", title: "Lift days",
                     subtitle: liftDaysSubtitle)
        }
        .buttonStyle(.plain)
    }

    private var liftDaysSubtitle: String {
        let month = Int(Date().timeIntervalSince1970) - 30 * 86_400
        let recent = liftDays.filter { $0.row.startTs >= month }
        let parts = strengthTypes.types.compactMap { c -> String? in
            let n = recent.filter { $0.types.contains(c) }.count
            return n > 0 ? "\(c.displayName) \(n)" : nil
        }
        return parts.isEmpty ? String(localized: "Compare push, pull, legs and your other lift days.")
            : String(localized: "Last 30 days: ") + parts.joined(separator: " · ")
    }

    private func reapplyRules(force: Bool = false) {
        let now = RestDayRules.Snapshot.current()
        guard force || now != rules else { return }
        rules = now
        trained = RestDayRules.trainingDays(rows, rules: now, days: wakeDays)
        week = RestDayRules.week(rows, rules: now, days: wakeDays)
    }

    /// "Tue Oct 21", or "Today".
    static func dayTitle(_ key: String) -> String {
        guard let d = dayParser.date(from: key) else { return key }
        if Calendar.current.isDateInToday(d) { return String(localized: "Today") }
        if Calendar.current.isDateInYesterday(d) { return String(localized: "Yesterday") }
        return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - Day log

    private var dayLog: some View { dayLogCard(todayKey, pushDetail: false) }

    /// One day's workouts, inline. In the day sheet rows push their detail, on the page they open a sheet.
    private func dayLogCard(_ key: String, pushDetail: Bool) -> some View {
        let dayRows = byDay[key] ?? []
        let isToday = key == todayKey
        return NoopCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(isToday ? String(localized: "Today") : Self.dayTitle(key))
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    if !pushDetail {
                        Button { addTarget = AddTarget(endingAt: nil) } label: {
                            Label("Add", systemImage: "plus")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, NoopMetrics.cardPadding)
                .padding(.top, NoopMetrics.cardPadding)
                .padding(.bottom, NoopMetrics.space2)

                Text(daySummary(dayRows, isToday: isToday))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.horizontal, NoopMetrics.cardPadding)
                    .padding(.bottom, dayRows.isEmpty ? NoopMetrics.cardPadding : NoopMetrics.space2)

                ForEach(Array(dayRows.enumerated()), id: \.offset) { _, row in
                    Divider().overlay(StrandPalette.hairline.opacity(0.5))
                    if pushDetail {
                        NavigationLink {
                            WorkoutDetailView(row: row).environmentObject(repo)
                        } label: { logRowLabel(row) }
                        .buttonStyle(.plain)
                    } else {
                        Button { detail = WorkoutDetailTarget(row: row) } label: { logRowLabel(row) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// A fresh manual workout. Saved, rescored from the strap's heart rate, and the log reloaded.
    private func addSheet(_ add: AddTarget) -> some View {
        ManualWorkoutSheet(editing: nil, endingAt: add.endingAt) { row, _ in
            Task {
                await repo.saveManualWorkout(row, replacing: nil)
                await intelligence.analyzeRecent()
                await load()
            }
        }
    }

    /// Default end for a workout added to a past day: 6 pm that day. Today: now.
    private func endTime(forDay key: String) -> Date? {
        guard key != todayKey, let d = Self.dayParser.date(from: key) else { return nil }
        return Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: d)
    }

    private func daySummary(_ dayRows: [WorkoutRow], isToday: Bool) -> String {
        guard !dayRows.isEmpty else {
            return isToday ? String(localized: "Nothing logged yet.") : String(localized: "No workouts. Rest day.")
        }
        let total = dayRows.reduce(0.0) { $0 + Self.seconds($1) }
        let effort = dayRows.compactMap(\.strain).reduce(0, +)
        let counted = dayRows.filter(rules.isTraining).count
        var parts = [dayRows.count == 1 ? String(localized: "1 workout") : String(localized: "\(dayRows.count) workouts"),
                     Self.duration(total)]
        if effort > 0 {
            parts.append(String(localized: "Effort \(UnitFormatter.effortDisplay(effort, scale: effortScale))"))
        }
        if counted == 0 { parts.append(String(localized: "still a rest day")) }
        return parts.joined(separator: " · ")
    }

    private func logRowLabel(_ row: WorkoutRow) -> some View {
        let counts = rules.isTraining(row)
        return HStack(spacing: 12) {
            WorkoutTypeIcon(workoutType: row.sport, size: 17,
                            color: counts ? StrandPalette.effortColor : StrandPalette.textTertiary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(WorkoutSource.displaySport(row.sport))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    // A strength workout's types, its subcategories.
                    ForEach(liftDayByStart[row.startTs]?.types ?? [], id: \.self) { StrengthCategoryTag(category: $0) }
                }
                Text(rowSubtitle(row, counts: counts))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let s = row.strain {
                Text(UnitFormatter.effortDisplay(s, scale: effortScale))
                    .font(StrandFont.number(15))
                    .foregroundStyle(StrandPalette.effortColor)
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, NoopMetrics.cardPadding)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }

    private func rowSubtitle(_ row: WorkoutRow, counts: Bool) -> String {
        let start = Date(timeIntervalSince1970: TimeInterval(row.startTs))
        let end = Date(timeIntervalSince1970: TimeInterval(row.endTs))
        var parts = ["\(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))",
                     Self.duration(Self.seconds(row))]
        if let hr = row.avgHr { parts.append(String(localized: "\(hr) bpm avg")) }
        if !counts { parts.append(String(localized: "not training")) }
        return parts.joined(separator: " · ")
    }

    static func seconds(_ r: WorkoutRow) -> Double { r.durationS ?? Double(max(0, r.endTs - r.startTs)) }

    static func duration(_ s: Double) -> String {
        let m = Int((s / 60).rounded())
        return m >= 60 ? String(localized: "\(m / 60)h \(m % 60)m") : String(localized: "\(m) min")
    }

    // MARK: - Calendar

    private func calendarCard(onPick: @escaping (String) -> Void) -> some View {
        let keys = MonthMath.dayKeys(in: monthStart).filter { $0 <= todayKey }
        let trainedCount = keys.filter { trained[$0] != nil }.count
        let restCount = keys.filter { trained[$0] == nil && $0 != todayKey }.count
        let matchCount = keys.filter { !matching(byDay[$0] ?? []).isEmpty }.count
        return NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                MonthHeader(monthStart: $monthStart)
                filterBar
                MonthGrid(monthStart: monthStart) { date, key in
                    Button { onPick(key) } label: { dayCell(date: date, key: key) }
                        .buttonStyle(.plain)
                }
                HStack(spacing: NoopMetrics.space3) {
                    legendSwatch(StrandPalette.effortColor.opacity(0.85), "Trained")
                    legendSwatch(StrandPalette.restColor.opacity(0.25), "Rest")
                    Spacer()
                }
                Divider().overlay(StrandPalette.hairline.opacity(0.5))
                HStack {
                    if filter == .all {
                        stat(String(localized: "Rest days, last 7"), "\(week.restDays)")
                        Spacer()
                        stat(String(localized: "Trained this month"), "\(trainedCount)")
                        Spacer()
                        stat(String(localized: "Rest this month"), "\(restCount)")
                    } else {
                        stat(String(localized: "\(filter.label) days this month"), "\(matchCount)")
                        Spacer()
                        stat(String(localized: "Trained this month"), "\(trainedCount)")
                        Spacer()
                        if let last = lastMatchKey {
                            stat(String(localized: "Last \(filter.label)"), Self.dayTitle(last))
                        }
                    }
                }
                settingsLink("Calendar settings") { WorkoutCalendarSettingsView() }
            }
        }
    }

    private func settingsLink<D: View>(_ title: LocalizedStringKey, @ViewBuilder _ dest: @escaping () -> D) -> some View {
        NavigationLink {
            dest()
        } label: {
            HStack {
                Text(title)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.accent)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .buttonStyle(.plain)
    }

    /// The most recent day passing the filter, across every month.
    private var lastMatchKey: String? {
        byDay.keys.filter { !matching(byDay[$0] ?? []).isEmpty }.max()
    }

    private func dayCell(date: Date, key: String) -> some View {
        if filter != .all { return AnyView(filteredDayCell(date: date, key: key)) }
        return AnyView(plainDayCell(date: date, key: key))
    }

    /// With a filter on: days that match are filled in the filter's colour with their workouts' icons;
    /// other trained days are only outlined, so the month still reads.
    private func filteredDayCell(date: Date, key: String) -> some View {
        let hits = matching(byDay[key] ?? [])
        let trainedOther = hits.isEmpty && trained[key] != nil
        let isToday = key == todayKey
        let tint = filter.color ?? StrandPalette.effortColor
        let logos = WorkoutCalendarPrefs.logoSports(hits, priority: priorityList, count: max(1, min(3, iconCount)))
        return VStack(spacing: 3) {
            Text("\(Calendar.current.component(.day, from: date))")
                .font(StrandFont.caption)
                .foregroundStyle(!hits.isEmpty ? StrandPalette.textPrimary : StrandPalette.textTertiary)
            if !logos.isEmpty { logoCluster(logos) } else { Color.clear.frame(width: 4, height: 12) }
        }
        .frame(maxWidth: .infinity, minHeight: iconCount >= 3 ? 58 : 48)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(!hits.isEmpty ? tint.opacity(0.85) : StrandPalette.surfaceInset.opacity(0.3))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isToday ? StrandPalette.accent : (trainedOther ? StrandPalette.hairlineStrong : Color.clear),
                              lineWidth: isToday ? 1.5 : 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.dayTitle(key)) + Text(", ")
            + Text(!hits.isEmpty ? filter.label : String(localized: "no match")))
    }

    private func plainDayCell(date: Date, key: String) -> some View {
        let dayTrained = trained[key]
        let isToday = key == todayKey
        let logos = WorkoutCalendarPrefs.logoSports(dayTrained ?? [], priority: priorityList,
                                                    count: max(1, min(3, iconCount)))
        return VStack(spacing: 3) {
            Text("\(Calendar.current.component(.day, from: date))")
                .font(StrandFont.caption)
                .foregroundStyle(dayTrained != nil ? StrandPalette.textPrimary
                                 : (isToday ? StrandPalette.accent : StrandPalette.textSecondary))
            if !logos.isEmpty {
                logoCluster(logos)
            } else if byDay[key] != nil {
                Circle().fill(StrandPalette.textTertiary).frame(width: 4, height: 4)
            } else {
                Color.clear.frame(width: 4, height: 12)
            }
        }
        .frame(maxWidth: .infinity, minHeight: iconCount >= 3 ? 58 : 48)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(dayTrained != nil ? StrandPalette.effortColor.opacity(0.85)
                      : (isToday ? StrandPalette.surfaceInset.opacity(0.4) : StrandPalette.restColor.opacity(0.25)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isToday ? StrandPalette.accent : Color.clear, lineWidth: 1.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.dayTitle(key)) + Text(", ")
            + Text(dayTrained != nil ? String(localized: "trained") : String(localized: "rest day")))
    }

    /// One logo sits alone; two sit side by side; three make a small triangle. Each gets its own disc so
    /// they stay apart and readable at calendar size.
    @ViewBuilder
    private func logoCluster(_ sports: [String]) -> some View {
        switch sports.count {
        case 1:
            WorkoutTypeIcon(workoutType: sports[0], size: 14, color: StrandPalette.textPrimary)
        case 2:
            HStack(spacing: 3) {
                ForEach(sports, id: \.self) { logoDisc($0, size: 17) }
            }
        default:
            VStack(spacing: 1) {
                HStack(spacing: 2) {
                    logoDisc(sports[0], size: 15)
                    logoDisc(sports[1], size: 15)
                }
                logoDisc(sports[2], size: 15)
            }
        }
    }

    private func logoDisc(_ sport: String, size: CGFloat) -> some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.18))
            WorkoutTypeIcon(workoutType: sport, size: size * 0.6, color: StrandPalette.textPrimary)
        }
        .frame(width: size, height: size)
    }

    private func legendSwatch(_ color: Color, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 12, height: 12)
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            Text(value).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
        }
    }

    // MARK: - Auto-tracking and history links

    private var autoTrackingCard: some View {
        NavigationLink {
            AutoTrackingSettingsView()
        } label: {
            linkCard(icon: "location.circle.fill", title: "Auto-tracking", subtitle: statusLine)
        }
        .buttonStyle(.plain)
    }

    private var statusLine: String {
        guard placesEnabled || walkEnabled else {
            return String(localized: "Off. Pin your gym or rink and workouts start and stop on their own.")
        }
        var parts: [String] = []
        if placesEnabled {
            let n = tracker.places.count
            parts.append(n == 1 ? String(localized: "1 place") : String(localized: "\(n) places"))
        }
        if walkEnabled { parts.append(String(localized: "walks and runs")) }
        var line = String(localized: "On: \(parts.joined(separator: ", ")).")
        if let here = tracker.place(id: tracker.currentPlaceId) {
            line += " " + String(localized: "You're at \(here.name).")
        }
        return line
    }

    private var historyCard: some View {
        NavigationLink(value: TabRoute.workouts) {
            linkCard(icon: "list.bullet.rectangle", title: "All workouts",
                     subtitle: String(localized: "See, edit, rename or delete any workout."))
        }
        .buttonStyle(.plain)
    }

    private func linkCard(icon: String, title: LocalizedStringKey, subtitle: String) -> some View {
        NoopCard {
            HStack(spacing: NoopMetrics.space3) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                    Text(title)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(subtitle)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
        }
    }
}

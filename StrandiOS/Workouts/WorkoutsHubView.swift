import SwiftUI
import Combine
import StrandDesign
import WhoopStore

/// The Workouts tab: what's running now, the day's log, a month of training vs rest days, auto-tracking,
/// and the full history.
struct WorkoutsHubView: View {
    @EnvironmentObject private var repo: Repository
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
    @State private var selectedDay = Repository.localDayKey(Date())
    /// Whether the user picked a day; until then the log follows the current day.
    @State private var pickedDay = false
    @State private var monthStart = MonthMath.startOfMonth(Date())
    @State private var detail: WorkoutDetailTarget?

    private struct WorkoutDetailTarget: Identifiable {
        let row: WorkoutRow
        var id: String { "\(row.startTs)-\(row.source)" }
    }

    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }
    /// The day you're in now: since your last sleep.
    private var todayKey: String { wakeDays.currentDayKey() }

    var body: some View {
        ScreenScaffold(title: "Workouts") {
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    WorkoutStartControl()
                    LiveSessionCard()
                    LiveIntervalCard()
                    dayLog.id("dayLog")
                    calendarCard { key in
                        selectedDay = key
                        pickedDay = true
                        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo("dayLog", anchor: .top) }
                    }
                    autoTrackingCard
                    historyCard
                }
            }
        }
        .task(id: repo.refreshSeq) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)) { _ in reapplyRules() }
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
        if !pickedDay { selectedDay = wakeDays.currentDayKey() }
        rows = loaded
        var grouped: [String: [WorkoutRow]] = [:]
        for r in loaded {
            grouped[wakeDays.dayKey(r.startTs), default: []].append(r)
        }
        for k in grouped.keys { grouped[k]?.sort { $0.startTs > $1.startTs } }
        byDay = grouped
        reapplyRules(force: true)
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

    private var dayLog: some View {
        let dayRows = byDay[selectedDay] ?? []
        let isToday = selectedDay == todayKey
        return NoopCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(isToday ? String(localized: "Today") : Self.dayTitle(selectedDay))
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    if !isToday {
                        Button("Back to today") { selectedDay = todayKey; pickedDay = false }
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.accent)
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

                ForEach(Array(dayRows.enumerated()), id: \.offset) { idx, row in
                    Divider().overlay(StrandPalette.hairline.opacity(0.5))
                    logRow(row)
                }
            }
        }
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

    private func logRow(_ row: WorkoutRow) -> some View {
        let counts = rules.isTraining(row)
        return Button { detail = WorkoutDetailTarget(row: row) } label: {
            HStack(spacing: 12) {
                WorkoutTypeIcon(workoutType: row.sport, size: 17,
                                color: counts ? StrandPalette.effortColor : StrandPalette.textTertiary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(WorkoutSource.displaySport(row.sport))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
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
        .buttonStyle(.plain)
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
        return NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                MonthHeader(monthStart: $monthStart)
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
                    stat(String(localized: "Rest days, last 7"), "\(week.restDays)")
                    Spacer()
                    stat(String(localized: "Trained this month"), "\(trainedCount)")
                    Spacer()
                    stat(String(localized: "Rest this month"), "\(restCount)")
                }
                NavigationLink {
                    RestDayRulesView(historySports: historySports)
                } label: {
                    HStack {
                        Text("What counts as a rest day")
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
        }
    }

    /// Sports from the user's own log, most frequent first.
    private var historySports: [String] {
        var counts: [String: Int] = [:]
        for r in rows { counts[WorkoutSource.displaySport(r.sport), default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }.map(\.key)
    }

    private func dayCell(date: Date, key: String) -> some View {
        let dayTrained = trained[key]
        let isSelected = key == selectedDay
        let isToday = key == todayKey
        let top = dayTrained?.max { ($0.strain ?? 0) < ($1.strain ?? 0) }
        return VStack(spacing: 3) {
            Text("\(Calendar.current.component(.day, from: date))")
                .font(StrandFont.caption)
                .foregroundStyle(dayTrained != nil ? StrandPalette.textPrimary
                                 : (isToday ? StrandPalette.accent : StrandPalette.textSecondary))
            if let top {
                WorkoutTypeIcon(workoutType: top.sport, size: 12, color: StrandPalette.textPrimary)
            } else if byDay[key] != nil {
                Circle().fill(StrandPalette.textTertiary).frame(width: 4, height: 4)
            } else {
                Color.clear.frame(width: 4, height: 12)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(dayTrained != nil ? StrandPalette.effortColor.opacity(0.85)
                      : (isToday ? StrandPalette.surfaceInset.opacity(0.4) : StrandPalette.restColor.opacity(0.25)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? StrandPalette.accent : Color.clear, lineWidth: 2)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.dayTitle(key)) + Text(", ")
            + Text(dayTrained != nil ? String(localized: "trained") : String(localized: "rest day")))
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

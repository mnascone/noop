import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The sleep calendar on its own page (from the Sleep tab's Calendar link).
struct SleepCalendarView: View {
    var body: some View {
        ScrollView {
            SleepCalendarCard(showsSummary: true)
                .padding(NoopMetrics.space4)
        }
        .background(StrandPalette.surfaceBase)
        .navigationTitle("Sleep calendar")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// The colours the sleep calendar runs between, poor to good. Stored as "r,g,b" (0...1).
enum SleepCalendarColors {
    static let poorKey = "noop.sleepCalendar.poorColor"
    static let goodKey = "noop.sleepCalendar.goodColor"
    /// Light blue for a poor night, purple for a good one.
    static let defaultPoor = (r: 0.62, g: 0.84, b: 0.98)
    static let defaultGood = (r: 0.47, g: 0.24, b: 0.82)

    typealias RGB = (r: Double, g: Double, b: Double)

    static func rgb(_ raw: String, fallback: RGB) -> RGB {
        let p = raw.split(separator: ",").compactMap { Double($0) }
        guard p.count == 3 else { return fallback }
        return (p[0], p[1], p[2])
    }

    static func encode(_ c: Color) -> String? {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        #else
        guard let ns = NSColor(c).usingColorSpace(.sRGB) else { return nil }
        let r = ns.redComponent, g = ns.greenComponent, b = ns.blueComponent
        #endif
        func clamp(_ x: CGFloat) -> Double { min(1, max(0, Double(x))) }
        return String(format: "%.3f,%.3f,%.3f", clamp(r), clamp(g), clamp(b))
    }

    /// Where a score sits between poor (40 and under) and good (95 and up).
    static func fraction(_ score: Int) -> Double { min(1, max(0, (Double(score) - 40) / 55)) }

    static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        (a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t)
    }

    static func color(_ c: RGB) -> Color { Color(red: c.r, green: c.g, blue: c.b) }

    /// Readable text on top of a cell of this colour.
    static func ink(_ c: RGB) -> Color {
        (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) > 0.6 ? Color.black.opacity(0.85) : Color.white
    }
}

/// A month of nights: each day shows its sleep score and hours, coloured from poor to good. Tap one for
/// its breakdown. A Sleep tab card, a Today card, and the body of the full calendar page.
struct SleepCalendarCard: View {
    var showsSummary = false
    /// The night shown elsewhere on the screen (wake-day key), ringed in the grid.
    var selectedDay: String? = nil
    /// When set, tapping a night calls this instead of opening its score breakdown.
    var onSelect: ((String) -> Void)? = nil
    /// Just the grid and legend (the night picker sheet).
    var gridOnly = false

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var intelligence: IntelligenceEngine
    @EnvironmentObject private var profile: ProfileStore
    @AppStorage(SleepCalendarColors.poorKey) private var poorRaw = ""
    @AppStorage(SleepCalendarColors.goodKey) private var goodRaw = ""

    @State private var monthStart: Date = MonthMath.startOfMonth(Date())

    private struct Night { let score: Int?; let hours: Double? }

    private var poor: SleepCalendarColors.RGB { SleepCalendarColors.rgb(poorRaw, fallback: SleepCalendarColors.defaultPoor) }
    private var good: SleepCalendarColors.RGB { SleepCalendarColors.rgb(goodRaw, fallback: SleepCalendarColors.defaultGood) }

    /// Scores for the shown month only.
    private func nights(_ keys: Set<String>) -> [String: Night] {
        let inputs = SleepScoreInputs.resolve(intelligence: intelligence, days: repo.days, age: profile.age)
        var out: [String: Night] = [:]
        for d in repo.days where keys.contains(d.day) && (d.totalSleepMin ?? 0) > 0 {
            let score = repo.importedSleep[d.day]?.performancePct
                ?? AnalyticsEngine.Rest.composite(daily: d, needHours: inputs.needHours, consistency: inputs.consistency)
            out[d.day] = Night(score: score.map { Int($0.rounded()) }, hours: d.totalSleepMin.map { $0 / 60 })
        }
        return out
    }

    var body: some View {
        let keys = MonthMath.dayKeys(in: monthStart)
        let data = nights(Set(keys))
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                if !showsSummary {
                    Text("Sleep calendar").strandOverline()
                }
                MonthHeader(monthStart: $monthStart)
                MonthGrid(monthStart: monthStart) { date, key in
                    let night = data[key]
                    if let night, night.score != nil || night.hours != nil {
                        if let onSelect {
                            Button { onSelect(key) } label: {
                                cell(date: date, night: night, selected: key == selectedDay)
                            }
                            .buttonStyle(.plain)
                        } else {
                            NavigationLink {
                                SleepScoreBreakdownView(dayKey: key)
                            } label: {
                                cell(date: date, night: night, selected: key == selectedDay)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        cell(date: date, night: nil, selected: false)
                    }
                }
                legend
                if !gridOnly {
                    if onSelect != nil, let sel = selectedDay {
                        Divider().overlay(StrandPalette.hairline)
                        selectedNight(sel, score: nights([sel])[sel]?.score)
                    }
                    monthSummary(keys, data)
                    monthTrend(keys, data)
                }
            }
        }
        .onAppear { syncMonth() }
        .onChangeCompat(of: selectedDay) { _ in syncMonth() }
    }

    /// Follow the shown night into its month.
    private func syncMonth() {
        guard let sel = selectedDay, let d = MonthMath.date(fromKey: sel) else { return }
        let m = MonthMath.startOfMonth(d)
        if m != monthStart { monthStart = m }
    }

    private func cell(date: Date, night: Night?, selected: Bool) -> some View {
        let isToday = Calendar.current.isDateInToday(date)
        let rgb = night?.score.map { SleepCalendarColors.mix(poor, good, SleepCalendarColors.fraction($0)) }
        let ink = rgb.map(SleepCalendarColors.ink)
        return VStack(spacing: 2) {
            Text("\(Calendar.current.component(.day, from: date))")
                .font(StrandFont.caption)
                .foregroundStyle(ink?.opacity(0.8) ?? (isToday ? StrandPalette.accent : StrandPalette.textSecondary))
            Text(night?.score.map(String.init) ?? " ")
                .font(StrandFont.captionNumber)
                .foregroundStyle(ink ?? StrandPalette.textPrimary)
            Text(night?.hours.map { String(format: "%.1fh", $0) } ?? " ")
                .font(.system(size: 9))
                .foregroundStyle(ink?.opacity(0.75) ?? StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rgb.map(SleepCalendarColors.color) ?? StrandPalette.surfaceInset.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? StrandPalette.textPrimary
                              : (isToday ? StrandPalette.accent : Color.clear),
                              lineWidth: selected ? 2 : 1.5)
        )
    }

    /// The shown night's key figures, one row, with its breakdown one tap away.
    private func selectedNight(_ key: String, score: Int?) -> some View {
        let d = repo.days.last { $0.day == key }
        let eff: Double? = d?.efficiency.map { $0 > 1.5 ? $0 : $0 * 100 }
        let deepRem: Double? = {
            guard let d, d.deepMin != nil || d.remMin != nil else { return nil }
            return (d.deepMin ?? 0) + (d.remMin ?? 0)
        }()
        let date = MonthMath.date(fromKey: key)
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack {
                Text(date.map { $0.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) } ?? key)
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                NavigationLink {
                    SleepScoreBreakdownView(dayKey: key)
                } label: {
                    Label("Breakdown", systemImage: "chevron.right")
                        .labelStyle(.titleOnly)
                        .font(StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
            }
            HStack(alignment: .top, spacing: 0) {
                figure("Score", score.map(String.init))
                figure("Asleep", d?.totalSleepMin.map { Self.hm($0) })
                figure("Efficiency", eff.map { "\(Int($0.rounded()))%" })
                figure("Deep+REM", deepRem.map { Self.hm($0) })
                figure("RHR", d?.restingHr.map(String.init))
                figure("HRV", d?.avgHrv.map { "\(Int($0.rounded()))" })
            }
        }
    }

    private func figure(_ label: String, _ value: String?) -> some View {
        VStack(spacing: 1) {
            Text(value ?? "–")
                .font(StrandFont.captionNumber.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(LocalizedStringKey(label))
                .font(.system(size: 9))
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private static func hm(_ min: Double) -> String {
        let m = Int(min.rounded())
        return "\(m / 60)h\(String(format: "%02d", m % 60))"
    }

    /// This month against the month before: score and sleep, with the direction.
    @ViewBuilder
    private func monthTrend(_ keys: [String], _ data: [String: Night]) -> some View {
        if let prevStart = Calendar.current.date(byAdding: .month, value: -1, to: monthStart) {
            let prevKeys = MonthMath.dayKeys(in: MonthMath.startOfMonth(prevStart))
            let prev = nights(Set(prevKeys))
            let cur = keys.compactMap { data[$0]?.score }
            let old = prevKeys.compactMap { prev[$0]?.score }
            let curH = keys.compactMap { data[$0]?.hours }
            let oldH = prevKeys.compactMap { prev[$0]?.hours }
            if cur.count >= 3, old.count >= 3 {
                let ds = Double(cur.reduce(0, +)) / Double(cur.count) - Double(old.reduce(0, +)) / Double(old.count)
                let dh = (curH.isEmpty || oldH.isEmpty) ? 0
                    : (curH.reduce(0, +) / Double(curH.count) - oldH.reduce(0, +) / Double(oldH.count)) * 60
                HStack(spacing: 6) {
                    Image(systemName: ds >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .foregroundStyle(ds >= 0 ? StrandPalette.recovery100 : StrandPalette.recovery030)
                    Text(String(format: String(localized: "Score %+.0f and sleep %+.0f min a night vs last month"), ds, dh))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: NoopMetrics.space2) {
            Text("Poor").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            LinearGradient(colors: [SleepCalendarColors.color(poor), SleepCalendarColors.color(good)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 8)
                .clipShape(Capsule())
            Text("Good").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            NavigationLink {
                SleepCalendarColorsView()
            } label: {
                Image(systemName: "paintpalette")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Calendar colours")
        }
    }

    private func monthSummary(_ keys: [String], _ data: [String: Night]) -> some View {
        let scores = keys.compactMap { data[$0]?.score }
        let hours = keys.compactMap { data[$0]?.hours }
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Average score").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                Text(scores.isEmpty ? "–" : "\(scores.reduce(0, +) / scores.count)")
                    .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 2) {
                Text("Average sleep").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                Text(hours.isEmpty ? "–" : String(format: "%.1f h", hours.reduce(0, +) / Double(hours.count)))
                    .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 2) {
                Text("Nights").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                Text("\(hours.count)").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            }
        }
    }
}

/// A month grid of recorded nights, coloured by score. Picking one shows that night on the Sleep tab.
struct NightPickerSheet: View {
    let current: String?
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                SleepCalendarCard(selectedDay: current, onSelect: onPick, gridOnly: true)
                    .padding(.horizontal, NoopMetrics.space4)
                    .padding(.top, NoopMetrics.space2)
            }
            .navigationTitle("Pick a night")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }
}

/// Pick the two ends of the sleep calendar's colour scale.
struct SleepCalendarColorsView: View {
    @AppStorage(SleepCalendarColors.poorKey) private var poorRaw = ""
    @AppStorage(SleepCalendarColors.goodKey) private var goodRaw = ""

    private func binding(_ raw: Binding<String>, _ fallback: SleepCalendarColors.RGB) -> Binding<Color> {
        Binding(
            get: { SleepCalendarColors.color(SleepCalendarColors.rgb(raw.wrappedValue, fallback: fallback)) },
            set: { if let s = SleepCalendarColors.encode($0) { raw.wrappedValue = s } })
    }

    var body: some View {
        Form {
            Section {
                ColorPicker("Poor sleep", selection: binding($poorRaw, SleepCalendarColors.defaultPoor),
                            supportsOpacity: false)
                ColorPicker("Good sleep", selection: binding($goodRaw, SleepCalendarColors.defaultGood),
                            supportsOpacity: false)
            } footer: {
                Text("Nights in between blend from one to the other. 40 and under is fully poor, 95 and up fully good.")
            }
            Section {
                Button("Reset to light blue and purple") {
                    poorRaw = ""
                    goodRaw = ""
                }
            }
        }
        .navigationTitle("Calendar colours")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// "October 2026" with previous / next buttons. Next stops at the current month.
struct MonthHeader: View {
    @Binding var monthStart: Date

    var body: some View {
        HStack {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Previous month")
            Spacer()
            Text(monthStart.formatted(.dateTime.month(.wide).year()))
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer()
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .disabled(MonthMath.startOfMonth(Date()) <= monthStart)
                .accessibilityLabel("Next month")
        }
        .buttonStyle(.plain)
        .foregroundStyle(StrandPalette.accent)
    }

    private func step(_ months: Int) {
        if let d = Calendar.current.date(byAdding: .month, value: months, to: monthStart) {
            monthStart = MonthMath.startOfMonth(d)
        }
    }
}

/// A Monday-or-Sunday-first month grid (follows the locale). `cell` gets each date and its day key.
struct MonthGrid<Cell: View>: View {
    let monthStart: Date
    @ViewBuilder let cell: (Date, String) -> Cell

    var body: some View {
        let cal = Calendar.current
        let days = MonthMath.days(in: monthStart)
        let lead = (cal.component(.weekday, from: monthStart) - cal.firstWeekday + 7) % 7
        let symbols = Array(cal.veryShortStandaloneWeekdaySymbols[(cal.firstWeekday - 1)...])
            + Array(cal.veryShortStandaloneWeekdaySymbols[..<(cal.firstWeekday - 1)])
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { _, s in
                Text(s).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            ForEach(0..<lead, id: \.self) { _ in Color.clear.frame(height: 1) }
            ForEach(days, id: \.self) { date in
                if date > Date() {
                    Text("\(cal.component(.day, from: date))")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary.opacity(0.5))
                        .frame(maxWidth: .infinity, minHeight: 52)
                } else {
                    cell(date, Repository.localDayKey(date))
                }
            }
        }
    }
}

/// Month arithmetic shared by the sleep and workout calendars.
@MainActor
enum MonthMath {
    static func startOfMonth(_ d: Date) -> Date {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d
    }

    static func days(in monthStart: Date) -> [Date] {
        let cal = Calendar.current
        guard let range = cal.range(of: .day, in: .month, for: monthStart) else { return [] }
        return range.compactMap { cal.date(byAdding: .day, value: $0 - 1, to: monthStart) }
    }

    static func dayKeys(in monthStart: Date) -> [String] {
        days(in: monthStart).map { Repository.localDayKey($0) }
    }

    /// Local midnight of a "yyyy-MM-dd" key.
    static func date(fromKey key: String) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
}

import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// A month of nights: each day shows its sleep score and hours, colored by score. Tap one for its breakdown.
struct SleepCalendarView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var intelligence: IntelligenceEngine
    @EnvironmentObject private var profile: ProfileStore

    @State private var monthStart: Date = MonthMath.startOfMonth(Date())

    private struct Night { let score: Int?; let hours: Double? }

    /// Scores for every banked day, computed once per data change.
    private var nights: [String: Night] {
        let inputs = SleepScoreInputs.resolve(intelligence: intelligence, days: repo.days, age: profile.age)
        var out: [String: Night] = [:]
        for d in repo.days where (d.totalSleepMin ?? 0) > 0 {
            let score = repo.importedSleep[d.day]?.performancePct
                ?? AnalyticsEngine.Rest.composite(daily: d, needHours: inputs.needHours, consistency: inputs.consistency)
            out[d.day] = Night(score: score.map { Int($0.rounded()) }, hours: d.totalSleepMin.map { $0 / 60 })
        }
        return out
    }

    var body: some View {
        let data = nights
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                MonthHeader(monthStart: $monthStart)
                MonthGrid(monthStart: monthStart) { date, key in
                    let night = data[key]
                    if let night, night.score != nil || night.hours != nil {
                        NavigationLink {
                            SleepScoreBreakdownView(dayKey: key)
                        } label: {
                            cell(date: date, night: night)
                        }
                        .buttonStyle(.plain)
                    } else {
                        cell(date: date, night: nil)
                    }
                }
                legend
                monthSummary(data)
            }
            .padding(NoopMetrics.space4)
        }
        .background(StrandPalette.surfaceBase)
        .navigationTitle("Sleep calendar")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func color(_ score: Int) -> Color {
        switch score {
        case 85...: return StrandPalette.restColor
        case 70..<85: return StrandPalette.restColor.opacity(0.65)
        case 50..<70: return StrandPalette.restColor.opacity(0.38)
        default: return StrandPalette.restColor.opacity(0.18)
        }
    }

    private func cell(date: Date, night: Night?) -> some View {
        let isToday = Calendar.current.isDateInToday(date)
        return VStack(spacing: 2) {
            Text("\(Calendar.current.component(.day, from: date))")
                .font(StrandFont.caption)
                .foregroundStyle(isToday ? StrandPalette.accent : StrandPalette.textSecondary)
            Text(night?.score.map(String.init) ?? " ")
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textPrimary)
            Text(night?.hours.map { String(format: "%.1fh", $0) } ?? " ")
                .font(.system(size: 9))
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(night?.score.map(color) ?? StrandPalette.surfaceInset.opacity(0.4))
        )
    }

    private var legend: some View {
        HStack(spacing: NoopMetrics.space3) {
            ForEach([(85, "85+"), (70, "70–84"), (50, "50–69"), (0, "under 50")], id: \.0) { s, label in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3).fill(color(s)).frame(width: 12, height: 12)
                    Text(LocalizedStringKey(label)).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    private func monthSummary(_ data: [String: Night]) -> some View {
        let keys = MonthMath.dayKeys(in: monthStart)
        let scores = keys.compactMap { data[$0]?.score }
        let hours = keys.compactMap { data[$0]?.hours }
        return NoopCard {
            HStack {
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
}

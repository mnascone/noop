import SwiftUI
import StrandDesign

/// A year of Charge as small month calendars, newest month first, each laid out like a normal calendar
/// (weeks run across, days left to right). Each day is tinted by its Charge.
struct ChargeYearCalendar: View {
    /// Day key (YYYY-MM-DD) → Charge 0...100.
    let scores: [String: Double]
    /// How many months back to show, the current one included.
    let months: Int

    private var monthStarts: [Date] {
        let cal = Calendar.current
        let current = MonthMath.startOfMonth(Date())
        return (0..<max(1, months)).compactMap { cal.date(byAdding: .month, value: -$0, to: current) }
    }

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: NoopMetrics.space3, alignment: .top), count: 3)
        LazyVGrid(columns: columns, alignment: .leading, spacing: NoopMetrics.space3) {
            ForEach(monthStarts, id: \.self) { start in
                miniMonth(start)
            }
        }
    }

    private func miniMonth(_ start: Date) -> some View {
        let cal = Calendar.current
        let days = MonthMath.days(in: start)
        let lead = (cal.component(.weekday, from: start) - cal.firstWeekday + 7) % 7
        let isJanuaryOrCurrent = cal.component(.month, from: start) == 1
            || cal.isDate(start, equalTo: Date(), toGranularity: .month)
        let label = isJanuaryOrCurrent
            ? start.formatted(.dateTime.month(.abbreviated).year(.twoDigits))
            : start.formatted(.dateTime.month(.abbreviated))
        let cells = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
        let today = Date()
        return VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
            LazyVGrid(columns: cells, spacing: 2) {
                ForEach(0..<lead, id: \.self) { _ in Color.clear.aspectRatio(1, contentMode: .fit) }
                ForEach(days, id: \.self) { date in
                    let score = scores[Repository.localDayKey(date)]
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(date > today ? Color.clear
                              : (score.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.surfaceInset.opacity(0.6)))
                        .aspectRatio(1, contentMode: .fit)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilitySummary(start, days: days)))
    }

    private func accessibilitySummary(_ start: Date, days: [Date]) -> String {
        let vals = days.compactMap { scores[Repository.localDayKey($0)] }
        let name = start.formatted(.dateTime.month(.wide).year())
        guard !vals.isEmpty else { return String(localized: "\(name), no Charge recorded") }
        let avg = Int((vals.reduce(0, +) / Double(vals.count)).rounded())
        return String(localized: "\(name), \(vals.count) days, average Charge \(avg)")
    }
}

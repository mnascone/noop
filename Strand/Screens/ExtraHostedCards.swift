import SwiftUI
import StrandDesign
import WhoopStore

/// The Today copies of the Trends, Sleep and Workouts cards added for the customizable Today screen. Each
/// draws the same view its home tab uses.
struct ExtraHostedCardView: View {
    let card: HostedCard
    let effortScale: EffortScale
    @EnvironmentObject private var repo: Repository

    var body: some View {
        switch card {
        case .pacingBoth:
            PacingDialCard(days: repo.days, effortScale: effortScale, mode: .both)
        case .chargeCalendar:
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    Text("Charge calendar").strandOverline()
                    ChargeMonthCalendar(scores: Dictionary(
                        repo.days.compactMap { d in d.recovery.map { (d.day, $0) } },
                        uniquingKeysWith: { _, last in last }))
                }
            }
        case .trainingLoad:
            TrainingLoadCard(days: repo.days)
        case .sleepCalendar:
            SleepCalendarCard()
        case .restWeek:
            RestWeekCard()
        default:
            EmptyView()
        }
    }
}

/// The last 7 days as trained or rest, by the user's rest-day rules.
struct RestWeekCard: View {
    @EnvironmentObject private var repo: Repository
    @State private var rows: [WorkoutRow] = []

    var body: some View {
        let rules = RestDayRules.Snapshot.current()
        let trained = RestDayRules.trainingDays(rows, rules: rules)
        let week = RestDayRules.week(rows, rules: rules)
        let today = Repository.localDayKey(Date())
        let keys = Array(RestDayRules.pastDayKeys(count: 6, todayKey: today).reversed()) + [today]
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("Training and rest").strandOverline()
                HStack(spacing: 0) {
                    ForEach(keys, id: \.self) { key in
                        let did = trained[key] != nil
                        VStack(spacing: 4) {
                            ZStack {
                                Circle()
                                    .fill(did ? StrandPalette.effortColor : StrandPalette.restColor.opacity(0.22))
                                if let sport = trained[key]?.max(by: { ($0.strain ?? 0) < ($1.strain ?? 0) })?.sport {
                                    WorkoutTypeIcon(workoutType: sport, size: 13, color: StrandPalette.surfaceBase)
                                }
                            }
                            .frame(width: 30, height: 30)
                            .overlay(Circle().strokeBorder(key == today ? StrandPalette.accent : Color.clear,
                                                           lineWidth: 1.5))
                            Text(Self.weekday(key))
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                Text(week.restDays == 1
                     ? String(localized: "1 rest day in the last 7.")
                     : String(localized: "\(week.restDays) rest days in the last 7."))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .task(id: repo.refreshSeq) { rows = await repo.workoutRows(days: 70) }
    }

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func weekday(_ key: String) -> String {
        guard let d = parser.date(from: key) else { return "" }
        return d.formatted(.dateTime.weekday(.narrow))
    }
}

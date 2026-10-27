import SwiftUI
import StrandDesign
import WhoopStore

/// How Effort is keeping pace with Charge, each compared with your own recent normal.
///
/// Short term: the last 3 days against the 11 before. Long term: the last 7 days against the 4 weeks
/// before. The overall read leans on the long term once there's enough history for it (70/30), and uses
/// the short term alone until then.
enum PacingMath {
    struct Pacing: Equatable {
        var chargeRecent: Double
        var chargeUsual: Double
        var effortRecent: Double
        var effortUsual: Double
        /// Stress (0-3 scale) recent minus usual, when stress is known.
        var stressDelta: Double?
        /// -1 = Charge far ahead, 0 = in step, +1 = Effort far ahead.
        var balance: Double
    }

    enum State { case recovering, balanced, overreaching }

    static let band = 0.25

    static func state(_ balance: Double) -> State {
        balance <= -band ? .recovering : (balance >= band ? .overreaching : .balanced)
    }

    struct Window {
        let recentDays: Int
        let usualDays: Int
        let minRecent: Int
        let minUsual: Int
        static let short = Window(recentDays: 3, usualDays: 11, minRecent: 2, minUsual: 5)
        static let long = Window(recentDays: 7, usualDays: 28, minRecent: 4, minUsual: 10)
    }

    /// The change in Effort beyond the change in Charge (log ratios), so a 20% rise in Effort with Charge
    /// flat reads the same as Effort flat with Charge down 20%. ±0.35 fills the dial.
    /// `todayEffortFloor`: the hardest workout logged today. Today's Effort comes from the strap's synced
    /// heart rate, which can lag a workout you just saved, so pace counts today as at least that workout
    /// and moves the moment it's logged.
    static func pacing(days: [DailyMetric], todayKey: String, window w: Window,
                       stressByDay: [String: Double] = [:], todayEffortFloor: Double? = nil) -> Pacing? {
        let span = w.recentDays - 1 + w.usualDays
        let past = RestDayRules.pastDayKeys(count: span, todayKey: todayKey)
        guard past.count == span else { return nil }
        let recentKeys = Set([todayKey] + past.prefix(w.recentDays - 1))
        let usualKeys = Set(past.dropFirst(w.recentDays - 1))
        var cR: [Double] = [], cU: [Double] = [], eR: [Double] = [], eU: [Double] = []
        var sR: [Double] = [], sU: [Double] = []
        var sawToday = false
        for d in days {
            if recentKeys.contains(d.day) {
                if let c = d.recovery { cR.append(c) }
                if d.day == todayKey {
                    sawToday = true
                    if let e = Self.larger(d.strain, todayEffortFloor) { eR.append(e) }
                } else if let e = d.strain {
                    eR.append(e)
                }
                if let st = stressByDay[d.day] { sR.append(st) }
            } else if usualKeys.contains(d.day) {
                if let c = d.recovery { cU.append(c) }
                if let e = d.strain { eU.append(e) }
                if let st = stressByDay[d.day] { sU.append(st) }
            }
        }
        if !sawToday, let f = todayEffortFloor { eR.append(f) }
        guard cR.count >= w.minRecent, eR.count >= w.minRecent, cU.count >= w.minUsual, eU.count >= w.minUsual
        else { return nil }
        func mean(_ a: [Double]) -> Double { a.reduce(0, +) / Double(a.count) }
        let p = (mean(cR), mean(cU), mean(eR), mean(eU))
        guard p.0 > 0, p.1 > 0 else { return nil }
        // +5 keeps a near-zero Effort stretch from swinging the ratio wildly.
        var s = log((p.2 + 5) / (p.3 + 5)) - log(p.0 / p.1)
        // Stress (0-3) above your usual adds load the way extra Effort does: one point counts like ~15%
        // more Effort.
        var stressDelta: Double?
        if !sR.isEmpty, sU.count >= max(3, w.minUsual / 2) {
            let d = mean(sR) - mean(sU)
            stressDelta = d
            s += 0.15 * d
        }
        return Pacing(chargeRecent: p.0, chargeUsual: p.1, effortRecent: p.2, effortUsual: p.3,
                      stressDelta: stressDelta, balance: min(1, max(-1, s / 0.35)))
    }

    static func larger(_ a: Double?, _ b: Double?) -> Double? {
        switch (a, b) {
        case let (x?, y?): return Swift.max(x, y)
        default: return a ?? b
        }
    }

    /// The hardest Effort among workouts that started today (local day), or nil.
    static func todayEffortFloor(_ rows: [WorkoutRow], todayKey: String) -> Double? {
        rows.filter { Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval($0.startTs))) == todayKey }
            .compactMap(\.strain).max()
    }

    /// Long term weighted 70/30 over short term when it exists, else the short term alone.
    static func overall(short: Pacing?, long: Pacing?) -> Double? {
        if let long { return 0.7 * long.balance + 0.3 * (short?.balance ?? long.balance) }
        return short?.balance
    }
}

/// Pace and stress side by side, as two open rings in the style of the Today hero rings.
///
/// Pace fills out from the top: left toward green when Charge is ahead of Effort, right toward red when
/// Effort is ahead (long term weighted more once there's enough history, short term until then). Stress
/// is the shared `StressNow` reading, always labelled with where it came from; tapping it opens the
/// Stress screen, which can take a fresh measurement. Today and Performance show the same card.
struct PacingDialCard: View {
    enum Mode { case short, both }

    let days: [DailyMetric]
    let effortScale: EffortScale
    var mode: Mode = .both
    /// Tapping the pace side opens its breakdown, which offers this as a way on to the long-term trends.
    /// The stress side opens the Stress screen.
    var onOpen: (() -> Void)? = nil

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var repo: Repository
    @State private var showStress = false
    @State private var showPace = false
    /// The hardest workout logged today, so pace moves as soon as one is saved.
    @State private var todayFloor: Double?

    static let ringDiameter: CGFloat = 84

    /// Daily stress (0-3) from resting HR and HRV against your own baseline, plus any imported values.
    private var stressByDay: [String: Double] { Self.stressByDay(days) }

    static func stressByDay(_ days: [DailyMetric]) -> [String: Double] {
        guard let m = StressModel(days: days, stored: []) else { return [:] }
        return Dictionary(m.fullTrend.map { (Self.utcDay.string(from: $0.date), $0.value) },
                          uniquingKeysWith: { _, last in last })
    }

    private static let utcDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        let today = Repository.localDayKey(Date())
        let stress = stressByDay
        let short = PacingMath.pacing(days: days, todayKey: today, window: .short, stressByDay: stress,
                                      todayEffortFloor: todayFloor)
        let long = PacingMath.pacing(days: days, todayKey: today, window: .long, stressByDay: stress,
                                     todayEffortFloor: todayFloor)
        let overall = PacingMath.overall(short: short, long: long)
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(alignment: .top, spacing: 0) {
                    paceColumn(overall)
                        .contentShape(Rectangle())
                        .onTapGesture { showPace = true }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint(Text("Shows what's driving your pace"))
                    Rectangle()
                        .fill(StrandPalette.hairline.opacity(0.6))
                        .frame(width: 1, height: Self.ringDiameter)
                        .padding(.top, 4)
                    StressNowColumn(diameter: Self.ringDiameter) { showStress = true }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .onAppear { StressNow.shared.attach(model: model) }
        // Also on a workout just saved: its row may still be landing in the store, so it counts directly.
        .task(id: "\(repo.refreshSeq)-\(model.lastWorkout?.startTs ?? 0)") {
            let key = Repository.localDayKey(Date())
            var rows = await repo.workoutRows(days: 2)
            if let w = model.lastWorkout { rows.append(w) }
            todayFloor = PacingMath.todayEffortFloor(rows, todayKey: key)
            await StressNow.shared.refreshStored(repo: repo)
        }
        .sheet(isPresented: $showPace) {
            NavigationStack {
                PaceBreakdownView(days: days, effortScale: effortScale, todayEffortFloor: todayFloor,
                                  onOpenTrends: openTrendsFromPace)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showPace = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showStress) {
            NavigationStack {
                StressView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showStress = false }
                        }
                    }
            }
        }
    }

    /// Close the breakdown, then go on to the trends once the sheet has gone.
    private var openTrendsFromPace: (() -> Void)? {
        guard let onOpen else { return nil }
        return {
            showPace = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { onOpen() }
        }
    }

    private func paceColumn(_ overall: Double?) -> some View {
        let color = overall.map(Self.stateColor) ?? StrandPalette.textTertiary
        return VStack(spacing: 4) {
            ArcGauge(from: 0.5, to: overall.map { ($0 + 1) / 2 } ?? 0.5, color: color,
                     diameter: Self.ringDiameter, tick: 0.5) {
                Text(overall.map(Self.stateWord) ?? "–")
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            Text("Pace").font(StrandFont.subhead.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Pace"))
        .accessibilityValue(Text(overall.map(Self.stateWord) ?? String(localized: "No data yet")))
    }

    /// Today, beside the week: the numbers the rings above show, so the verdict can't advise against
    /// them. Pace itself is a 7 against 28 day comparison; on a bad day the week can still be light.
    struct Today: Equatable {
        var charge: Double?
        var sleepHours: Double?
        var stressHigh = false

        /// Charge in the red (under 34), stress High, or under 6 hours' sleep: a day to go easy whatever
        /// the week says.
        var low: Bool { (charge.map { $0 < 34 } ?? false) || stressHigh || (sleepHours.map { $0 < 6 } ?? false) }

        /// "today's Charge is 26, stress is high and you slept 5.1 h", the reasons that apply.
        var reasons: String {
            var r: [String] = []
            if let c = charge, c < 34 { r.append(String(localized: "today's Charge is \(Int(c.rounded()))")) }
            if stressHigh { r.append(String(localized: "your stress level is high")) }
            if let h = sleepHours, h < 6 { r.append(String(localized: "you slept \(h.formatted(.number.precision(.fractionLength(1)))) h")) }
            return ListFormatter.localizedString(byJoining: r)
        }
    }

    /// Today from the same sources as the rings: today's Charge and sleep, and the stress ring's reading.
    @MainActor
    static func today(_ days: [DailyMetric]) -> Today {
        let key = Repository.localDayKey(Date())
        let d = days.first { $0.day == key }
        let stress = StressNow.shared.reading().map { $0.isCurrent && !$0.active && StressNow.band($0.value) == .high } ?? false
        return Today(charge: d?.recovery, sleepHours: d?.totalSleepMin.map { $0 / 60 }, stressHigh: stress)
    }

    /// The week's figures, labelled as the week's so they don't read as today's: "7-day avg vs usual:
    /// Effort 60.7 vs 61.4 · Charge 49 vs 42 · stress lower (high today)".
    static func detail(_ p: PacingMath.Pacing, effortScale: EffortScale, today: Today? = nil, long: Bool = true) -> String {
        var parts = [
            String(localized: "Effort \(UnitFormatter.effortDisplay(p.effortRecent, scale: effortScale)) vs \(UnitFormatter.effortDisplay(p.effortUsual, scale: effortScale))"),
            String(localized: "Charge \(Int(p.chargeRecent.rounded())) vs \(Int(p.chargeUsual.rounded()))"),
        ]
        if let d = p.stressDelta, abs(d) >= 0.2 {
            var word = d > 0 ? String(localized: "stress higher") : String(localized: "stress lower")
            if d < 0, today?.stressHigh == true { word += " " + String(localized: "(high today)") }
            parts.append(word)
        }
        let head = long ? String(localized: "7-day average vs your usual: ") : String(localized: "3-day average vs your usual: ")
        return head + parts.joined(separator: " · ")
    }

    /// The week's load against recovery: light, on pace, or heavy. ("Under" read as under-recovered.)
    static func stateWord(_ balance: Double) -> String {
        switch PacingMath.state(balance) {
        case .recovering: return String(localized: "Light")
        case .balanced: return String(localized: "On pace")
        case .overreaching: return String(localized: "Heavy")
        }
    }

    /// Green at the easy end, red at the hard end.
    static func stateColor(_ balance: Double) -> Color {
        StrandPalette.recoveryColor((1 - (balance + 1) / 2) * 100)
    }

    /// The verdict, the week's pace with today's state: a light week never says "push" on a day the
    /// rings say rest.
    static func compactLine(_ balance: Double, today: Today? = nil) -> String {
        if let t = today, t.low {
            let why = t.reasons
            switch PacingMath.state(balance) {
            case .recovering:
                return String(localized: "Your week has been lighter than usual, but \(why). Rest today. The room to push is for when Charge is back up.")
            case .balanced:
                return String(localized: "Your week's load is in step with recovery, but \(why). Keep today easy.")
            case .overreaching:
                return String(localized: "Load is outrunning recovery and \(why). Rest today.")
            }
        }
        switch PacingMath.state(balance) {
        case .recovering: return String(localized: "This week you're recovering faster than you're loading. Room to push.")
        case .balanced: return String(localized: "Load matches what your Charge and stress can carry.")
        case .overreaching: return String(localized: "Load is outrunning recovery. Ease off for a day or two.")
        }
    }
}

/// The stress ring: the stress level now (0-100), its band, and where it came from ("Live", "Now",
/// "At 2:41 PM"). Tapping calls `onOpen`.
struct StressNowColumn: View {
    var diameter: CGFloat
    var onOpen: () -> Void
    @ObservedObject private var stress = StressNow.shared

    var body: some View {
        // Re-read every second while measuring (for the countdown), else often enough for a reading to
        // age out of "live" on time.
        TimelineView(.periodic(from: .now, by: stress.measureEnd != nil ? 1 : 10)) { ctx in
            let r = stress.reading()
            Button(action: onOpen) {
                VStack(spacing: 4) {
                    StressRing(reading: r, diameter: diameter)
                    Text("Stress level").font(StrandFont.subhead.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                    caption(r, now: ctx.date)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text("Opens Stress, where you can measure now"))
        }
    }

    @ViewBuilder
    private func caption(_ r: StressNow.Reading?, now: Date) -> some View {
        if let end = stress.measureEnd {
            let left = max(0, Int(end.timeIntervalSince(now).rounded()))
            Text(String(localized: "Measuring · \(left)s"))
                .font(StrandFont.caption.weight(.semibold))
                .foregroundStyle(StrandPalette.accent)
                .monospacedDigit()
        } else if let r {
            HStack(spacing: 4) {
                if r.kind == .live {
                    Circle().fill(StrandPalette.statusPositive).frame(width: 6, height: 6)
                }
                Text(StressNow.label(r.kind))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
            }
        } else {
            Text("Tap to measure").font(StrandFont.caption).foregroundStyle(StrandPalette.accent)
        }
    }
}

/// The ring itself: fills to the level, coloured by its band (blue rest, deepening orange for low, medium
/// and high), with the number and band in the middle. "Active" while moving, where heart rate and HRV say
/// nothing about stress.
struct StressRing: View {
    let reading: StressNow.Reading?
    var diameter: CGFloat = 84

    var body: some View {
        let shown = reading.flatMap { $0.active ? nil : $0 }
        ArcGauge(to: shown.map { $0.value / 100 } ?? 0,
                 color: shown.map { StressNow.color($0.value) } ?? StrandPalette.textTertiary,
                 diameter: diameter, lineWidth: diameter >= 80 ? 8 : 7) {
            VStack(spacing: 0) {
                if reading?.active == true {
                    Text("Active")
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                } else {
                    Text(shown.map { "\(Int($0.value.rounded()))" } ?? "–")
                        .font(StrandFont.rounded(diameter * 0.3, weight: .bold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .monospacedDigit()
                    if let s = shown {
                        Text(StressNow.band(s.value).title)
                            .font(StrandFont.caption.weight(.semibold))
                            .foregroundStyle(StressNow.color(s.value))
                    }
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Stress"))
        .accessibilityValue(Text(spoken))
    }

    private var spoken: String {
        guard let r = reading else { return String(localized: "No data yet") }
        if r.active { return String(localized: "Active") }
        let band = StressNow.band(r.value).title
        return "\(Int(r.value.rounded())), \(band), \(StressNow.label(r.kind))"
    }
}

import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Nutrition against training, from the food log in Apple Health (MacroFactor and similar apps write
/// there): glycogen, protein, energy balance, today so far, and the coach's read when it's set up.
struct FuelingCard: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore

    @State private var days: [FuelingCheck.Day] = []
    @State private var weightKg: Double?
    @State private var loaded = false
    @State private var link: NutritionHealthLink.Status = .unavailable
    @State private var connecting = false
    @State private var refreshedOnce = false

    private var weight: Double { weightKg ?? profile.weightKg }
    private var result: FuelingCheck.Result? { FuelingCheck.evaluate(days, weightKg: weight) }
    private var today: FuelingCheck.Day? {
        days.last.flatMap { $0.day == Repository.localDayKey(Date()) ? $0 : nil }
    }

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                SectionHeader("Fueling", overline: "Nutrition", trailing: String(localized: "Apple Health"))
                if let r = result {
                    if let g = r.glycogen {
                        line(icon: "bolt.fill", title: String(localized: "Glycogen"), status: g.status,
                             word: Self.glycogenWord(g.status),
                             detail: String(localized: "\(Int(g.actual)) g carbs on \(Self.dayName(r.day)). That day's load wants about \(Int(g.target)) g (\(Self.num(r.carbsPerKgTarget ?? 0)) g/kg)."))
                    }
                    if let p = r.protein {
                        line(icon: "fork.knife", title: String(localized: "Protein"), status: p.status,
                             word: Self.proteinWord(p.status),
                             detail: String(localized: "\(Int(p.actual)) g, \(Self.num(r.proteinPerKg ?? 0)) g/kg. Aim for about \(Int(p.target)) g."))
                    }
                    if let bal = r.energyBalanceKcal {
                        line(icon: "flame.fill", title: String(localized: "Energy"),
                             status: abs(bal) < 250 ? .good : (bal < -750 ? .low : .close),
                             word: bal < -100 ? String(localized: "Deficit") : (bal > 100 ? String(localized: "Surplus") : String(localized: "Even")),
                             detail: String(localized: "Averaging \(Int(abs(bal).rounded())) kcal \(bal < 0 ? String(localized: "under") : String(localized: "over")) what you burn across \(r.loggedDays) logged days."))
                    }
                    if let t = today, (t.kcal ?? 0) > 0 {
                        todaySoFar(t)
                    }
                    FuelingCoachRead(result: r, today: today, weightKg: weight)
                } else if loaded {
                    emptyState
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
        }
        .task(id: repo.refreshSeq) {
            link = NutritionHealthLink.status()
            await load()
            // Connected but nothing read yet: pull from Health once now instead of waiting for the next
            // background pass (and pick up the nutrition permission if it hasn't been asked yet).
            if result == nil, link == .connected, !refreshedOnce {
                refreshedOnce = true
                await NutritionHealthLink.refresh()
                await load()
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch link {
        case .notConnected:
            note("Connect Apple Health so NOOP can read the calories and macros MacroFactor logs there.")
            Button {
                connecting = true
                Task {
                    await NutritionHealthLink.connect()
                    link = NutritionHealthLink.status()
                    await load()
                    connecting = false
                }
            } label: {
                Label(connecting ? "Connecting..." : "Connect Apple Health", systemImage: "heart.fill")
                    .font(StrandFont.subhead.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(StrandPalette.accent)
            .disabled(connecting)
        case .denied:
            note("NOOP can't read Apple Health. In the Health app, open your profile, then Apps, then NOOP, and allow Dietary Energy, Protein, Carbohydrates and Total Fat.")
        case .noHealthKit:
            note("This install can't reach Apple Health: it was signed without the HealthKit permission, which is what free Apple ID sideloading does. Re-sign it with a paid developer account, or send the totals with a Shortcut:")
            shortcutSteps
        case .connected:
            note("Apple Health has no food logged in the last week. In MacroFactor, turn on its Apple Health integration so it writes your calories and macros there, then reopen this.")
            Button {
                Task { await NutritionHealthLink.refresh(); await load() }
            } label: {
                Label("Check again", systemImage: "arrow.clockwise").font(StrandFont.subhead)
            }
            .buttonStyle(.bordered)
        case .unavailable:
            note("No Apple Health on this device. Nutrition can come in through the Shortcut import:")
            shortcutSteps
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The Shortcut that sends one day's totals: four Health sums into an N line, Base64, open the link.
    private var shortcutSteps: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(Self.shortcutLines.enumerated()), id: \.offset) { i, line in
                HStack(alignment: .top, spacing: 6) {
                    Text("\(i + 1).").font(StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                    Text(line).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    static let shortcutLines: [LocalizedStringKey] = [
        "In Shortcuts, add Find Health Samples: Dietary Energy, start date is today. Then Calculate Statistics: Sum.",
        "Do the same for Protein, Carbohydrates and Total Fat.",
        "Add a Text action: N,(Current Date as yyyy-MM-dd),(energy),(protein),(carbs),(fat).",
        "Base64 Encode the text, then Open URL: noop://import-health?v=1&payload=(Base64 result).",
        "Make it a personal automation each evening so it runs on its own.",
    ]

    private func load() async {
        async let kcalA = repo.series(key: NutritionKeys.kcal, source: "apple-health", days: 9)
        async let proteinA = repo.series(key: NutritionKeys.protein, source: "apple-health", days: 9)
        async let carbsA = repo.series(key: NutritionKeys.carbs, source: "apple-health", days: 9)
        async let fatA = repo.series(key: NutritionKeys.fat, source: "apple-health", days: 9)
        async let activeA = repo.series(key: "active_kcal", source: "apple-health", days: 9)
        async let basalA = repo.series(key: "basal_kcal", source: "apple-health", days: 9)
        async let weightA = repo.series(key: "weight", source: "apple-health", days: 60)
        func map(_ s: [(day: String, value: Double)]) -> [String: Double] {
            Dictionary(s.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        }
        let kcal = map(await kcalA), protein = map(await proteinA), carbs = map(await carbsA)
        let fat = map(await fatA), active = map(await activeA), basal = map(await basalA)
        weightKg = (await weightA).last?.value
        let byDay = Dictionary(repo.days.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        let todayKey = Repository.localDayKey(Date())
        let keys = Array(RestDayRules.pastDayKeys(count: 7, todayKey: todayKey).reversed()) + [todayKey]
        // Burn: Apple Health basal + active when present, else the strap's active estimate on top of a
        // rough resting burn (22 kcal per kg).
        let restingGuess = 22 * (weightKg ?? profile.weightKg)
        days = keys.map { k in
            let strapActive = byDay[k]?.activeKcalEst
            let burned: Double? = {
                if let b = basal[k], let a = active[k] { return b + a }
                if let a = active[k] ?? strapActive { return (basal[k] ?? restingGuess) + a }
                return nil
            }()
            return FuelingCheck.Day(day: k, kcal: kcal[k], proteinG: protein[k], carbsG: carbs[k], fatG: fat[k],
                                    burnedKcal: burned, effort: byDay[k]?.strain)
        }
        loaded = true
    }

    private func line(icon: String, title: String, status: FuelingCheck.Status, word: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: NoopMetrics.space3) {
            Image(systemName: icon)
                .font(StrandFont.subhead)
                .foregroundStyle(Self.color(status))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(StrandFont.subhead.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Text(word)
                        .font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(Self.color(status))
                }
                Text(detail)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func todaySoFar(_ t: FuelingCheck.Day) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Today so far").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            HStack {
                chip("\(Int(t.kcal ?? 0))", "kcal")
                chip("\(Int(t.proteinG ?? 0))", "protein g")
                chip("\(Int(t.carbsG ?? 0))", "carbs g")
                chip("\(Int(t.fatG ?? 0))", "fat g")
            }
        }
    }

    private func chip(_ value: String, _ label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func color(_ s: FuelingCheck.Status) -> Color {
        switch s {
        case .good: return StrandPalette.statusPositive
        case .close: return StrandPalette.statusWarning
        case .low: return StrandPalette.statusCritical
        case .high: return StrandPalette.statusWarning
        }
    }

    static func glycogenWord(_ s: FuelingCheck.Status) -> String {
        switch s {
        case .good, .high: return String(localized: "Refilled")
        case .close: return String(localized: "Mostly refilled")
        case .low: return String(localized: "Running low")
        }
    }

    static func proteinWord(_ s: FuelingCheck.Status) -> String {
        switch s {
        case .good, .high: return String(localized: "Enough")
        case .close: return String(localized: "A bit short")
        case .low: return String(localized: "Short")
        }
    }

    static func num(_ x: Double) -> String { String(format: "%.1f", x) }

    static func dayName(_ key: String) -> String { WorkoutsDayName.name(key) }
}

/// Day names for nutrition copy ("yesterday", "Tue").
enum WorkoutsDayName {
    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func name(_ key: String) -> String {
        guard let d = parser.date(from: key) else { return key }
        if Calendar.current.isDateInToday(d) { return String(localized: "today") }
        if Calendar.current.isDateInYesterday(d) { return String(localized: "yesterday") }
        return d.formatted(.dateTime.weekday(.abbreviated))
    }
}

/// The coach's read on fueling, asked once per day and set of intake numbers. Its own view so only it
/// observes the coach.
struct FuelingCoachRead: View {
    let result: FuelingCheck.Result
    let today: FuelingCheck.Day?
    let weightKg: Double
    @EnvironmentObject private var coach: AICoachEngine
    @State private var text: String?
    @State private var loading = false

    private static let cacheKey = "noop.fuelingRead.cache"

    private var key: String {
        let g = result.glycogen.map { Int($0.actual / 25) } ?? -1
        let p = result.protein.map { Int($0.actual / 10) } ?? -1
        let t = today.map { "\(Int(($0.kcal ?? 0) / 200))|\(Int(($0.proteinG ?? 0) / 20))" } ?? "-"
        return "\(result.day)|\(g)|\(p)|\(Int((result.energyBalanceKcal ?? 0) / 150))|\(t)"
    }

    var body: some View {
        Group {
            if let text {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Coach's read").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    Text(DailyRecommendation.styled(text))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            } else if loading {
                Text("Asking your coach...").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            } else if !coach.canRecommend {
                Text("Set up the coach for a personal read on this.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .task(id: "\(key)|\(coach.canRecommend)") { await ask() }
    }

    private func ask() async {
        if let cached = UserDefaults.standard.dictionary(forKey: Self.cacheKey),
           cached["key"] as? String == key, let t = cached["text"] as? String {
            text = t
            return
        }
        guard coach.canRecommend, !loading else { return }
        loading = true
        defer { loading = false }
        var lines = ["FUELING CHECK (NOOP's rule-based read; targets are sports-nutrition guides):"]
        lines.append("  Body weight: \(Int(weightKg.rounded())) kg")
        lines.append("  Judged day: \(result.day)")
        if let g = result.glycogen {
            lines.append("  Carbs \(Int(g.actual)) g vs about \(Int(g.target)) g for that day's load (\(g.status.rawValue))")
        }
        if let p = result.protein {
            lines.append("  Protein \(Int(p.actual)) g vs about \(Int(p.target)) g (\(p.status.rawValue))")
        }
        if let b = result.energyBalanceKcal {
            lines.append("  Average energy balance over \(result.loggedDays) logged days: \(Int(b.rounded())) kcal/day")
        }
        if let t = today {
            lines.append("  Today so far: \(Int(t.kcal ?? 0)) kcal, protein \(Int(t.proteinG ?? 0)) g, carbs \(Int(t.carbsG ?? 0)) g, fat \(Int(t.fatG ?? 0)) g")
        }
        guard let reply = await coach.generateFuelingRead(extra: lines.joined(separator: "\n")) else { return }
        UserDefaults.standard.set(["key": key, "text": reply], forKey: Self.cacheKey)
        text = reply
    }
}

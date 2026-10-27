import Foundation
import Combine
import StrandAnalytics
import WhoopProtocol
import WhoopStore
#if os(iOS)
import CoreMotion
#endif

/// One day of the all-day stress level, as stored: its 3-minute epochs and the baseline they were scored
/// against. A day reads back exactly as it was shown.
struct StressLevelDay: Codable, Equatable, Sendable {
    /// Local day, "yyyy-MM-dd".
    let day: String
    var baseline: StressLevel.Baseline
    /// A finished day: kept as it is. Today is never frozen.
    var frozen: Bool
    var epochs: [StressLevel.Epoch]
    var computedAt: Int
    /// Which scoring made it. A finished day from an older scoring is scored again.
    var version: Int? = nil
    static let currentVersion = 3

    var summary: StressLevel.Summary { StressLevel.summary(epochs) }
    var measured: [StressLevel.Epoch] { epochs.filter { $0.state == .measured } }
}

/// Days of stress level on disk, one JSON file per local day. Kept out of the database so nothing that
/// rewrites synced rows can touch them.
enum StressLevelStore {
    private static var dir: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let d = base.appendingPathComponent("noop-stress", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func load(_ day: String) -> StressLevelDay? {
        guard let url = dir?.appendingPathComponent("\(day).json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StressLevelDay.self, from: data)
    }

    static func save(_ d: StressLevelDay) {
        guard let url = dir?.appendingPathComponent("\(d.day).json"), let data = try? JSONEncoder().encode(d) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// The all-day stress level, for every surface that shows stress: worked out from the strap's stored heart
/// rate, beats and motion every 3 minutes and stored per day. Today keeps updating as data syncs; a finished
/// day is kept as it was. Live heart rate and beats score the
/// current stretch the same way, against the same baseline.
@MainActor
final class StressLevelService: ObservableObject {
    static let shared = StressLevelService()

    @Published private(set) var today: StressLevelDay?
    /// Past days, newest first, for the week view.
    @Published private(set) var recent: [StressLevelDay] = []

    /// The workout running now, if any: activity, not stress, from its start.
    var activeWorkoutStart: Int?

    /// Writes a line to the app log (set by `StressNow`).
    var log: ((String) -> Void)?

    private var lastFingerprint: String?
    private var refreshing = false
    private var lastDiagnosis: String?
    /// What made today's activity, from the last scoring: for the log.
    private static var diagnosis: String?

    private init() {
        today = StressLevelStore.load(StressLevelStore.dayKey(Date()))
    }

    // MARK: Reading

    /// The newest measured epoch, with when it was.
    var latest: StressLevel.Epoch? { today?.epochs.last { $0.state == .measured } }

    /// The state of the newest epoch with heart rate: activity shows as activity, not as an old number.
    var latestState: StressLevel.Epoch? { today?.epochs.last { $0.state != .noData } }

    var baseline: StressLevel.Baseline? { today?.baseline }

    // MARK: Updating

    /// Score today from what's stored. Cheap when nothing changed: a heart-rate fingerprint gates the reads.
    func refresh(repo: Repository, force: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let now = Date()
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        let from = Int(start.timeIntervalSince1970), to = Int(now.timeIntervalSince1970)
        let key = StressLevelStore.dayKey(now)
        let fp = await repo.hrFingerprintUnion(from: from, to: to)
        let workouts = await repo.workoutRows(days: 2)
        let fpKey = fp + "|\(workouts.count)|\(activeWorkoutStart ?? 0)|\(to / StressLevel.epochSeconds)"
        if !force, fpKey == lastFingerprint, today?.day == key { return }
        lastFingerprint = fpKey
        let stored = StressLevelStore.load(key)
        // The day's first scoring (or the first after the scoring changed): score the days before it
        // first, so today's calm level can come from your recent days rather than from today alone.
        if stored == nil || stored?.version != StressLevelDay.currentVersion {
            await ensureHistory(repo: repo, days: 6)
        }
        guard let day = await Self.score(day: key, from: from, to: to, repo: repo, workouts: workouts,
                                         stored: stored, activeSince: activeWorkoutStart) else { return }
        StressLevelStore.save(day)
        today = day
        if let d = Self.diagnosis, d != lastDiagnosis {
            lastDiagnosis = d
            log?("stress: \(d)")
        }
    }

    /// Make sure the last `days` days are scored and stored (for the week view), oldest first so each can
    /// use the ones before it as its baseline.
    func ensureHistory(repo: Repository, days: Int = 7) async {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        var out: [StressLevelDay] = []
        let workouts = await repo.workoutRows(days: days + 2)
        for back in stride(from: days, through: 1, by: -1) {
            guard let dayStart = cal.date(byAdding: .day, value: -back, to: todayStart),
                  let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            let key = StressLevelStore.dayKey(dayStart)
            if let d = StressLevelStore.load(key), d.frozen, d.version == StressLevelDay.currentVersion,
               d.computedAt >= Int(dayEnd.timeIntervalSince1970) {
                out.append(d)
                continue
            }
            if let d = await Self.score(day: key, from: Int(dayStart.timeIntervalSince1970),
                                        to: Int(dayEnd.timeIntervalSince1970), repo: repo, workouts: workouts,
                                        stored: StressLevelStore.load(key), wholeDay: true) {
                StressLevelStore.save(d)
                out.append(d)
            }
        }
        recent = out.reversed()
    }

    /// Walking, running or cycling the phone's motion coprocessor saw (it keeps a week of history), a
    /// minute or more at a time. Empty without Motion & Fitness access or off iOS.
    static func phoneActivity(from: Int, to: Int) async -> [ClosedRange<Int>] {
        #if os(iOS)
        guard CMMotionActivityManager.isActivityAvailable(),
              CMMotionActivityManager.authorizationStatus() == .authorized else { return [] }
        let manager = CMMotionActivityManager()
        return await withCheckedContinuation { (c: CheckedContinuation<[ClosedRange<Int>], Never>) in
            manager.queryActivityStarting(from: Date(timeIntervalSince1970: TimeInterval(from)),
                                          to: Date(timeIntervalSince1970: TimeInterval(to)), to: .main) { acts, _ in
                _ = manager
                guard let acts else { c.resume(returning: []); return }
                var out: [ClosedRange<Int>] = []
                for (i, a) in acts.enumerated() where (a.walking || a.running || a.cycling) && a.confidence != .low {
                    let s = Int(a.startDate.timeIntervalSince1970)
                    let e = i + 1 < acts.count ? Int(acts[i + 1].startDate.timeIntervalSince1970) : to
                    if e - s >= 60 { out.append(s...(e - 1)) }
                }
                c.resume(returning: out)
            }
        }
        #else
        return []
        #endif
    }

    /// Calm floors from the days before `day`: the median of their floors once there are three.
    private static func historyBaseline(before day: String) -> (hr: Double, rmssd: Double?)? {
        let cal = Calendar.current
        guard let d = dayParser.date(from: day) else { return nil }
        var floors: [Double] = [], rms: [Double] = []
        for back in 1...14 {
            guard let prev = cal.date(byAdding: .day, value: -back, to: d),
                  let rec = StressLevelStore.load(StressLevelStore.dayKey(prev)) else { continue }
            let raws = rec.epochs.filter { $0.state == .measured && !$0.asleep }
            let hrs = raws.compactMap(\.meanHR).sorted()
            if hrs.count >= 20 { floors.append(hrs[Int(Double(hrs.count - 1) * StressLevel.calmPercentile)]) }
            let r = raws.compactMap(\.rmssd).sorted()
            if r.count >= 10 { rms.append(r[r.count / 2]) }
        }
        guard floors.count >= 3 else { return nil }
        let f = floors.sorted()[floors.count / 2]
        return (f, rms.count >= 3 ? rms.sorted()[rms.count / 2] : nil)
    }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Score one day's stored samples into epochs.
    private static func score(day key: String, from: Int, to: Int, repo: Repository, workouts rows: [WorkoutRow],
                              stored: StressLevelDay?, wholeDay: Bool = false,
                              activeSince: Int? = nil) async -> StressLevelDay? {
        let hr = await repo.hrSamples(from: from, to: to, limit: 200_000)
        // Nothing readable (a store hiccup, or samples aged out): keep what was stored rather than blank it.
        guard !hr.isEmpty else { return stored }
        let rr = await repo.rrIntervals(from: from, to: to, limit: 200_000)
        let gravity = await repo.gravitySamplesUnion(from: from, to: to, limit: 200_000)
        let sleeps = await repo.sleepSessions(from: from - 12 * 3600, to: to, limit: 20)
            .filter { $0.endTs > from && $0.effectiveStartTs < to }
            .map { $0.effectiveStartTs...$0.endTs }
        // Activity: logged workouts, the one running now, and walking, running or cycling the phone saw.
        var workouts = rows.filter { $0.endTs > from && $0.startTs < to }.map { $0.startTs...$0.endTs }
        if let a = activeSince, a < to { workouts.append(max(a, from)...to) }
        let logged = workouts
        let phone = await Self.phoneActivity(from: from, to: to)
        workouts += phone
        // The morning factors: last night's resting heart rate and HRV against your 30 days, 0-3.
        let morning = wholeDay ? (stored?.baseline.morning ?? StressModel(days: repo.days, stored: [])?.score)
            : StressModel(days: repo.days, stored: [])?.score
        let rests = repo.days.suffix(14).compactMap(\.restingHr).sorted()
        let restingHR = rests.isEmpty ? nil : Double(rests[rests.count / 2])
        let history = historyBaseline(before: key)

        let built: StressLevelDay = await runUnescalated {
            let inputs = StressLevel.Inputs(
                hr: hr.map { .init(ts: $0.ts, bpm: $0.bpm) },
                beats: rr.map { .init(ts: $0.ts, ms: $0.rrMs) },
                motion: WorkoutDetector.activitySeries(gravity).map { .init(ts: $0.ts, intensity: $0.intensity) },
                workouts: workouts, sleeps: sleeps)
            let raws = StressLevel.raw(from: from, to: to, inputs)
            let today = StressLevel.calmFloor(raws)
            // The baseline: your recent days; else the day's own floor; else resting heart rate plus a
            // little (awake and still runs a few bpm over sleeping). Today is re-scored in full every time,
            // so it keeps up with late-synced data and a refined calm level; a finished day is kept as is.
            let baseline: StressLevel.Baseline
            if let h = history {
                baseline = .init(calmHR: StressLevel.calmHR(floor: h.hr, restingHR: restingHR),
                                 typicalRMSSD: h.rmssd ?? today.rmssd, morning: morning, source: "history")
            } else if let f = today.hr {
                baseline = .init(calmHR: StressLevel.calmHR(floor: f, restingHR: restingHR),
                                 typicalRMSSD: today.rmssd, morning: morning, source: "today")
            } else {
                baseline = .init(calmHR: (restingHR ?? 60) + 8, typicalRMSSD: nil, morning: morning, source: "resting")
            }
            let frozen = wholeDay
            let epochs = StressLevel.score(raws, baseline: baseline)
            return StressLevelDay(day: key, baseline: baseline, frozen: frozen, epochs: epochs,
                                  computedAt: to, version: StressLevelDay.currentVersion)
        }
        if !wholeDay {
            // Which source made each active stretch: a logged or running workout, the phone, else the strap.
            var w = 0, p = 0, strap = 0
            for e in built.epochs where e.state == .active {
                let span = e.start...(e.start + StressLevel.epochSeconds - 1)
                if logged.contains(where: { $0.overlaps(span) }) { w += 1 }
                else if phone.contains(where: { $0.overlaps(span) }) { p += 1 }
                else { strap += 1 }
            }
            let after = built.epochs.filter { $0.state == .afterActivity }.count
            let calm = Int(built.baseline.calmHR.rounded())
            diagnosis = "today calm \(calm) bpm (\(built.baseline.source)), active 3-min stretches: "
                + "workout \(w), phone \(p), strap \(strap), after activity \(after)"
        }
        return built
    }
}

import Foundation
import Combine
import UIKit
import StrandAnalytics

/// Which sports get live set or interval tracking.
enum LiveIntervalModes {
    static let liftingSports: Set<String> = ["strength", "weightlifting", "bodybuilding", "powerlifting",
                                             "calisthenics"]
    static let intervalSports: Set<String> = ["assault bike", "hiit", "crossfit", "boot camp", "spinning",
                                              "indoor cycle", "row machine"]
    static let sprintSports: Set<String> = ["sprints"]

    static func mode(forSport sport: String) -> WorkRestSegmenter.Mode? {
        let s = sport.trimmingCharacters(in: .whitespaces).lowercased()
        if liftingSports.contains(s) { return .lifting }
        if intervalSports.contains(s) { return .assaultBike }
        if sprintSports.contains(s) { return .sprints }
        return nil
    }

    /// "Sets" for lifting, "Intervals" otherwise.
    static func unitName(_ mode: WorkRestSegmenter.Mode, count: Int) -> String {
        switch mode {
        case .lifting: return count == 1 ? String(localized: "set") : String(localized: "sets")
        case .assaultBike, .sprints: return count == 1 ? String(localized: "interval") : String(localized: "intervals")
        }
    }
}

/// Live sets / intervals and rests for the active workout, from the strap's heart rate. Runs only while a
/// workout of a tracked sport is active. The summary is saved into the workout's notes when it ends.
@MainActor
final class LiveIntervalTracker: ObservableObject {

    static let shared = LiveIntervalTracker()

    @Published private(set) var mode: WorkRestSegmenter.Mode?
    @Published private(set) var summary: WorkRestSegmenter.Summary?
    /// Lifting, between sets: whether heart rate has come down enough for the next one.
    @Published private(set) var readiness: SetReadiness.Reading?
    /// The inputs that don't change during a workout: resting heart rate, age, today's HRV against baseline.
    private(set) var readyBasis: (resting: Int, age: Int?, hrvRatio: Double?)?
    private var buzzedForRest: Int?

    private var segmenter: WorkRestSegmenter?
    private weak var model: AppModel?
    private var cancellables: Set<AnyCancellable> = []
    private var ticker: Timer?
    private var trackedStart: Int?
    private var trackedSport: String?

    private init() {}

    func attach(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model

        model.$activeWorkout
            .sink { [weak self] w in
                // Runs in willSet: hop a turn so `model.activeWorkout` reads the new value too.
                DispatchQueue.main.async { self?.workoutChanged(w) }
            }
            .store(in: &cancellables)

        model.live.$heartRate
            .sink { [weak self] hr in
                guard let self, let hr, self.segmenter != nil else { return }
                guard self.model?.activeWorkout?.isPaused != true else { return }
                self.segmenter?.ingest(ts: Int(Date().timeIntervalSince1970), bpm: hr)
                self.refresh()
            }
            .store(in: &cancellables)

        model.workoutNotesProvider = { [weak self] start, end in
            MainActor.assumeIsolated { self?.notes(start: start, end: end) }
        }

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.startTickerIfNeeded() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.ticker?.invalidate(); self?.ticker = nil }
            .store(in: &cancellables)
    }

    private func workoutChanged(_ w: AppModel.ActiveWorkout?) {
        guard let w else {
            stop()
            return
        }
        let start = Int(w.start.timeIntervalSince1970)
        // Same workout, possibly with a renamed sport.
        if start == trackedStart, w.sport == trackedSport { return }
        guard let m = LiveIntervalModes.mode(forSport: w.sport) else {
            stop()
            return
        }
        var seg = WorkRestSegmenter(mode: m, sensitivity: AutoTrackingPrefs.intervalSensitivity)
        // A backdated start carries the heart rate since then: count those sets too.
        for s in w.samples { seg.ingest(ts: s.ts, bpm: s.bpm) }
        segmenter = seg
        mode = m
        readyBasis = m == .lifting ? Self.basis(model) : nil
        buzzedForRest = nil
        trackedStart = start
        trackedSport = w.sport
        refresh()
        startTickerIfNeeded()
    }

    /// Track sets and rest for the running workout even though its sport isn't one tracked by default.
    func trackAsLifting() {
        guard let w = model?.activeWorkout, mode == nil else { return }
        var seg = WorkRestSegmenter(mode: .lifting, sensitivity: AutoTrackingPrefs.intervalSensitivity)
        for s in w.samples { seg.ingest(ts: s.ts, bpm: s.bpm) }
        segmenter = seg
        mode = .lifting
        readyBasis = Self.basis(model)
        buzzedForRest = nil
        trackedStart = Int(w.start.timeIntervalSince1970)
        trackedSport = w.sport
        refresh()
        startTickerIfNeeded()
    }

    private func stop() {
        segmenter = nil
        mode = nil
        summary = nil
        readiness = nil
        readyBasis = nil
        trackedStart = nil
        trackedSport = nil
        ticker?.invalidate()
        ticker = nil
    }

    private func refresh() {
        guard let seg = segmenter else { return }
        let next = seg.summary(now: Int(Date().timeIntervalSince1970))
        if next != summary { summary = next }
        let ready = readingNow(seg, next)
        if ready != readiness {
            if ready?.light == .green, readiness?.light != .green, SetReadyPrefs.buzz,
               case .resting(let since) = next.phase, buzzedForRest != since {
                buzzedForRest = since
                model?.ble.buzzStrapOnce()
            }
            readiness = ready
        }
    }

    private func readingNow(_ seg: WorkRestSegmenter, _ s: WorkRestSegmenter.Summary) -> SetReadiness.Reading? {
        guard mode == .lifting, SetReadyPrefs.enabled, let basis = readyBasis,
              let rest = s.currentRestS, let hr = model?.live.heartRate, hr > 0 else { return nil }
        return SetReadiness.read(config: SetReadyPrefs.config, currentBpm: hr, restS: rest,
                                 restingBpm: basis.resting, setPeakBpm: seg.intervals.last?.peakBpm,
                                 age: basis.age, hrvRatio: basis.hrvRatio)
    }

    /// Resting heart rate (latest night), age, and last night's HRV against the 30-night median.
    static func basis(_ model: AppModel?) -> (resting: Int, age: Int?, hrvRatio: Double?)? {
        guard let model else { return nil }
        let days = model.repo.days
        guard let resting = days.last(where: { ($0.restingHr ?? 0) > 0 })?.restingHr else { return nil }
        let hrvs = days.suffix(30).compactMap(\.avgHrv).filter { $0 > 0 }.sorted()
        var ratio: Double?
        if hrvs.count >= 7, let last = days.last(where: { ($0.avgHrv ?? 0) > 0 })?.avgHrv {
            ratio = last / hrvs[hrvs.count / 2]
        }
        return (resting, model.profile.age, ratio)
    }

    /// Once a second in the foreground, so the rest timer counts up even when heart rate is flat.
    private func startTickerIfNeeded() {
        guard ticker == nil, segmenter != nil, UIApplication.shared.applicationState == .active else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        t.tolerance = 0.2
        ticker = t
    }

    /// "9 sets · avg rest 1:45 · longest 3:10 · 14:20 working", or nil when nothing was tracked.
    func notes(start: Int, end: Int) -> String? {
        guard let seg = segmenter, let m = mode, trackedStart == start else { return nil }
        let inWorkout = seg.intervals.filter { $0.endTs <= end }
        let reps = LiveRepTracker.shared.notesLine(start: start)
        guard !inWorkout.isEmpty else { return reps }
        let rests = inWorkout.count > 1
            ? (1..<inWorkout.count).map { inWorkout[$0].startTs - inWorkout[$0 - 1].endTs } : []
        var parts = ["\(inWorkout.count) \(LiveIntervalModes.unitName(m, count: inWorkout.count))"]
        if !rests.isEmpty {
            let avg = rests.reduce(0, +) / rests.count
            parts.append(String(localized: "avg rest \(Self.clock(avg))"))
            if let longest = rests.max() { parts.append(String(localized: "longest \(Self.clock(longest))")) }
        }
        let work = inWorkout.map(\.durationS).reduce(0, +)
        parts.append(String(localized: "\(Self.clock(work)) working"))
        let line = parts.joined(separator: " · ") + " " + String(localized: "(estimated from heart rate)")
        return reps.map { line + "\n" + $0 } ?? line
    }

    static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

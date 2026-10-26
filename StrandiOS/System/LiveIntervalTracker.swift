import Foundation
import Combine
import UIKit
import StrandAnalytics

/// Which sports get live set or interval tracking.
enum LiveIntervalModes {
    static var liftingSports: Set<String> { WorkoutCategoryStore.strengthSports }
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

/// Live sets / intervals and rests for the active workout, found automatically (`StrengthSetDetector`:
/// heart rate, wrist motion and reps together, with your learned tuning for this sport or exercise).
/// Runs only while a workout of a tracked sport is active. Corrections made in the editor during the
/// workout are the authority for the stretch they cover; detection carries on after it. When the workout
/// ends its timeline is saved and its sets line written into the workout's notes.
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
    /// Heart rate since the workout began (unix seconds).
    private var hrHistory: [(ts: Int, bpm: Int)] = []
    /// Beats since the workout began, for the rest-only HRV check and the saved timeline.
    private var beats: [SetCalibration.Beat] = []
    /// Motion is contributing to detection.
    @Published private(set) var setsFromMotion = false

    /// How fast heart rate came down after one set: the drop from its peak 30 and 60 seconds later.
    struct Recovery: Equatable {
        let set: Int
        let peak: Int
        let drop30: Int?
        let drop60: Int?
    }
    @Published private(set) var recoveries: [Recovery] = []

    /// The sets as shown: your edits for the stretch they cover, detection after it. Uncertain segments
    /// are included, flagged.
    @Published private(set) var sets: [TimelineSet] = []
    /// What detection found over the whole workout so far.
    private var detected: [TimelineSet] = []
    /// Your sets from the editor, authoritative up to `editedThrough`.
    private var liveEdited: [TimelineSet]?
    private var editedThrough = 0
    private var editLog: [SetEditRecord] = []
    private var lastDetectAt = 0

    /// The exercise being done at a moment, when the Lift Log knows it.
    var exerciseAt: ((Int) -> String?)?
    /// The running Lift Log session's exercises, for the editor's menu.
    var exerciseNames: (() -> [String])?

    private var segmenter: WorkRestSegmenter?
    private weak var model: AppModel?
    private var cancellables: Set<AnyCancellable> = []
    private var ticker: Timer?
    private(set) var trackedStart: Int?
    private(set) var trackedSport: String?

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
                let now = Int(Date().timeIntervalSince1970)
                self.segmenter?.ingest(ts: now, bpm: hr)
                self.hrHistory.append((now, hr))
                if let f = self.hrHistory.first, now - f.ts > 4 * 3600 { self.hrHistory.removeAll { now - $0.ts > 4 * 3600 } }
                self.refresh()
            }
            .store(in: &cancellables)

        let live = model.live
        live.$rrSeq
            .removeDuplicates()
            // Synchronously, as the packet is published, so each beat is taken once.
            .map { [weak live] _ in live?.rr ?? [] }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] packet in
                guard let self, self.segmenter != nil, self.model?.activeWorkout?.isPaused != true else { return }
                let now = Int(Date().timeIntervalSince1970)
                for ms in packet where ms >= 300 && ms <= 2000 { self.beats.append(.init(ts: now, ms: ms)) }
                if let f = self.beats.first, now - f.ts > 4 * 3600 { self.beats.removeAll { now - $0.ts > 4 * 3600 } }
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
        begin(w, mode: m)
    }

    private func begin(_ w: AppModel.ActiveWorkout, mode m: WorkRestSegmenter.Mode) {
        let tuning = StrengthTuningStore.effective(sport: w.sport, exercise: nil, mode: m)
        var seg = WorkRestSegmenter(mode: m, params: tuning.segmenterParams(m))
        // A backdated start carries the heart rate since then: count those sets too.
        for s in w.samples { seg.ingest(ts: s.ts, bpm: s.bpm) }
        hrHistory = w.samples.map { ($0.ts, $0.bpm) }
        beats = []
        detected = []
        liveEdited = nil
        editedThrough = 0
        editLog = []
        sets = []
        recoveries = []
        lastDetectAt = 0
        segmenter = seg
        mode = m
        readyBasis = m == .lifting ? Self.basis(model) : nil
        buzzedForRest = nil
        trackedStart = Int(w.start.timeIntervalSince1970)
        trackedSport = w.sport
        // Corrections made earlier in this workout survive the app being closed or relaunched.
        if let saved = WorkoutSetsStore.load(startTs: trackedStart!, sport: w.sport), let edited = saved.edited {
            liveEdited = edited
            editedThrough = saved.history.map(\.at).max() ?? saved.endTs
            editLog = saved.history
        }
        refresh()
        startTickerIfNeeded()
    }

    /// Track sets and rest for the running workout even though its sport isn't one tracked by default.
    func trackAsLifting() {
        guard let w = model?.activeWorkout, mode == nil else { return }
        begin(w, mode: .lifting)
    }

    private func stop() {
        segmenter = nil
        mode = nil
        summary = nil
        readiness = nil
        readyBasis = nil
        hrHistory = []
        beats = []
        detected = []
        liveEdited = nil
        editLog = []
        sets = []
        recoveries = []
        setsFromMotion = false
        trackedStart = nil
        trackedSport = nil
        ticker?.invalidate()
        ticker = nil
    }

    // MARK: Detection

    private var motionRuns: [MotionRun] { mode == .lifting ? LiveRepTracker.shared.motionRuns : [] }

    private var hrSamples: [SetCalibration.HRSampleTS] { hrHistory.map { .init(ts: $0.ts, bpm: $0.bpm) } }

    /// Re-detect over the workout so far, at most every 3 s (it's quick, but there's no need to run it
    /// on every beat).
    private func detectIfDue(now: Int) {
        guard let m = mode, now - lastDetectAt >= 3 else { return }
        lastDetectAt = now
        let exercise = exerciseAt?(now)
        let tuning = StrengthTuningStore.effective(sport: trackedSport ?? "", exercise: exercise, mode: m)
        var found = StrengthSetDetector.detect(hr: hrSamples, beats: beats, motion: motionRuns, mode: m,
                                               tuning: tuning, bounds: (trackedStart ?? now)...now)
        // A set keeps the exercise it was first given (the Lift Log moves on to the next exercise while
        // earlier sets are still being re-detected); a new one takes the exercise at its time.
        for i in found.indices where found[i].exercise == nil {
            let f = found[i]
            found[i].exercise = detected.first { $0.exercise != nil && $0.end >= f.start && $0.start <= f.end }?.exercise
                ?? exerciseAt?((f.start + f.end) / 2)
        }
        detected = found
        let motion = !motionRuns.isEmpty
        if motion != setsFromMotion { setsFromMotion = motion }
    }

    /// Your edits up to where you made them, then detection.
    private func shownSets() -> [TimelineSet] {
        guard let edited = liveEdited else { return detected }
        let later = detected.filter { d in d.start > editedThrough && !edited.contains { $0.end >= d.start && $0.start <= d.end } }
        return (edited + later).sorted { $0.start < $1.start }
    }

    private func refresh() {
        guard let seg = segmenter else { return }
        let now = Int(Date().timeIntervalSince1970)
        detectIfDue(now: now)
        let shown = shownSets()
        if shown != sets { sets = shown }
        let counted = shown.filter { !$0.uncertain }
        // Phase: working while heart rate or motion says so; else resting since the last counted set.
        let phase: WorkRestSegmenter.Phase
        if let start = LiveRepTracker.shared.currentSetStart, mode == .lifting { phase = .working(since: Int(start)) }
        else if case .working(let since) = seg.phase, since > (counted.last?.end ?? 0) { phase = .working(since: since) }
        else if let last = counted.last { phase = .resting(since: last.end) }
        else { phase = .warmingUp }
        let next = WorkRestSegmenter.summary(
            intervals: counted.map { .init(startTs: $0.start, endTs: $0.end, peakBpm: peakHR($0) ?? 0) },
            phase: phase, now: now)
        if next != summary { summary = next }
        let rec = recoveryList(setEnds: counted.map(\.end), now: now)
        if rec != recoveries { recoveries = rec }
        let ready = readingNow(next, last: counted.last)
        if ready != readiness {
            if ready?.light == .green, readiness?.light != .green, SetReadyPrefs.buzz,
               case .resting(let since) = next.phase, buzzedForRest != since {
                buzzedForRest = since
                model?.ble.buzzStrapOnce()
            }
            readiness = ready
        }
    }

    // MARK: The editor during the workout

    /// The workout so far as a timeline, for the editor.
    func timelineSnapshot() -> SetTimeline? {
        guard let start = trackedStart, let m = mode else { return nil }
        let now = Int(Date().timeIntervalSince1970)
        lastDetectAt = 0
        detectIfDue(now: now)
        return SetTimeline(startTs: start, endTs: now, sport: trackedSport ?? "", mode: m.rawValue,
                           hr: hrSamples, beats: beats, motion: motionRuns, detected: detected,
                           detectedFrom: setsFromMotion ? "motion+heartRate" : "heartRate",
                           edited: liveEdited.map { _ in shownSets() }, history: editLog)
    }

    /// The editor's sets become the authority up to now.
    func applyEdits(_ edited: [TimelineSet], log: [SetEditRecord]) {
        liveEdited = edited
        editedThrough = Int(Date().timeIntervalSince1970)
        editLog = log
        refresh()
        // On disk at once, so they outlive a relaunch mid-workout.
        if let t = timelineSnapshot() { WorkoutSetsStore.save(t) }
    }

    private func readingNow(_ s: WorkRestSegmenter.Summary, last: TimelineSet?) -> SetReadiness.Reading? {
        guard mode == .lifting, SetReadyPrefs.enabled, let basis = readyBasis,
              let rest = s.currentRestS, let hr = model?.live.heartRate, hr > 0 else { return nil }
        return SetReadiness.read(config: SetReadyPrefs.config, currentBpm: hr, restS: rest,
                                 restingBpm: basis.resting, setPeakBpm: last.flatMap(peakHR),
                                 age: basis.age, hrvRatio: basis.hrvRatio,
                                 setStartBpm: last.flatMap { heartRate(near: $0.start) },
                                 plateaued: heartRatePlateaued())
    }

    /// Heart rate as a set began: the median of the 10 s before it to 3 s in.
    private func heartRate(near ts: Int) -> Int? {
        let v = hrHistory.filter { $0.ts >= ts - 10 && $0.ts <= ts + 3 }.map(\.bpm).sorted()
        return v.isEmpty ? nil : v[v.count / 2]
    }

    /// Heart rate has stopped coming down: the last 20 s sit within 4 bpm, and the newest 10 s are no
    /// lower than the 10 s before them.
    private func heartRatePlateaued() -> Bool {
        guard let last = hrHistory.last else { return false }
        let recent = hrHistory.suffix(40).filter { last.ts - $0.ts <= 20 }
        guard recent.count >= 10 else { return false }
        let bpms = recent.map(\.bpm)
        guard let hi = bpms.max(), let lo = bpms.min(), hi - lo <= 4 else { return false }
        let newer = recent.filter { last.ts - $0.ts < 10 }.map(\.bpm)
        let older = recent.filter { last.ts - $0.ts >= 10 }.map(\.bpm)
        guard !newer.isEmpty, !older.isEmpty else { return false }
        let mean = { (x: [Int]) in Double(x.reduce(0, +)) / Double(x.count) }
        return mean(newer) >= mean(older) - 0.5
    }

    /// Peak heart rate during a set or just after it, where it usually lands.
    private func peakHR(_ s: TimelineSet) -> Int? {
        hrHistory.filter { $0.ts >= s.start && $0.ts <= s.end + 20 }.map(\.bpm).max()
    }

    /// Save this workout's timeline, so it can be shown and corrected afterwards.
    private func saveTimeline(start: Int, end: Int, sport: String) -> SetTimeline? {
        guard let m = mode else { return nil }
        lastDetectAt = 0
        detectIfDue(now: end)
        let hr = hrSamples.filter { $0.ts >= start && $0.ts <= end }
        guard hr.count >= 30 || liveEdited != nil else { return nil }
        let t = SetTimeline(startTs: start, endTs: end, sport: sport, mode: m.rawValue, hr: hr,
                            beats: beats.filter { $0.ts >= start && $0.ts <= end },
                            motion: motionRuns.filter { $0.start >= start && $0.end <= end },
                            detected: detected.filter { $0.end <= end },
                            detectedFrom: setsFromMotion ? "motion+heartRate" : "heartRate",
                            edited: liveEdited.map { _ in shownSets().filter { $0.end <= end } },
                            history: editLog)
        WorkoutSetsStore.save(t)
        if t.isCorrected { Task { _ = await StrengthTuningStore.refit(sport: sport, mode: m) } }
        return t
    }

    /// For each set: its peak heart rate (up to 20 s after it ends, where it usually lands) and the drop
    /// 30 and 60 seconds after that peak. A drop is left out until that much rest has passed.
    private func recoveryList(setEnds: [Int], now: Int) -> [Recovery] {
        guard !hrHistory.isEmpty else { return [] }
        var out: [Recovery] = []
        for (i, end) in setEnds.enumerated() {
            let lo = hrHistory.firstIndex { $0.ts >= end - 15 } ?? hrHistory.count
            var hi = lo
            while hi < hrHistory.count, hrHistory[hi].ts <= end + 90 { hi += 1 }
            let window = hrHistory[lo..<hi]
            guard let top = window.filter({ $0.ts <= end + 20 }).max(by: { $0.bpm < $1.bpm }) else { continue }
            let nextStart = i + 1 < setEnds.count ? setEnds[i + 1] : Int.max
            func drop(_ secs: Int) -> Int? {
                let t = top.ts + secs
                guard t <= now, t < nextStart,
                      let v = window.filter({ abs($0.ts - t) <= 5 }).min(by: { abs($0.ts - t) < abs($1.ts - t) })
                else { return nil }
                return top.bpm - v.bpm
            }
            out.append(Recovery(set: i + 1, peak: top.bpm, drop30: drop(30), drop60: drop(60)))
        }
        return out
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

    /// The workout's sets line, from its saved timeline, or nil when nothing was tracked.
    func notes(start: Int, end: Int) -> String? {
        guard mode != nil, trackedStart == start,
              let t = saveTimeline(start: start, end: end, sport: trackedSport ?? "") else { return nil }
        return WorkoutSetsStore.notes(t)
    }

    static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

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
    /// Heart rate since the workout began (unix seconds), for recovery after each set.
    private var hrHistory: [(ts: Int, bpm: Int)] = []
    /// Where sets come from: the strap's motion (confirmed by heart rate) when rep counting streams it,
    /// else heart rate alone.
    @Published private(set) var setsFromMotion = false

    /// How fast heart rate came down after one set: the drop from its peak 30 and 60 seconds later.
    struct Recovery: Equatable {
        let set: Int
        let peak: Int
        let drop30: Int?
        let drop60: Int?
    }
    @Published private(set) var recoveries: [Recovery] = []

    private var segmenter: WorkRestSegmenter?
    /// Learned from your corrections (`SetTuningStore`); 0 = no HRV check.
    private var hrvDrop = 0.0
    /// Beats since the workout began (unix seconds), for the HRV check and the saved record.
    private var beats: [SetCalibration.Beat] = []
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
        let tuning = SetTuningStore.tuning(for: m)
        var seg = WorkRestSegmenter(mode: m, params: tuning.params(m))
        hrvDrop = tuning.hrvDrop
        // A backdated start carries the heart rate since then: count those sets too.
        for s in w.samples { seg.ingest(ts: s.ts, bpm: s.bpm) }
        hrHistory = w.samples.map { ($0.ts, $0.bpm) }
        beats = []
        recoveries = []
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
        let tuning = SetTuningStore.tuning(for: .lifting)
        var seg = WorkRestSegmenter(mode: .lifting, params: tuning.params(.lifting))
        hrvDrop = tuning.hrvDrop
        for s in w.samples { seg.ingest(ts: s.ts, bpm: s.bpm) }
        hrHistory = w.samples.map { ($0.ts, $0.bpm) }
        beats = []
        recoveries = []
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
        hrHistory = []
        beats = []
        recoveries = []
        setsFromMotion = false
        trackedStart = nil
        trackedSport = nil
        ticker?.invalidate()
        ticker = nil
    }

    private func refresh() {
        guard let seg = segmenter else { return }
        let now = Int(Date().timeIntervalSince1970)
        let motion = mode == .lifting ? motionSummary(now: now) : nil
        if (motion != nil) != setsFromMotion { setsFromMotion = motion != nil }
        let next = motion ?? WorkRestSegmenter.summary(intervals: heartRateSets(seg), phase: seg.phase, now: now)
        if next != summary { summary = next }
        let rec = recoveryList(setEnds: setEnds(seg), now: now)
        if rec != recoveries { recoveries = rec }
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
        let reps = LiveRepTracker.shared
        let hrSets = heartRateSets(seg)
        let peak = setsFromMotion ? reps.sets.last.flatMap { reps.peakHR($0) } : hrSets.last?.peakBpm
        let startTs = setsFromMotion ? reps.sets.last.map { Int($0.start) } : hrSets.last?.startTs
        return SetReadiness.read(config: SetReadyPrefs.config, currentBpm: hr, restS: rest,
                                 restingBpm: basis.resting, setPeakBpm: peak,
                                 age: basis.age, hrvRatio: basis.hrvRatio,
                                 setStartBpm: startTs.flatMap(heartRate(near:)),
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

    /// Sets and rests from the strap's motion, when rep counting is streaming it: a set is a steady run
    /// of reps whose heart rate rose with it; everything between is rest, however much you move.
    private func motionSummary(now: Int) -> WorkRestSegmenter.Summary? {
        let reps = LiveRepTracker.shared
        // Switching rep counting off mid-workout keeps the sets it already counted; only a workout that
        // never streamed motion falls back to heart rate.
        guard reps.active || !reps.sets.isEmpty else { return nil }
        let sets = reps.sets
        let rests: [Int] = sets.count > 1
            ? (1..<sets.count).map { Int(sets[$0].start - sets[$0 - 1].end) } : []
        let works = sets.map { Int($0.end - $0.start) }
        let phase: WorkRestSegmenter.Phase
        var restNow: Int?, workNow: Int?
        if let start = reps.currentSetStart {
            phase = .working(since: Int(start))
            workNow = max(0, now - Int(start))
        } else if let last = sets.last {
            phase = .resting(since: Int(last.end))
            restNow = max(0, now - Int(last.end))
        } else {
            phase = .warmingUp
        }
        return WorkRestSegmenter.Summary(
            count: sets.count, phase: phase, currentRestS: restNow, currentWorkS: workNow,
            lastRestS: rests.last, avgRestS: rests.isEmpty ? nil : rests.reduce(0, +) / rests.count,
            longestRestS: rests.max(), avgWorkS: works.isEmpty ? nil : works.reduce(0, +) / works.count,
            totalWorkS: works.reduce(0, +))
    }

    /// When each finished set ended, from whichever source is counting sets.
    private func setEnds(_ seg: WorkRestSegmenter) -> [Int] {
        setsFromMotion ? LiveRepTracker.shared.sets.map { Int($0.end) } : heartRateSets(seg).map(\.endTs)
    }

    /// The heart-rate sets after your learned HRV check, with pauses inside a set joined.
    private func heartRateSets(_ seg: WorkRestSegmenter) -> [WorkRestSegmenter.Interval] {
        SetCalibration.joinShortGaps(SetCalibration.hrvFilter(seg.intervals, beats: beats, drop: hrvDrop))
    }

    /// Keep this workout's sets, heart rate and beats so they can be shown and corrected afterwards.
    private func saveRecord(start: Int, end: Int, sport: String) {
        guard let seg = segmenter, let m = mode else { return }
        let motionSets = LiveRepTracker.shared.notesLine(start: start) != nil ? LiveRepTracker.shared.sets : []
        let detected: [WorkoutSetsRecord.SetSpan] = motionSets.isEmpty
            ? heartRateSets(seg).filter { $0.endTs <= end }.map { .init(start: $0.startTs, end: $0.endTs, reps: nil) }
            : motionSets.map { .init(start: Int($0.start), end: Int($0.end), reps: $0.reps) }
        let hr = hrHistory.filter { $0.ts >= start && $0.ts <= end }.map { SetCalibration.HRSampleTS(ts: $0.ts, bpm: $0.bpm) }
        guard hr.count >= 60 else { return }
        WorkoutSetsStore.save(WorkoutSetsRecord(
            startTs: start, endTs: end, sport: sport, mode: m.rawValue, hr: hr,
            beats: beats.filter { $0.ts >= start && $0.ts <= end },
            detected: detected, detectedFrom: motionSets.isEmpty ? "heartRate" : "motion", edited: nil))
    }

    /// For each set: its peak heart rate (up to 20 s after it ends, where it usually lands) and the drop
    /// 30 and 60 seconds after that peak. A drop is left out until that much rest has passed.
    private func recoveryList(setEnds: [Int], now: Int) -> [Recovery] {
        guard !hrHistory.isEmpty else { return [] }
        var out: [Recovery] = []
        // Only the newest set's numbers can still change; earlier ones are kept as computed.
        for (i, end) in setEnds.enumerated() {
            if i < recoveries.count - 1, recoveries[i].set == i + 1, recoveries[i].drop60 != nil {
                out.append(recoveries[i])
                continue
            }
            // The stretch from just before the set ended to 90 s after: everything this set's numbers need.
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

    /// "9 sets · avg rest 1:45 · longest 3:10 · 14:20 working", or nil when nothing was tracked.
    func notes(start: Int, end: Int) -> String? {
        guard let seg = segmenter, let m = mode, trackedStart == start else { return nil }
        saveRecord(start: start, end: end, sport: trackedSport ?? "")
        let inWorkout = heartRateSets(seg).filter { $0.endTs <= end }
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
        var line = parts.joined(separator: " · ") + " " + String(localized: "(estimated from heart rate)")
        let drops = recoveries.compactMap(\.drop60)
        if drops.count >= 2, let first = drops.first, let last = drops.last {
            let avg = drops.reduce(0, +) / drops.count
            line += "\n" + String(localized: "HR recovery in 60 s: avg -\(avg) bpm over \(drops.count) rests (first -\(first), last -\(last))")
        }
        return reps.map { line + "\n" + $0 } ?? line
    }

    static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

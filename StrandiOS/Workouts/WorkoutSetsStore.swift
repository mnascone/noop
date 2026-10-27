import Foundation
import StrandAnalytics
import WhoopStore
import WhoopProtocol

/// A workout's set timeline on disk: one JSON file per workout, holding the recorded heart rate, beats
/// and wrist motion, what was detected, your edits and their history. Files outlive restarts and syncs:
/// syncing rewrites heart-rate rows in the database, never these, so your corrections stay the authority
/// for that workout.
typealias WorkoutSetsRecord = SetTimeline

@MainActor
enum WorkoutSetsStore {
    private static var dir: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let d = base.appendingPathComponent("noop-sets", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func file(startTs: Int, sport: String) -> URL? {
        let safe = sport.lowercased().filter { $0.isLetter || $0.isNumber }
        return dir?.appendingPathComponent("\(startTs)-\(safe).json")
    }

    static func load(startTs: Int, sport: String) -> SetTimeline? {
        guard let url = file(startTs: startTs, sport: sport), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SetTimeline.self, from: data)
    }

    /// Follow a workout whose sport was changed. Sets you corrected go with it; ones only detected are
    /// dropped, to be counted again the new sport's way.
    static func move(startTs: Int, from old: String, to new: String) {
        guard let oldURL = file(startTs: startTs, sport: old), oldURL != file(startTs: startTs, sport: new),
              var t = load(startTs: startTs, sport: old) else { return }
        if t.isCorrected {
            t.sport = new
            save(t)
        }
        try? FileManager.default.removeItem(at: oldURL)
    }

    static func save(_ t: SetTimeline) {
        guard let url = file(startTs: t.startTs, sport: t.sport), let data = try? JSONEncoder().encode(t) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func all() -> [SetTimeline] {
        guard let d = dir, let files = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)
        else { return [] }
        return files.compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(SetTimeline.self, from: $0) } }
            .sorted { $0.startTs > $1.startTs }
    }

    /// Every saved timeline, read off the main thread (they carry the workout's heart rate, so there's
    /// some to read).
    nonisolated static func readAll() async -> [SetTimeline] {
        await Task.detached(priority: .utility) { () -> [SetTimeline] in
            guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            else { return [] }
            let d = base.appendingPathComponent("noop-sets", isDirectory: true)
            guard let files = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)
            else { return [] }
            return files.compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(SetTimeline.self, from: $0) } }
        }.value
    }

    /// Corrected workouts of a sport, newest first.
    static func corrected(sport: String, limit: Int = 15) -> [SetTimeline] {
        Array(all().filter { $0.isCorrected && $0.sport.lowercased() == sport.lowercased() }.prefix(limit))
    }

    /// A timeline for an older workout, or one saved without live tracking: its heart rate and beats from
    /// the store, detected with your current tuning. With no stored heart rate yet it's empty, and you can
    /// still enter sets into it. A sport that doesn't count sets is treated as lifting.
    static func build(row: WorkoutRow, repo: Repository) async -> SetTimeline {
        let mode = LiveIntervalModes.mode(forSport: row.sport) ?? .lifting
        let hrRows = await repo.hrSamples(from: row.startTs, to: row.endTs, limit: 50_000)
        let rr = hrRows.count >= 30 ? await repo.rrIntervals(from: row.startTs, to: row.endTs, limit: 100_000) : []
        let hr = hrRows.map { SetCalibration.HRSampleTS(ts: $0.ts, bpm: $0.bpm) }
        let beats = rr.map { SetCalibration.Beat(ts: $0.ts, ms: $0.rrMs) }
        let tuning = StrengthTuningStore.effective(sport: row.sport, exercise: nil, mode: mode)
        let sets = hr.count >= 30
            ? StrengthSetDetector.detect(hr: hr, beats: beats, motion: [], mode: mode, tuning: tuning,
                                         bounds: row.startTs...row.endTs)
            : []
        return SetTimeline(startTs: row.startTs, endTs: row.endTs, sport: row.sport, mode: mode.rawValue,
                           hr: hr, beats: beats, detected: sets, detectedFrom: "heartRate")
    }

    /// What the Lift Log knows about a workout: the sets you logged during it (exercise and when), and
    /// your exercise vocabulary for the editor's menu. Exercises seen are remembered with their muscle
    /// region so their push / pull / legs default is right.
    struct LiftContext {
        var logged: [(start: Int, end: Int, exercise: String)] = []
        var names: [String] = []

        /// The exercise logged at a moment, within 20 s of a logged set.
        func exercise(at ts: Int) -> String? {
            logged.first { ts >= $0.start - 20 && ts <= $0.end + 20 }?.exercise
        }
    }

    static func liftContext(row: WorkoutRow, repo: Repository) async -> LiftContext {
        guard let store = await repo.storeHandle() else { return LiftContext() }
        var ctx = LiftContext()
        let vocabulary = (try? await store.liftExercises(deviceId: repo.deviceId)) ?? []
        let sessions = ((try? await store.liftSessions(deviceId: repo.deviceId, fromTs: row.startTs - 3 * 3600,
                                                        toTs: row.endTs)) ?? [])
            .filter { ($0.endTs ?? row.endTs) >= row.startTs }
        var sessionNames: [String] = []
        for sess in sessions {
            for set in (try? await store.liftSets(sessionId: sess.id)) ?? [] {
                ExerciseCategoryStore.shared.note(set.exercise, region: set.primaryMuscle?.region.rawValue)
                sessionNames.append(set.exercise)
                if let a = set.startTs, let b = set.endTs, b > a { ctx.logged.append((a, b, set.exercise)) }
            }
        }
        for v in vocabulary { ExerciseCategoryStore.shared.note(v.name, region: v.primaryMuscle?.region.rawValue) }
        var seen = Set<String>()
        ctx.names = (sessionNames + ExerciseCategoryStore.shared.recentNames + vocabulary.map(\.name))
            .filter { seen.insert($0.lowercased()).inserted }
        return ctx
    }

    /// Detected sets labelled with the Lift Log exercise logged at that time, where one was.
    static func label(_ sets: [TimelineSet], with ctx: LiftContext) -> [TimelineSet] {
        sets.map { s in
            var s = s
            if s.exercise == nil { s.exercise = ctx.exercise(at: (s.start + s.end) / 2) }
            return s
        }
    }

    /// The workout's sets line, from whatever its sets are now: count, rests, work, push/pull/legs, and
    /// heart-rate recovery.
    static func notes(_ t: SetTimeline) -> String {
        let workout = WorkoutCategoryStore.shared.categories(startTs: t.startTs)
        let sum = SetSummary(t, workout: WorkoutCategoryStore.shared.fallback(startTs: t.startTs)) {
            ExerciseCategoryStore.category(for: $0)
        }
        let mode = WorkRestSegmenter.Mode(rawValue: t.mode) ?? .lifting
        var parts = ["\(sum.count) \(LiveIntervalModes.unitName(mode, count: sum.count))"]
        if let a = sum.avgRestS { parts.append(String(localized: "avg rest \(LiveIntervalTracker.clock(a))")) }
        if let l = sum.longestRestS { parts.append(String(localized: "longest \(LiveIntervalTracker.clock(l))")) }
        parts.append(String(localized: "\(LiveIntervalTracker.clock(sum.workS)) working"))
        if sum.byCategory.isEmpty, !workout.isEmpty {
            // Chosen for the workout, with no set of its own to count: say what it was.
            parts.append(StrengthTypeStore.shared.types.filter(workout.contains).map(\.displayName).joined(separator: " + "))
        }
        for c in StrengthTypeStore.shared.types { if let n = sum.byCategory[c], n > 0 { parts.append("\(c.displayName) \(n)") } }
        var line = parts.joined(separator: " · ") + " "
            + (t.isCorrected ? String(localized: "(corrected by you)")
               : t.detectedFrom.contains("motion") ? String(localized: "(from wrist motion and heart rate)")
               : String(localized: "(estimated from heart rate)"))
        let reps = t.counted.compactMap(\.reps)
        if reps.count == t.counted.count, !reps.isEmpty {
            line += "\n" + String(localized: "Reps \(reps.map(String.init).joined(separator: " · "))")
        }
        let drops = sum.recoveries.compactMap(\.drop60)
        if let avg = sum.avgDrop60, let first = drops.first, let last = drops.last {
            line += "\n" + String(localized: "HR recovery in 60 s: avg -\(avg) bpm over \(drops.count) rests (first -\(first), last -\(last))")
        }
        return line
    }

    /// Write the workout's notes from its timeline, for a workout NOOP saved itself (others are read-only).
    /// A workout's types were changed away from the sets card: bring its notes along.
    static func typesChanged(row: WorkoutRow, repo: Repository) async {
        guard let t = load(startTs: row.startTs, sport: row.sport), !t.sets.isEmpty else { return }
        await syncNotes(t, row: row, repo: repo)
    }

    static func syncNotes(_ t: SetTimeline, row: WorkoutRow, repo: Repository) async {
        guard WorkoutSource.classify(row.source) == .manual else { return }
        let notes = notes(t)
        guard notes != row.notes else { return }
        await repo.saveManualWorkout(WorkoutRow(
            startTs: row.startTs, endTs: row.endTs, sport: row.sport, source: row.source,
            durationS: row.durationS, energyKcal: row.energyKcal, avgHr: row.avgHr, maxHr: row.maxHr,
            strain: row.strain, distanceM: row.distanceM, zonesJSON: row.zonesJSON, notes: notes,
            steps: row.steps))
        await repo.refresh()
    }
}

/// Learned and overridden detection tuning. Learned tunings are per kind of workout (sport) and per
/// exercise, refitted from your corrections; overrides come from Detection settings and win. Neither is
/// ever applied backwards: a workout keeps the sets it was given, and yours once you've corrected it.
enum StrengthTuningStore {
    static func sportKey(_ sport: String) -> String { "sport:" + sport.lowercased() }
    static func exerciseKey(_ name: String) -> String { "exercise:" + name.lowercased() }

    private static func fitKey(_ context: String) -> String { "noop.strengthFit." + context }
    private static func overrideKey(_ context: String) -> String { "noop.strengthOverride." + context }

    static func fit(_ context: String) -> StrengthFit? {
        UserDefaults.standard.data(forKey: fitKey(context)).flatMap { try? JSONDecoder().decode(StrengthFit.self, from: $0) }
    }

    static func override(sport: String) -> StrengthTuning? {
        UserDefaults.standard.data(forKey: overrideKey(sportKey(sport)))
            .flatMap { try? JSONDecoder().decode(StrengthTuning.self, from: $0) }
    }

    static func setOverride(_ t: StrengthTuning?, sport: String) {
        if let t, let d = try? JSONEncoder().encode(t) {
            UserDefaults.standard.set(d, forKey: overrideKey(sportKey(sport)))
        } else {
            UserDefaults.standard.removeObject(forKey: overrideKey(sportKey(sport)))
        }
    }

    static func forget(_ context: String) { UserDefaults.standard.removeObject(forKey: fitKey(context)) }

    /// What detection learned for a sport, or the defaults for its kind.
    static func learned(sport: String, mode: WorkRestSegmenter.Mode) -> StrengthTuning {
        fit(sportKey(sport))?.tuning ?? .defaults(mode)
    }

    /// The tuning to detect with: your override for the sport, else the exercise's learned tuning when
    /// it has enough corrections behind it, else the sport's, else the defaults.
    static func effective(sport: String, exercise: String?, mode: WorkRestSegmenter.Mode) -> StrengthTuning {
        if let o = override(sport: sport) { return o }
        if let e = exercise, let f = fit(exerciseKey(e)), f.examples >= 2 { return f.tuning }
        return learned(sport: sport, mode: mode)
    }

    /// Refit from every corrected workout of this sport, and for each exercise with two or more corrected
    /// workouts, off the main thread. Existing workouts are not re-detected.
    @MainActor
    static func refit(sport: String, mode: WorkRestSegmenter.Mode, including extra: [SetTimeline] = []) async -> StrengthFit? {
        // The workout being edited counts as it is now, in place of any older saved copy.
        let extraIds = Set(extra.map(\.id))
        let timelines = extra.filter(\.isCorrected) + WorkoutSetsStore.corrected(sport: sport).filter { !extraIds.contains($0.id) }
        guard !timelines.isEmpty else { return nil }
        let start = StrengthTuning.defaults(mode)
        let sportExamples = StrengthExample.from(timelines)
        var exerciseExamples: [String: [StrengthExample]] = [:]
        let names = Set(timelines.flatMap { ($0.edited ?? []).compactMap(\.exercise) })
        for n in names {
            let ex = StrengthExample.from(timelines, exercise: n)
            if ex.count >= 2 { exerciseExamples[n] = ex }
        }
        let result = await Task.detached(priority: .utility) { () -> (StrengthFit?, [String: StrengthFit]) in
            let s = StrengthLearner.fit(sportExamples, mode: mode, start: start)
            var e: [String: StrengthFit] = [:]
            for (n, ex) in exerciseExamples {
                if let f = StrengthLearner.fit(ex, mode: mode, start: s?.tuning ?? start) { e[n] = f }
            }
            return (s, e)
        }.value
        func store(_ f: StrengthFit, _ key: String) {
            if let d = try? JSONEncoder().encode(f) { UserDefaults.standard.set(d, forKey: fitKey(key)) }
        }
        if let s = result.0 { store(s, sportKey(sport)) }
        for (n, f) in result.1 { store(f, exerciseKey(n)) }
        return result.0
    }

    /// Every sport and exercise something has been learned for.
    static func learnedContexts() -> [(context: String, fit: StrengthFit)] {
        UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("noop.strengthFit.") }
            .sorted()
            .compactMap { k in
                let ctx = String(k.dropFirst("noop.strengthFit.".count))
                return fit(ctx).map { (ctx, $0) }
            }
    }
}

import Foundation
import StrandAnalytics
import WhoopStore
import WhoopProtocol

/// The sets of one workout, kept on this device so they can be shown and corrected after it ends: what
/// was counted live, the heart rate and beats it was counted from, and your corrections. Corrections
/// train `SetCalibration`, so later workouts count sets the way you do.
struct WorkoutSetsRecord: Codable, Equatable {
    struct SetSpan: Codable, Equatable, Hashable, Identifiable {
        var start: Int
        var end: Int
        var reps: Int?
        var id: Int { start }
        var span: SetCalibration.Span { .init(start: start, end: end) }
    }

    var startTs: Int
    var endTs: Int
    var sport: String
    /// "lifting", "assaultBike", "sprints".
    var mode: String
    var hr: [SetCalibration.HRSampleTS]
    var beats: [SetCalibration.Beat]
    /// What was counted, and where from ("heartRate" or "motion").
    var detected: [SetSpan]
    var detectedFrom: String
    /// Your sets, once you've corrected them.
    var edited: [SetSpan]?

    var sets: [SetSpan] { edited ?? detected }
    var segmenterMode: WorkRestSegmenter.Mode { WorkRestSegmenter.Mode(rawValue: mode) ?? .lifting }
}

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

    static func load(startTs: Int, sport: String) -> WorkoutSetsRecord? {
        guard let url = file(startTs: startTs, sport: sport), let data = try? Data(contentsOf: url),
              var r = try? JSONDecoder().decode(WorkoutSetsRecord.self, from: data) else { return nil }
        // Counted before short pauses were always joined: join them now, so a set isn't shown split.
        if r.edited == nil { r.detected = joinShortGaps(r.detected) }
        return r
    }

    /// Sets whose break is under `SetCalibration.minGapS` become one, reps added.
    static func joinShortGaps(_ sets: [WorkoutSetsRecord.SetSpan]) -> [WorkoutSetsRecord.SetSpan] {
        var out: [WorkoutSetsRecord.SetSpan] = []
        for s in sets.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, s.start - last.end < SetCalibration.minGapS {
                let reps = (last.reps ?? 0) + (s.reps ?? 0)
                out[out.count - 1] = .init(start: last.start, end: max(last.end, s.end), reps: reps > 0 ? reps : nil)
            } else {
                out.append(s)
            }
        }
        return out
    }

    static func save(_ r: WorkoutSetsRecord) {
        guard let url = file(startTs: r.startTs, sport: r.sport), let data = try? JSONEncoder().encode(r) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Every record with corrections, newest first.
    static func corrected(mode: WorkRestSegmenter.Mode, limit: Int = 12) -> [WorkoutSetsRecord] {
        guard let d = dir, let files = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)
        else { return [] }
        return files.compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(WorkoutSetsRecord.self, from: $0) } }
            .filter { $0.edited != nil && $0.segmenterMode == mode }
            .sorted { $0.startTs > $1.startTs }
            .prefix(limit).map { $0 }
    }

    /// A record for an older workout, or one saved without live tracking: its heart rate and beats from
    /// the store, counted with your current tuning. With no stored heart rate yet it's an empty record you
    /// can still enter sets into. A sport that doesn't count sets is treated as lifting.
    static func build(row: WorkoutRow, repo: Repository) async -> WorkoutSetsRecord {
        let mode = LiveIntervalModes.mode(forSport: row.sport) ?? .lifting
        let hrRows = await repo.hrSamples(from: row.startTs, to: row.endTs, limit: 50_000)
        let rr = hrRows.count >= 60 ? await repo.rrIntervals(from: row.startTs, to: row.endTs, limit: 100_000) : []
        let hr = hrRows.map { SetCalibration.HRSampleTS(ts: $0.ts, bpm: $0.bpm) }
        let beats = rr.map { SetCalibration.Beat(ts: $0.ts, ms: $0.rrMs) }
        let sets = hr.count >= 60
            ? SetCalibration.detect(hr: hr, beats: beats, mode: mode, tuning: SetTuningStore.tuning(for: mode)) : []
        return WorkoutSetsRecord(startTs: row.startTs, endTs: row.endTs, sport: row.sport, mode: mode.rawValue,
                                 hr: hr, beats: beats,
                                 detected: sets.map { .init(start: $0.startTs, end: $0.endTs, reps: nil) },
                                 detectedFrom: "heartRate", edited: nil)
    }

    /// The workout's notes with its sets line rewritten for your corrected sets.
    static func notesLine(_ r: WorkoutSetsRecord) -> String {
        let sets = r.sets.sorted { $0.start < $1.start }
        let mode = r.segmenterMode
        var parts = ["\(sets.count) \(LiveIntervalModes.unitName(mode, count: sets.count))"]
        let rests = sets.count > 1 ? (1..<sets.count).map { sets[$0].start - sets[$0 - 1].end } : []
        if !rests.isEmpty {
            parts.append(String(localized: "avg rest \(LiveIntervalTracker.clock(rests.reduce(0, +) / rests.count))"))
            if let longest = rests.max() { parts.append(String(localized: "longest \(LiveIntervalTracker.clock(longest))")) }
        }
        parts.append(String(localized: "\(LiveIntervalTracker.clock(sets.map { $0.end - $0.start }.reduce(0, +))) working"))
        let reps = sets.compactMap(\.reps)
        var line = parts.joined(separator: " · ")
        line += " " + (r.edited != nil ? String(localized: "(corrected by you)") : String(localized: "(estimated from heart rate)"))
        if reps.count == sets.count, !reps.isEmpty {
            line += "\n" + String(localized: "Reps \(reps.map(String.init).joined(separator: " · "))")
        }
        return line
    }
}

/// Your learned set-detection tuning per kind of workout, refitted each time you correct one.
enum SetTuningStore {
    private static func key(_ mode: WorkRestSegmenter.Mode) -> String { "noop.setTuning.\(mode.rawValue)" }

    static func fit(for mode: WorkRestSegmenter.Mode) -> SetCalibration.Fit? {
        guard let data = UserDefaults.standard.data(forKey: key(mode)) else { return nil }
        return try? JSONDecoder().decode(SetCalibration.Fit.self, from: data)
    }

    /// The learned tuning, or the defaults scaled by the old sensitivity setting until there is one.
    static func tuning(for mode: WorkRestSegmenter.Mode) -> SetCalibration.Tuning {
        if let f = fit(for: mode) { return f.tuning }
        let p = WorkRestSegmenter.params(for: mode, sensitivity: AutoTrackingPrefs.intervalSensitivity)
        return .init(riseBPM: p.riseBPM, fallBPM: p.fallBPM, minWorkS: p.minWorkS, minRestS: p.minRestS, hrvDrop: 0)
    }

    static func store(_ f: SetCalibration.Fit, for mode: WorkRestSegmenter.Mode) {
        if let data = try? JSONEncoder().encode(f) { UserDefaults.standard.set(data, forKey: key(mode)) }
    }

    static func reset(_ mode: WorkRestSegmenter.Mode) {
        UserDefaults.standard.removeObject(forKey: key(mode))
    }

    /// Refit from every corrected workout of this kind, off the main thread.
    @MainActor
    static func refit(_ mode: WorkRestSegmenter.Mode) async -> SetCalibration.Fit? {
        let examples = WorkoutSetsStore.corrected(mode: mode).map {
            SetCalibration.Example(hr: $0.hr, beats: $0.beats, truth: ($0.edited ?? []).map(\.span))
        }
        guard !examples.isEmpty else { return nil }
        let fit = await Task.detached(priority: .utility) { SetCalibration.fit(examples, mode: mode) }.value
        if let fit { store(fit, for: mode) }
        return fit
    }
}

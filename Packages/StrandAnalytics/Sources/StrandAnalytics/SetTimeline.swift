import Foundation

// SetTimeline.swift: one strength workout's sets, the sensor data they came from, and your edits.
//
// The recorded heart rate, beats and wrist-motion runs are kept untouched. What was detected is kept
// too. Your edits produce `edited`, which from then on is the authority for this workout, and every
// edit is logged in `history`. Editing never changes the sensor data: joining two sets makes one span
// covering both and the gap, nothing more.
//
// Pure and Codable. Older records (start/end/reps only) decode with defaults.

/// Push, pull or legs: the split a strength exercise belongs to. Stored per exercise; a set inherits
/// its exercise's.
public enum StrengthCategory: String, Codable, CaseIterable, Sendable {
    case push, pull, legs

    /// A sensible default for an exercise you haven't categorised: from its name first (what it's
    /// usually trained as in a push/pull/legs split), else from the region of its primary muscle.
    /// Nil when neither says (core work, carries), so it's left for you rather than guessed.
    /// `primaryRegion` is `LiftMuscle.Region`'s raw value ("push", "pull", "legs", "trunk").
    public static func guess(name: String, primaryRegion: String? = nil) -> StrengthCategory? {
        let n = " " + name.lowercased().replacingOccurrences(of: "-", with: " ") + " "
        func has(_ words: [String]) -> Bool { words.contains { n.contains($0) } }
        // Order matters: "leg curl" is legs though "curl" alone is pull; "upright row" is push in most
        // splits (delts) though "row" is pull.
        if has([" squat", "lunge", "leg press", "leg curl", "leg extension", "calf", "hip thrust", "glute",
                "split squat", "step up", "hack squat", "romanian", " rdl", "good morning", "adductor",
                "abductor", "hamstring", "nordic", "bulgarian"]) { return .legs }
        if has(["upright row", "face pull"]) { return n.contains("face pull") ? .pull : .push }
        if has([" row", "pull up", "pullup", "pull-up", "chin up", "chinup", "pulldown", "pull down", " curl",
                "deadlift", "shrug", "lat ", "rear delt", "reverse fly", "pullover"]) { return .pull }
        if has(["bench", " press", "push up", "pushup", "dip", " fly", "flye", "tricep", "lateral raise",
                "front raise", "skull", "pec deck", "overhead", " ohp", "shoulder"]) { return .push }
        return primaryRegion.flatMap(StrengthCategory.init(rawValue:))
    }
}

/// A stretch of steady, rhythmic wrist motion: a candidate set from the strap's accelerometer.
public struct MotionRun: Codable, Equatable, Sendable {
    public var start: Int
    public var end: Int
    public var reps: Int
    /// When each counted rep landed (unix seconds), for the optional rep marks.
    public var repTimes: [Double]
    /// Typical size of one rep's swing, in g. Nil when not measured.
    public var rangeG: Double?

    public init(start: Int, end: Int, reps: Int, repTimes: [Double] = [], rangeG: Double? = nil) {
        self.start = start; self.end = end; self.reps = reps; self.repTimes = repTimes; self.rangeG = rangeG
    }
}

/// One set on the timeline.
public struct TimelineSet: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var start: Int
    public var end: Int
    public var reps: Int?
    /// The exercise it was, when known. Its category comes from the exercise.
    public var exercise: String?
    /// Push / pull / legs chosen for this set itself. Wins over its exercise's and the workout's.
    public var category: StrengthCategory?
    /// How sure detection was, 0-1. Nil for a set you made or confirmed.
    public var confidence: Double?
    /// Weak evidence: shown, not counted, until you confirm or delete it.
    public var uncertain: Bool

    public var duration: Int { end - start }
    public var span: SetCalibration.Span { .init(start: start, end: end) }

    public init(id: String? = nil, start: Int, end: Int, reps: Int? = nil, exercise: String? = nil,
                category: StrengthCategory? = nil, confidence: Double? = nil, uncertain: Bool = false) {
        self.id = id ?? "s\(start)-\(UUID().uuidString.prefix(6))"
        self.start = start; self.end = end; self.reps = reps; self.exercise = exercise
        self.category = category
        self.confidence = confidence; self.uncertain = uncertain
    }

    enum CodingKeys: String, CodingKey { case id, start, end, reps, exercise, category, confidence, uncertain }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(Int.self, forKey: .start)
        end = try c.decode(Int.self, forKey: .end)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? "s\(start)"
        reps = try c.decodeIfPresent(Int.self, forKey: .reps)
        exercise = try c.decodeIfPresent(String.self, forKey: .exercise)
        category = try c.decodeIfPresent(StrengthCategory.self, forKey: .category)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
        uncertain = try c.decodeIfPresent(Bool.self, forKey: .uncertain) ?? false
    }
}

/// One edit, as logged.
public struct SetEditRecord: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case add, delete, move, split, join, confirm, exercise, reps, reset, undo, redo
        /// A rest you said is a real rest: no change to the sets, but your word on it.
        case keepRest
        /// Push / pull / legs set on a set.
        case category
    }
    /// When you made it (unix seconds).
    public var at: Int
    public var kind: Kind
    /// The spans it touched, before and after, as [start, end] pairs.
    public var before: [[Int]]
    public var after: [[Int]]

    public init(at: Int, kind: Kind, before: [[Int]], after: [[Int]]) {
        self.at = at; self.kind = kind; self.before = before; self.after = after
    }
}

public struct SetTimeline: Codable, Equatable, Identifiable, Sendable {
    /// One workout's timeline: its start and sport.
    public var id: String { "\(startTs)-\(sport)" }
    public var startTs: Int
    public var endTs: Int
    public var sport: String
    /// `WorkRestSegmenter.Mode` raw value.
    public var mode: String
    public var hr: [SetCalibration.HRSampleTS]
    public var beats: [SetCalibration.Beat]
    public var motion: [MotionRun]
    /// What detection found, untouched by edits.
    public var detected: [TimelineSet]
    /// "heartRate", "motion", or "motion+heartRate".
    public var detectedFrom: String
    /// Your sets. Once present they are the authority for this workout.
    public var edited: [TimelineSet]?
    public var history: [SetEditRecord]

    public init(startTs: Int, endTs: Int, sport: String, mode: String,
                hr: [SetCalibration.HRSampleTS], beats: [SetCalibration.Beat], motion: [MotionRun] = [],
                detected: [TimelineSet], detectedFrom: String, edited: [TimelineSet]? = nil,
                history: [SetEditRecord] = []) {
        self.startTs = startTs; self.endTs = endTs; self.sport = sport; self.mode = mode
        self.hr = hr; self.beats = beats; self.motion = motion; self.detected = detected
        self.detectedFrom = detectedFrom; self.edited = edited; self.history = history
    }

    enum CodingKeys: String, CodingKey {
        case startTs, endTs, sport, mode, hr, beats, motion, detected, detectedFrom, edited, history
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startTs = try c.decode(Int.self, forKey: .startTs)
        endTs = try c.decode(Int.self, forKey: .endTs)
        sport = try c.decode(String.self, forKey: .sport)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "lifting"
        hr = try c.decodeIfPresent([SetCalibration.HRSampleTS].self, forKey: .hr) ?? []
        beats = try c.decodeIfPresent([SetCalibration.Beat].self, forKey: .beats) ?? []
        motion = try c.decodeIfPresent([MotionRun].self, forKey: .motion) ?? []
        detected = try c.decodeIfPresent([TimelineSet].self, forKey: .detected) ?? []
        detectedFrom = try c.decodeIfPresent(String.self, forKey: .detectedFrom) ?? "heartRate"
        edited = try c.decodeIfPresent([TimelineSet].self, forKey: .edited)
        history = try c.decodeIfPresent([SetEditRecord].self, forKey: .history) ?? []
    }

    /// What's shown: your sets once you've edited, else what was detected.
    public var sets: [TimelineSet] { (edited ?? detected).sorted { $0.start < $1.start } }
    /// What counts: the shown sets minus uncertain ones.
    public var counted: [TimelineSet] { sets.filter { !$0.uncertain } }
    public var isCorrected: Bool { edited != nil }
}

// MARK: - The editor

/// Edits on a timeline's sets, with undo and redo and a log. Every operation is total: one that can't
/// apply (a span too short, an id that's gone) changes nothing and logs nothing.
public struct SetTimelineEditor: Equatable {
    public private(set) var sets: [TimelineSet]
    public private(set) var log: [SetEditRecord] = []
    private var undoStack: [[TimelineSet]] = []
    private var redoStack: [[TimelineSet]] = []
    public let bounds: ClosedRange<Int>
    /// The shortest a set can be made.
    public static let minSetS = 3

    public init(sets: [TimelineSet], bounds: ClosedRange<Int>) {
        self.sets = sets.sorted { $0.start < $1.start }
        self.bounds = bounds
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var counted: [TimelineSet] { sets.filter { !$0.uncertain } }

    public func index(of id: String) -> Int? { sets.firstIndex { $0.id == id } }

    private mutating func commit(_ kind: SetEditRecord.Kind, now: Int, before: [TimelineSet], _ change: (inout [TimelineSet]) -> Bool) -> Bool {
        var next = sets
        guard change(&next) else { return false }
        next.sort { $0.start < $1.start }
        guard next != sets else { return false }
        undoStack.append(sets)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        let touchedAfter = next.filter { n in !sets.contains(n) }
        log.append(SetEditRecord(at: now, kind: kind, before: before.map { [$0.start, $0.end] },
                                 after: touchedAfter.map { [$0.start, $0.end] }))
        sets = next
        return true
    }

    /// Add a set over `start...end`. Anything it overlaps becomes part of it (you drew over it).
    @discardableResult
    public mutating func add(start: Int, end: Int, now: Int = 0) -> String? {
        let s = Swift.max(bounds.lowerBound, Swift.min(start, end))
        let e = Swift.min(bounds.upperBound, Swift.max(start, end))
        guard e - s >= Self.minSetS else { return nil }
        let over = sets.filter { $0.end >= s && $0.start <= e }
        let new = TimelineSet(start: ([s] + over.map(\.start)).min()!, end: ([e] + over.map(\.end)).max()!,
                              reps: Self.sumReps(over), exercise: over.first?.exercise)
        let ok = commit(.add, now: now, before: over) { list in
            list.removeAll { x in over.contains { $0.id == x.id } }
            list.append(new)
            return true
        }
        return ok ? new.id : nil
    }

    @discardableResult
    public mutating func delete(_ id: String, now: Int = 0) -> Bool {
        guard let i = index(of: id) else { return false }
        let before = [sets[i]]
        return commit(.delete, now: now, before: before) { list in list.remove(at: i); return true }
    }

    /// Move one edge. A set dragged into its neighbour joins it.
    @discardableResult
    public mutating func move(_ id: String, start: Int? = nil, end: Int? = nil, now: Int = 0) -> Bool {
        guard let i = index(of: id) else { return false }
        var s = sets[i]
        if let start { s.start = Swift.max(bounds.lowerBound, Swift.min(start, s.end - Self.minSetS)) }
        if let end { s.end = Swift.min(bounds.upperBound, Swift.max(end, s.start + Self.minSetS)) }
        s.uncertain = false
        s.confidence = nil
        let before = [sets[i]]
        return commit(.move, now: now, before: before) { list in
            list[i] = s
            // Overlaps join into the moved set.
            let over = list.filter { $0.id != s.id && $0.end >= s.start && $0.start <= s.end }
            if !over.isEmpty {
                var merged = s
                merged.start = ([s.start] + over.map(\.start)).min()!
                merged.end = ([s.end] + over.map(\.end)).max()!
                merged.reps = Self.sumReps([s] + over)
                list.removeAll { x in over.contains { $0.id == x.id } }
                if let j = list.firstIndex(where: { $0.id == s.id }) { list[j] = merged }
            }
            return true
        }
    }

    /// Two sets from one, cut at `at` (a moment inside it), with a `gapS` break between.
    @discardableResult
    public mutating func split(_ id: String, at: Int, gapS: Int = 2, now: Int = 0) -> Bool {
        guard let i = index(of: id) else { return false }
        let s = sets[i]
        let firstEnd = at - gapS / 2, secondStart = at + (gapS - gapS / 2)
        guard firstEnd - s.start >= Self.minSetS, s.end - secondStart >= Self.minSetS else { return false }
        var a = s
        let b = TimelineSet(start: secondStart, end: s.end, exercise: s.exercise)
        a.end = firstEnd
        a.reps = nil; a.uncertain = false; a.confidence = nil
        return commit(.split, now: now, before: [s]) { list in
            list[i] = a
            list.append(b)
            return true
        }
    }

    /// The set and the next one become one continuous set covering both and the gap between.
    @discardableResult
    public mutating func joinWithNext(_ id: String, now: Int = 0) -> Bool {
        guard let i = index(of: id), i + 1 < sets.count else { return false }
        let a = sets[i], b = sets[i + 1]
        var joined = a
        joined.end = Swift.max(a.end, b.end)
        joined.reps = Self.sumReps([a, b])
        joined.uncertain = false
        joined.confidence = nil
        if joined.exercise == nil { joined.exercise = b.exercise }
        return commit(.join, now: now, before: [a, b]) { list in
            list[i] = joined
            list.remove(at: i + 1)
            return true
        }
    }

    /// The rest after set `id` is a real rest, not a pause: logged as your call, the sets unchanged.
    @discardableResult
    public mutating func keepRest(after id: String, now: Int = 0) -> Bool {
        guard let i = index(of: id), i + 1 < sets.count else { return false }
        log.append(SetEditRecord(at: now, kind: .keepRest, before: [sets[i], sets[i + 1]].map { [$0.start, $0.end] },
                                 after: [[sets[i].end, sets[i + 1].start]]))
        return true
    }

    /// Rests you've said are real, as the gap each covers.
    public var keptRests: [ClosedRange<Int>] {
        log.filter { $0.kind == .keepRest }.compactMap { r in r.after.first.flatMap { $0.count == 2 ? $0[0]...$0[1] : nil } }
    }

    /// An uncertain segment you say is a real set.
    @discardableResult
    public mutating func confirm(_ id: String, now: Int = 0) -> Bool {
        guard let i = index(of: id), sets[i].uncertain else { return false }
        let before = [sets[i]]
        return commit(.confirm, now: now, before: before) { list in
            list[i].uncertain = false
            list[i].confidence = nil
            return true
        }
    }

    @discardableResult
    public mutating func setExercise(_ ids: [String], to name: String?, now: Int = 0) -> Bool {
        let idx = ids.compactMap(index(of:))
        guard !idx.isEmpty else { return false }
        let before = idx.map { sets[$0] }
        let clean = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return commit(.exercise, now: now, before: before) { list in
            for i in idx { list[i].exercise = (clean?.isEmpty ?? true) ? nil : clean }
            return true
        }
    }

    /// Push / pull / legs for these sets themselves (nil: back to their exercise's or the workout's).
    @discardableResult
    public mutating func setCategory(_ ids: [String], to c: StrengthCategory?, now: Int = 0) -> Bool {
        let idx = ids.compactMap(index(of:))
        guard !idx.isEmpty else { return false }
        let before = idx.map { sets[$0] }
        return commit(.category, now: now, before: before) { list in
            for i in idx { list[i].category = c }
            return true
        }
    }

    @discardableResult
    public mutating func setReps(_ id: String, _ reps: Int?, now: Int = 0) -> Bool {
        guard let i = index(of: id) else { return false }
        let before = [sets[i]]
        return commit(.reps, now: now, before: before) { list in
            list[i].reps = reps.flatMap { $0 > 0 ? $0 : nil }
            return true
        }
    }

    /// Back to what was detected (itself undoable).
    @discardableResult
    public mutating func reset(to detected: [TimelineSet], now: Int = 0) -> Bool {
        let before = sets
        return commit(.reset, now: now, before: before) { list in list = detected; return true }
    }

    /// Undo and redo are logged too, so the history reads as what happened.
    public mutating func undo(now: Int = 0) {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(sets)
        log.append(SetEditRecord(at: now, kind: .undo, before: sets.map { [$0.start, $0.end] },
                                 after: prev.map { [$0.start, $0.end] }))
        sets = prev
    }

    public mutating func redo(now: Int = 0) {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(sets)
        log.append(SetEditRecord(at: now, kind: .redo, before: sets.map { [$0.start, $0.end] },
                                 after: next.map { [$0.start, $0.end] }))
        sets = next
    }

    /// The gap after set `id`, if there's a next one: its start and end.
    public func gap(after id: String) -> ClosedRange<Int>? {
        guard let i = index(of: id), i + 1 < sets.count else { return nil }
        return sets[i].end...sets[i + 1].start
    }

    static func sumReps(_ s: [TimelineSet]) -> Int? {
        let r = s.compactMap(\.reps)
        return r.isEmpty ? nil : r.reduce(0, +)
    }
}

// MARK: - Summary

/// What a workout's sets add up to, recalculated from whatever the sets are now.
public struct SetSummary: Equatable, Sendable {
    public struct Recovery: Equatable, Sendable {
        public let peak: Int
        public let drop60: Int?
    }
    public let count: Int
    public let workS: Int
    public let rests: [Int]
    public let recoveries: [Recovery]
    public let byCategory: [StrengthCategory: Int]

    public var avgRestS: Int? { rests.isEmpty ? nil : rests.reduce(0, +) / rests.count }
    public var longestRestS: Int? { rests.max() }
    public var avgDrop60: Int? {
        let d = recoveries.compactMap(\.drop60)
        return d.count >= 2 ? d.reduce(0, +) / d.count : nil
    }

    /// From the counted sets and the recorded heart rate. `category` maps an exercise name to its
    /// push/pull/legs category.
    /// A set's category: its own, else its exercise's (`category`), else the workout's (`workout`).
    public init(_ t: SetTimeline, workout: StrengthCategory? = nil,
                category: (String) -> StrengthCategory? = { _ in nil }) {
        let s = t.counted
        count = s.count
        workS = s.map(\.duration).reduce(0, +)
        rests = s.count > 1 ? (1..<s.count).map { s[$0].start - s[$0 - 1].end } : []
        var rec: [Recovery] = []
        for (i, set) in s.enumerated() {
            let nextStart = i + 1 < s.count ? s[i + 1].start : t.endTs + 120
            let window = t.hr.filter { $0.ts >= set.start && $0.ts <= set.end + 20 }
            guard let top = window.max(by: { $0.bpm < $1.bpm }) else { continue }
            let at = top.ts + 60
            var drop: Int?
            if at < nextStart, let v = t.hr.filter({ abs($0.ts - at) <= 5 }).min(by: { abs($0.ts - at) < abs($1.ts - at) }) {
                drop = top.bpm - v.bpm
            }
            rec.append(Recovery(peak: top.bpm, drop60: drop))
        }
        recoveries = rec
        var cats: [StrengthCategory: Int] = [:]
        for set in s {
            if let c = set.category ?? set.exercise.flatMap(category) ?? workout { cats[c, default: 0] += 1 }
        }
        byCategory = cats
    }
}

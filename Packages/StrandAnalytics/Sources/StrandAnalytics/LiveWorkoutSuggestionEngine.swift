import Foundation

// LiveWorkoutSuggestionEngine.swift — live "start / end workout?" suggestions for the iPhone.
//
// The retrospective `AutoWorkoutDetector` only runs after a sync and only offers to SAVE a past window.
// This engine runs while the app is awake (BLE heart-rate notifies, region and motion callbacks keep it
// running in the background) and decides when to OFFER to start or end a live workout, the way Apple
// Watch does. Like the retrospective detector it only ever suggests: the app layer turns each action into
// a notification and nothing starts or stops until the wearer taps it.
//
// Three inputs drive it, all supplied by the app layer:
//   1. Gym geofence: `gymEntered` / `gymExited` from a CLCircularRegion the wearer set.
//   2. Phone motion: the CMMotionActivity classification (walking / running / stationary / automotive).
//   3. Heart rate: the smoothed live bpm, available only while the realtime stream is armed.
//
// Heart rate is the confirming signal, and the realtime stream costs strap battery, so the engine also
// says when it WANTS the stream (`wantsRealtime`): from gym arrival until a start suggestion is resolved,
// during a sustained walking bout, and during any active workout. Otherwise the stream stays off.
//
// Start rules:
//   - Gym: inside the gym for `gymMinDwellS`, at least `minHRCoverageSamples` samples since arrival in the
//     last `startWindowS`, and at least `gymElevatedFraction` of them at or above resting + `gymMarginBPM`. Start is backdated to the first
//     elevated sample of the current elevated stretch, never earlier than gym arrival.
//   - Walk / run: a walking or running bout held for `walkMinBoutS` (`runMinBoutS` when mostly running),
//     with the window's median HR at or above resting + `walkMarginBPM` (`runMarginBPM`). With no heart
//     rate at all (strap disconnected) a bout of `walkNoHRMinBoutS` still qualifies. Start is backdated to
//     the beginning of the bout. A walking bout inside the gym is left to the gym rule.
//
// End rules (active workout, one suggestion until activity resumes):
//   - Gym: leaving the gym ends it immediately. Otherwise heart rate quiet (under resting +
//     `quietMarginBPM` for all but `quietTolerance` of samples) for `gymQuietEndS`.
//   - Walk / run: motion stopped for `walkStopGraceS` with heart rate back below the walk floor, or stopped
//     for `walkStopMaxS` regardless of heart rate, or automotive at once. End is backdated to the last
//     walking moment.
//   - Any other workout (started by hand): heart rate quiet for `otherQuietEndS`.
//
// Pure and deterministic: no clock, no I/O. All timestamps are unix seconds supplied by the caller. Events
// may arrive slightly out of order (motion history is replayed after a background wake); the engine keeps
// its own "now" as the latest timestamp seen. iOS-only feature: there is no Kotlin twin. NOT medical advice.

public struct LiveWorkoutSuggestionEngine: Sendable {

    // MARK: - Types

    /// What kind of session a suggestion is about. The app layer maps it to a catalogue sport.
    public enum Context: String, Sendable, Equatable {
        case gym, walk, run
    }

    /// Phone motion classification, reduced from CMMotionActivity by the app layer.
    public enum Motion: String, Sendable, Equatable {
        case stationary, walking, running, cycling, automotive, unknown

        var isOnFoot: Bool { self == .walking || self == .running }
    }

    /// Why an end suggestion was raised. Drives the notification copy.
    public enum EndReason: String, Sendable, Equatable {
        case leftGym, stoppedMoving, startedDriving, heartRateRecovered
    }

    public enum Event: Sendable, Equatable {
        case gymEntered
        case gymExited
        case motion(Motion)
        case heartRate(Int)
        /// A workout became active. `context` is the suggestion it came from, nil when started by hand.
        case workoutStarted(context: Context?)
        case workoutEnded
        /// The wearer declined the start suggestion ("Not now").
        case startDismissed
        /// The wearer declined the end suggestion ("Keep going").
        case endDismissed
        /// No new data, just time passing.
        case tick
    }

    public enum Action: Sendable, Equatable {
        case suggestStart(context: Context, startTs: Int, avgBpm: Int?)
        case withdrawStart
        case suggestEnd(context: Context?, endTs: Int, reason: EndReason)
        case withdrawEnd
    }

    public struct Config: Sendable, Equatable {
        public var restingBpm: Int
        public var gymEnabled: Bool
        public var walkEnabled: Bool

        public init(restingBpm: Int, gymEnabled: Bool = true, walkEnabled: Bool = true) {
            self.restingBpm = restingBpm
            self.gymEnabled = gymEnabled
            self.walkEnabled = walkEnabled
        }
    }

    // MARK: - Tunables (named constants, fixed a priori, not fit to labels)

    /// Gym work (lifting, circuits) raises HR less than cardio, so its floor sits below the retrospective
    /// detector's resting + 30.
    public static let gymMarginBPM = 20
    public static let gymElevatedFraction = 0.6
    /// Time inside the gym before a start can be suggested. Arriving out of breath (cycled, ran for the bus)
    /// settles within a few minutes, and the window below only judges samples since arrival.
    public static let gymMinDwellS = 3 * 60
    /// A brisk walk sits roughly 15 to 40 bpm over resting. 12 keeps a slow stroll out.
    public static let walkMarginBPM = 12
    public static let runMarginBPM = 25
    /// Rolling window the start rules judge.
    public static let startWindowS = 180
    /// Fewer samples than this in the window means "no usable heart rate" (the stream runs about 1 Hz).
    public static let minHRCoverageSamples = 30
    public static let walkMinBoutS = 5 * 60
    public static let runMinBoutS = 3 * 60
    public static let walkNoHRMinBoutS = 10 * 60
    /// A walking bout survives a pause this long (a crossing, a red light).
    public static let walkStopGraceS = 120
    public static let walkStopMaxS = 5 * 60
    /// Arm the realtime stream once a walking bout has lasted this long, so HR is ready by `walkMinBoutS`.
    public static let walkArmAfterS = 60
    /// Stop holding the stream for a bout that never qualified after this long.
    public static let walkMaxArmS = 30 * 60
    /// Stop holding the stream for a gym visit with no start suggestion after this long.
    public static let gymMaxArmS = 2 * 60 * 60
    /// An elevated stretch ends at a sub-floor gap longer than this (rest between sets is shorter).
    public static let elevatedStretchGapS = 5 * 60
    /// "Quiet" heart rate for the end rules: under resting + this.
    public static let quietMarginBPM = 10
    /// Fraction of samples allowed above the quiet line inside a quiet stretch.
    public static let quietTolerance = 0.1
    public static let gymQuietEndS = 10 * 60
    public static let otherQuietEndS = 15 * 60
    /// Activity counts as resumed (re-enabling an end suggestion) after this much elevated HR.
    public static let resumeElevatedS = 3 * 60
    /// A start suggestion nobody answered is withdrawn after this long.
    public static let pendingStartTimeoutS = 30 * 60
    /// Heart-rate history kept in memory.
    public static let hrHistoryS = 20 * 60

    // MARK: - State

    public var config: Config

    public private(set) var now: Int = 0

    public private(set) var inGym = false
    private var gymEnteredAt: Int?
    private var gymStartSuggested = false

    private var motion: Motion = .unknown
    private var walkBoutStart: Int?
    private var lastOnFootTs: Int?
    private var runSecondsInBout = 0
    private var lastMotionTs: Int?
    private var walkStartSuggestedForBout = false
    private var drivingSince: Int?

    private var hr: [(ts: Int, bpm: Int)] = []

    public private(set) var workoutActive = false
    public private(set) var workoutContext: Context?
    private var workoutStartedAt: Int?
    private var endSuggested = false

    public private(set) var pendingStart: (context: Context, startTs: Int)?
    private var pendingStartRaisedAt: Int?

    public init(config: Config) {
        self.config = config
    }

    // MARK: - Public API

    /// Whether the engine needs live heart rate right now. The app layer holds the realtime arm while true.
    public var wantsRealtime: Bool {
        if workoutActive { return true }
        if config.gymEnabled, inGym, let entered = gymEnteredAt {
            if pendingStart?.context == .gym { return true }
            if !gymStartSuggested, now - entered < Self.gymMaxArmS { return true }
        }
        if config.walkEnabled, !inGym, let bout = walkBoutStart, !walkStartSuggestedForBout {
            let dur = now - bout
            if dur >= Self.walkArmAfterS, dur < Self.walkMaxArmS { return true }
        }
        if let p = pendingStart, p.context != .gym { return true }
        return false
    }

    /// Live heart-rate samples the engine holds in `[from, to]`, for seeding a backdated workout.
    public func heartRate(from: Int, to: Int) -> [(ts: Int, bpm: Int)] {
        hr.filter { $0.ts >= from && $0.ts <= to }
    }

    /// Feed one event observed at `ts`. Returns the suggestions to raise or withdraw, in order.
    public mutating func handle(_ event: Event, at ts: Int) -> [Action] {
        now = max(now, ts)
        var out: [Action] = []

        switch event {
        case .gymEntered:
            if !inGym {
                inGym = true
                gymEnteredAt = ts
                gymStartSuggested = false
            }
        case .gymExited:
            if inGym {
                inGym = false
                gymEnteredAt = nil
                if pendingStart?.context == .gym { clearPending(&out) }
                if workoutActive, !endSuggested, workoutContext == .gym || workoutContext == nil {
                    endSuggested = true
                    out.append(.suggestEnd(context: workoutContext, endTs: ts, reason: .leftGym))
                }
            }
        case .motion(let m):
            applyMotion(m, at: ts)
        case .heartRate(let bpm):
            if bpm >= 30, bpm <= 230 {
                if let last = hr.last, last.ts >= ts {
                    if last.ts == ts { hr[hr.count - 1].bpm = bpm }
                } else {
                    hr.append((ts, bpm))
                }
            }
            let cutoff = now - Self.hrHistoryS
            if let first = hr.first, first.ts < cutoff { hr.removeAll { $0.ts < cutoff } }
        case .workoutStarted(let context):
            workoutActive = true
            workoutContext = context ?? inferredContext()
            workoutStartedAt = ts
            endSuggested = false
            if pendingStart != nil {
                pendingStart = nil
                pendingStartRaisedAt = nil
            }
            if inGym { gymStartSuggested = true }
            if walkBoutStart != nil { walkStartSuggestedForBout = true }
        case .workoutEnded:
            workoutActive = false
            workoutContext = nil
            workoutStartedAt = nil
            if endSuggested {
                endSuggested = false
                out.append(.withdrawEnd)
            }
        case .startDismissed:
            if pendingStart != nil {
                pendingStart = nil
                pendingStartRaisedAt = nil
            }
        case .endDismissed:
            break   // endSuggested stays set until activity resumes
        case .tick:
            break
        }

        evaluate(&out)
        return out
    }

    // MARK: - Motion

    private mutating func applyMotion(_ m: Motion, at ts: Int) {
        // Count running time inside the current bout before switching state.
        if motion == .running, let since = lastMotionTs, ts > since, walkBoutStart != nil {
            runSecondsInBout += ts - since
        }
        if m.isOnFoot {
            if walkBoutStart == nil {
                walkBoutStart = ts
                runSecondsInBout = 0
                walkStartSuggestedForBout = false
            }
            lastOnFootTs = ts
        } else if motion.isOnFoot {
            lastOnFootTs = ts   // the bout ran up to this transition
        }
        drivingSince = (m == .automotive) ? (drivingSince ?? ts) : nil
        motion = m
        lastMotionTs = ts
    }

    /// Seconds since the wearer was last on foot, 0 while on foot.
    private func stoppedFor() -> Int? {
        if motion.isOnFoot { return 0 }
        guard let last = lastOnFootTs else { return nil }
        return now - last
    }

    private func boutIsRun() -> Bool {
        guard let start = walkBoutStart else { return false }
        var run = runSecondsInBout
        if motion == .running, let since = lastMotionTs { run += max(0, now - since) }
        let dur = max(1, (lastOnFootTs.map { max($0, now) } ?? now) - start)
        return Double(run) / Double(dur) >= 0.5
    }

    private func inferredContext() -> Context? {
        if inGym { return .gym }
        if walkBoutStart != nil { return boutIsRun() ? .run : .walk }
        return nil
    }

    // MARK: - Evaluation

    private mutating func evaluate(_ out: inout [Action]) {
        // Close a walking bout that has been stopped past the grace window.
        if let stopped = stoppedFor(), walkBoutStart != nil, !motion.isOnFoot {
            let walkFloor = config.restingBpm + Self.walkMarginBPM
            let calm = (windowMedian(seconds: 120) ?? 0) < walkFloor
            let boutOver = drivingSince != nil
                || (stopped >= Self.walkStopGraceS && (calm || stopped >= Self.walkStopMaxS))
            if boutOver {
                let endTs = lastOnFootTs ?? now
                if workoutActive, !endSuggested, workoutContext == .walk || workoutContext == .run {
                    endSuggested = true
                    out.append(.suggestEnd(context: workoutContext, endTs: endTs,
                                           reason: drivingSince != nil ? .startedDriving : .stoppedMoving))
                }
                if let p = pendingStart, p.context != .gym { clearPending(&out) }
                walkBoutStart = nil
                runSecondsInBout = 0
                walkStartSuggestedForBout = false
            }
        }

        // Withdraw a start suggestion nobody answered.
        if let raised = pendingStartRaisedAt, now - raised >= Self.pendingStartTimeoutS {
            clearPending(&out)
        }

        if workoutActive {
            evaluateEnd(&out)
        } else if pendingStart == nil {
            evaluateStart(&out)
        }
    }

    private mutating func evaluateStart(_ out: inout [Action]) {
        if config.gymEnabled, inGym, !gymStartSuggested, let entered = gymEnteredAt,
           now - entered >= Self.gymMinDwellS {
            // Judge only heart rate since arrival: walking or cycling there must not count as the session.
            let window = recent(seconds: Self.startWindowS).filter { $0.ts >= entered }
            if window.count >= Self.minHRCoverageSamples {
                let floor = config.restingBpm + Self.gymMarginBPM
                let elevated = window.filter { $0.bpm >= floor }.count
                if Double(elevated) / Double(window.count) >= Self.gymElevatedFraction {
                    let start = max(entered, elevatedStretchStart(floor: floor) ?? window[0].ts)
                    raise(.gym, startTs: start, &out)
                    gymStartSuggested = true
                    return
                }
            }
        }

        if config.walkEnabled, !inGym, let bout = walkBoutStart, !walkStartSuggestedForBout, motion.isOnFoot {
            let dur = now - bout
            let isRun = boutIsRun()
            let window = recent(seconds: Self.startWindowS)
            if window.count >= Self.minHRCoverageSamples {
                guard dur >= (isRun ? Self.runMinBoutS : Self.walkMinBoutS) else { return }
                let floor = config.restingBpm + (isRun ? Self.runMarginBPM : Self.walkMarginBPM)
                if let median = windowMedian(seconds: Self.startWindowS), median >= floor {
                    raise(isRun ? .run : .walk, startTs: bout, &out)
                    walkStartSuggestedForBout = true
                }
            } else if dur >= Self.walkNoHRMinBoutS {
                raise(isRun ? .run : .walk, startTs: bout, &out)
                walkStartSuggestedForBout = true
            }
        }
    }

    private mutating func evaluateEnd(_ out: inout [Action]) {
        let quietLine = config.restingBpm + Self.quietMarginBPM
        if endSuggested {
            // Activity resumed: withdraw the stale suggestion so a later stop can raise a fresh one.
            let resumedByHR = sustainedElevated(seconds: Self.resumeElevatedS, floor: quietLine + 5)
            let resumedByFoot = (workoutContext == .walk || workoutContext == .run) && motion.isOnFoot
                && (now - (walkBoutStart ?? now)) >= Self.walkStopGraceS
            let resumedInGym = workoutContext == .gym && inGym && resumedByHR
            if (workoutContext == .gym && resumedInGym) || (workoutContext != .gym && (resumedByHR || resumedByFoot)) {
                endSuggested = false
                out.append(.withdrawEnd)
            }
            return
        }
        let quietSpan: Int
        switch workoutContext {
        case .gym: quietSpan = Self.gymQuietEndS
        case .walk, .run: return   // motion drives walk/run ends (see evaluate)
        case nil: quietSpan = Self.otherQuietEndS
        }
        guard let started = workoutStartedAt, now - started >= quietSpan else { return }
        let window = recent(seconds: quietSpan)
        // Require reasonable coverage across the whole span, not a few samples at its tail.
        guard window.count >= quietSpan / 6, let first = window.first, first.ts - (now - quietSpan) <= 60 else { return }
        let loud = window.filter { $0.bpm >= quietLine }
        if Double(loud.count) / Double(window.count) <= Self.quietTolerance {
            endSuggested = true
            let endTs = loud.last?.ts ?? first.ts
            out.append(.suggestEnd(context: workoutContext, endTs: endTs, reason: .heartRateRecovered))
        }
    }

    // MARK: - Helpers

    private mutating func raise(_ context: Context, startTs: Int, _ out: inout [Action]) {
        pendingStart = (context, startTs)
        pendingStartRaisedAt = now
        let bpms = heartRate(from: startTs, to: now).map(\.bpm)
        let avg = bpms.isEmpty ? nil : Int((Double(bpms.reduce(0, +)) / Double(bpms.count)).rounded())
        out.append(.suggestStart(context: context, startTs: startTs, avgBpm: avg))
    }

    private mutating func clearPending(_ out: inout [Action]) {
        guard pendingStart != nil else { return }
        pendingStart = nil
        pendingStartRaisedAt = nil
        out.append(.withdrawStart)
    }

    private func recent(seconds: Int) -> [(ts: Int, bpm: Int)] {
        let from = now - seconds
        return hr.filter { $0.ts > from }
    }

    private func windowMedian(seconds: Int) -> Int? {
        let w = recent(seconds: seconds)
        guard w.count >= Self.minHRCoverageSamples else { return nil }
        let sorted = w.map(\.bpm).sorted()
        return sorted[sorted.count / 2]
    }

    private func sustainedElevated(seconds: Int, floor: Int) -> Bool {
        let w = recent(seconds: seconds)
        guard w.count >= Self.minHRCoverageSamples else { return false }
        return Double(w.filter { $0.bpm >= floor }.count) / Double(w.count) >= Self.gymElevatedFraction
    }

    /// Earliest elevated sample reachable from now without crossing a sub-floor gap longer than
    /// `elevatedStretchGapS`.
    private func elevatedStretchStart(floor: Int) -> Int? {
        var earliest: Int?
        var lastElevated: Int?
        for s in hr.reversed() {
            if s.bpm >= floor {
                if let le = lastElevated, le - s.ts > Self.elevatedStretchGapS { break }
                earliest = s.ts
                lastElevated = s.ts
            } else if let le = lastElevated, le - s.ts > Self.elevatedStretchGapS {
                break
            }
        }
        return earliest
    }
}

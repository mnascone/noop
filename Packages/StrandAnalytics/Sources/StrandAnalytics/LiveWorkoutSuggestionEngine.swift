import Foundation

// LiveWorkoutSuggestionEngine.swift — decides when a workout starts and ends, live, on the iPhone.
//
// The app layer feeds it three signals and acts on what it returns:
//   1. Places: `placeEntered` / `placeExited` from geofences the wearer pinned (a gym, an ice rink).
//      Each place carries its own start/end thresholds.
//   2. Phone motion: the CMMotionActivity classification (walking / running / stationary / automotive).
//   3. Heart rate: the smoothed live bpm, available only while the realtime stream is armed.
//
// Whether a `start` / `end` action is applied automatically or offered as a notification is the app
// layer's choice. The engine only says what happened and when, including backdated times.
//
// Heart rate costs strap battery, so the engine also says when it WANTS the stream (`wantsRealtime`):
// from arriving at a place until a workout starts there (capped), during a sustained walking bout, and
// during any active workout.
//
// Start rules:
//   - Place: inside and NOT driving for `placeMinDwellS` (driving inside a place restarts the dwell when
//     it stops, so driving past or parking for a minute starts nothing), at least `minHRCoverageSamples`
//     samples since arrival in the last
//     `startWindowS`, and at least `elevatedFraction` of them at or above resting + the place's margin.
//     Start is the first elevated sample of the current elevated stretch, never before arrival.
//   - Walk / run: a walking or running bout held for `walkMinBoutS` (`runMinBoutS` when mostly running),
//     with the window's median HR at or above resting + `walkMarginBPM` (`runMarginBPM`). With no heart
//     rate at all a bout of `walkNoHRMinBoutS` still qualifies. Start is the beginning of the bout. A walk
//     inside a place is left to the place rule.
//
// Hand-offs between a walk and a place:
//   - Arriving at a place during a walk or run ends it at the arrival (`arrivedAtPlace`). The place start
//     then needs heart rate above BOTH resting + the place's margin AND the walk's own level (its median in
//     the last 3 minutes before arrival + `liftOverWalkBPM`), so walking in doesn't start the lift: the
//     first sets do.
//   - Leaving a place ends its workout as below. For `postExitWindowS` after leaving, GPS speed (`speed`)
//     in walking range for `postExitWalkS` starts a walk from the moment you left (or from when walking
//     pace began, if later). Driving speed means no walk. The app layer feeds speed only in that window
//     (`wantsLocationUpdates`).
//
// End rules (active workout, one end until activity resumes):
//   - Place: leaving it ends the workout at the LAST elevated sample (when heart rate dropped for the last
//     time), not at the exit. Staying put with heart rate under resting + `quietMarginBPM` for the place's
//     quiet span also ends it, at the last loud sample.
//   - Walk / run: stopped for `walkStopGraceS` with heart rate back below the walk floor, or stopped for
//     `walkStopMaxS` regardless, or driving at once. End is the last moment on foot. "Stopped" is the
//     motion classifier OR GPS: during a walk the app feeds GPS speed, and GPS still for `gpsStillS`
//     counts as stopped even while the classifier (which can stick on walking) says otherwise. Heart rate
//     back under the walk floor for `walkCalmEndS` with no GPS movement also ends it, at the last
//     sample above the floor.
//   - A walking bout whose GPS sits still for `gpsStillS` (pacing around the house) doesn't start a walk.
//   - Any other workout (started by hand): heart rate quiet for `otherQuietEndS`.
//
// Pure and deterministic: no clock, no I/O. Timestamps are unix seconds supplied by the caller. Events may
// arrive slightly out of order (motion history is replayed after a background wake); the engine keeps its
// own "now" as the latest timestamp seen. iOS-only: no Kotlin twin. NOT medical advice.

public struct LiveWorkoutSuggestionEngine: Sendable {

    // MARK: - Types

    /// What a start/end is about. Encoded with `key` for notification payloads.
    public enum Context: Sendable, Equatable, Hashable {
        case place(String)
        case walk
        case run

        public var key: String {
            switch self {
            case .place(let id): return "place:" + id
            case .walk: return "walk"
            case .run: return "run"
            }
        }

        public init?(key: String) {
            switch key {
            case "walk": self = .walk
            case "run": self = .run
            default:
                guard key.hasPrefix("place:") else { return nil }
                let id = String(key.dropFirst("place:".count))
                guard !id.isEmpty else { return nil }
                self = .place(id)
            }
        }

        public var placeId: String? {
            if case .place(let id) = self { return id }
            return nil
        }
    }

    /// Phone motion classification, reduced from CMMotionActivity by the app layer.
    public enum Motion: String, Sendable, Equatable {
        case stationary, walking, running, cycling, automotive, unknown

        var isOnFoot: Bool { self == .walking || self == .running }
    }

    public enum EndReason: String, Sendable, Equatable {
        case leftPlace, stoppedMoving, startedDriving, heartRateRecovered, arrivedAtPlace
    }

    /// Per-place thresholds. Defaults suit lifting. Team sports use `sport`.
    public struct PlaceParams: Sendable, Equatable {
        /// Heart rate at or above resting + this counts as working.
        public var marginBPM: Int
        /// End after this long with heart rate near resting while still inside.
        public var quietEndS: Int

        public init(marginBPM: Int = 20, quietEndS: Int = 10 * 60) {
            self.marginBPM = max(5, marginBPM)
            self.quietEndS = max(3 * 60, quietEndS)
        }

        public static let lifting = PlaceParams(marginBPM: 20, quietEndS: 10 * 60)
        public static let sport = PlaceParams(marginBPM: 30, quietEndS: 15 * 60)
    }

    public enum Event: Sendable, Equatable {
        case placeEntered(id: String, params: PlaceParams)
        case placeExited(id: String)
        case motion(Motion)
        /// GPS ground speed in metres per second (negative = unknown, ignored).
        case speed(Double)
        case heartRate(Int)
        /// A workout became active. `context` is what started it, nil when started by hand.
        case workoutStarted(context: Context?)
        case workoutEnded
        /// The wearer declined a start offer ("Not now"), or discarded an auto-start.
        case startDismissed
        /// The wearer declined an end offer ("Keep going").
        case endDismissed
        case tick
    }

    public enum Action: Sendable, Equatable {
        case start(context: Context, startTs: Int, avgBpm: Int?)
        case withdrawStart
        case end(context: Context?, endTs: Int, reason: EndReason)
        case withdrawEnd
    }

    public struct Config: Sendable, Equatable {
        public var restingBpm: Int
        public var placesEnabled: Bool
        public var walkEnabled: Bool

        public init(restingBpm: Int, placesEnabled: Bool = true, walkEnabled: Bool = true) {
            self.restingBpm = restingBpm
            self.placesEnabled = placesEnabled
            self.walkEnabled = walkEnabled
        }
    }

    // MARK: - Tunables (named constants, fixed a priori, not fit to labels)

    public static let elevatedFraction = 0.6
    /// Time inside a place before a start can fire. Arriving out of breath settles within minutes, and the
    /// window only judges samples since arrival.
    public static let placeMinDwellS = 3 * 60
    public static let walkMarginBPM = 12
    public static let runMarginBPM = 25
    public static let startWindowS = 180
    /// Fewer samples than this in a window means "no usable heart rate" (the stream runs about 1 Hz).
    public static let minHRCoverageSamples = 30
    public static let walkMinBoutS = 5 * 60
    public static let runMinBoutS = 3 * 60
    public static let walkNoHRMinBoutS = 10 * 60
    public static let walkStopGraceS = 120
    public static let walkStopMaxS = 5 * 60
    public static let walkArmAfterS = 60
    public static let walkMaxArmS = 30 * 60
    /// Stop holding the stream for a place visit with no start after this long.
    public static let placeMaxArmS = 3 * 60 * 60
    /// An elevated stretch ends at a sub-floor gap longer than this (rest between sets is shorter).
    public static let elevatedStretchGapS = 5 * 60
    public static let quietMarginBPM = 10
    public static let quietTolerance = 0.1
    public static let otherQuietEndS = 15 * 60
    public static let resumeElevatedS = 3 * 60
    public static let pendingStartTimeoutS = 30 * 60
    /// Heart-rate history kept in memory: enough to backdate an end across a long session's tail.
    public static let hrHistoryS = 4 * 60 * 60
    /// After a walk into a place, a lift needs heart rate this far above the walk's own level.
    public static let liftOverWalkBPM = 10
    /// How long after leaving a place GPS speed is watched for a walk away.
    public static let postExitWindowS = 20 * 60
    /// Walking pace held this long after leaving a place starts a walk.
    public static let postExitWalkS = 2 * 60
    /// GPS walking pace, metres per second (about 2 to 9 km/h). Above `gpsRunMaxMps` reads as a vehicle.
    public static let gpsWalkMinMps = 0.6
    public static let gpsWalkMaxMps = 2.6
    public static let gpsRunMaxMps = 6.0
    /// GPS under walking pace this long counts as stopped, whatever the motion classifier says.
    public static let gpsStillS = 90
    /// Heart rate back under the walk floor this long, with no GPS movement, ends a walk.
    public static let walkCalmEndS = 5 * 60

    // MARK: - State

    public var config: Config
    public private(set) var now: Int = 0

    public private(set) var currentPlace: String?
    private var placeParams = PlaceParams.lifting
    private var placeEnteredAt: Int?
    private var placeStartRaised = false
    /// The walk's heart-rate level at arrival, when a walk led into this place.
    private var walkHRAtArrival: Int?
    private var lastPlaceExitTs: Int?
    private var gpsOnFootSince: Int?
    /// GPS has read under walking pace since then.
    private var gpsStillSince: Int?
    /// The last GPS fix at walking pace or faster (on foot).
    private var gpsLastMovedTs: Int?
    private var gpsRunning = false

    private var motion: Motion = .unknown
    private var walkBoutStart: Int?
    private var lastOnFootTs: Int?
    private var runSecondsInBout = 0
    private var lastMotionTs: Int?
    private var walkStartRaisedForBout = false
    private var drivingSince: Int?

    private var hr: [(ts: Int, bpm: Int)] = []

    public private(set) var workoutActive = false
    public private(set) var workoutContext: Context?
    private var workoutStartedAt: Int?
    private var workoutParams: PlaceParams?
    private var endRaised = false
    private var raisedEndReason: EndReason?

    public private(set) var pendingStart: (context: Context, startTs: Int)?
    private var pendingStartRaisedAt: Int?

    public init(config: Config) {
        self.config = config
    }

    public var inPlace: Bool { currentPlace != nil }

    /// Watch GPS speed: during a walk or run (to see it stop), while a walking bout is being judged (to
    /// see it go somewhere), and in the window after leaving a place.
    public var wantsLocationUpdates: Bool {
        guard config.walkEnabled, currentPlace == nil else { return false }
        if workoutActive, workoutContext == .walk || workoutContext == .run { return true }
        if let bout = walkBoutStart, !walkStartRaisedForBout, now - bout >= Self.walkArmAfterS,
           now - bout < Self.walkMaxArmS { return true }
        guard let exit = lastPlaceExitTs, now - exit < Self.postExitWindowS else { return false }
        return true
    }

    // MARK: - Public API

    public var wantsRealtime: Bool {
        if workoutActive { return true }
        if config.placesEnabled, currentPlace != nil, let entered = placeEnteredAt {
            if pendingStart?.context.placeId != nil { return true }
            if !placeStartRaised, now - entered < Self.placeMaxArmS { return true }
        }
        if config.walkEnabled, currentPlace == nil, let bout = walkBoutStart, !walkStartRaisedForBout {
            let dur = now - bout
            if dur >= Self.walkArmAfterS, dur < Self.walkMaxArmS { return true }
        }
        if let p = pendingStart, p.context.placeId == nil { return true }
        return false
    }

    public func heartRate(from: Int, to: Int) -> [(ts: Int, bpm: Int)] {
        hr.filter { $0.ts >= from && $0.ts <= to }
    }

    public mutating func handle(_ event: Event, at ts: Int) -> [Action] {
        now = max(now, ts)
        var out: [Action] = []

        switch event {
        case let .placeEntered(id, params):
            if currentPlace != id {
                let walkingIn = (workoutActive && (workoutContext == .walk || workoutContext == .run))
                    || walkBoutStart != nil
                walkHRAtArrival = walkingIn ? windowMedian(seconds: 180) : nil
                currentPlace = id
                placeParams = params
                placeEnteredAt = ts
                placeStartRaised = false
                lastPlaceExitTs = nil
                gpsOnFootSince = nil
                gpsStillSince = nil
                // A walk or run that brought you here ends at the door, and is saved as its own workout.
                if workoutActive, !endRaised, workoutContext == .walk || workoutContext == .run {
                    endRaised = true
                    raisedEndReason = .arrivedAtPlace
                    out.append(.end(context: workoutContext, endTs: ts, reason: .arrivedAtPlace))
                }
            }
        case .placeExited(let id):
            if currentPlace == id {
                currentPlace = nil
                placeEnteredAt = nil
                walkHRAtArrival = nil
                lastPlaceExitTs = ts
                gpsOnFootSince = nil
                // A fresh walk can start from here: whatever bout ran inside the place is over.
                walkBoutStart = motion.isOnFoot ? ts : nil
                runSecondsInBout = 0
                walkStartRaisedForBout = false
                if pendingStart?.context == .place(id) { clearPending(&out) }
                if workoutActive, !endRaised, workoutContext == .place(id) || workoutContext == nil {
                    endRaised = true
                    out.append(.end(context: workoutContext, endTs: lastElevatedTs(fallback: ts),
                                    reason: .leftPlace))
                }
            }
        case .motion(let m):
            applyMotion(m, at: ts)
        case .speed(let mps):
            applySpeed(mps, at: ts)
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
            workoutParams = workoutContext?.placeId != nil ? placeParams : nil
            endRaised = false
            pendingStart = nil
            pendingStartRaisedAt = nil
            if currentPlace != nil { placeStartRaised = true }
            if walkBoutStart != nil { walkStartRaisedForBout = true }
        case .workoutEnded:
            gpsStillSince = nil
            workoutActive = false
            workoutContext = nil
            workoutStartedAt = nil
            workoutParams = nil
            raisedEndReason = nil
            if endRaised {
                endRaised = false
                out.append(.withdrawEnd)
            }
        case .startDismissed:
            pendingStart = nil
            pendingStartRaisedAt = nil
        case .endDismissed, .tick:
            break
        }

        evaluate(&out)
        return out
    }

    // MARK: - Motion

    private mutating func applyMotion(_ m: Motion, at ts: Int) {
        if motion == .running, let since = lastMotionTs, ts > since, walkBoutStart != nil {
            runSecondsInBout += ts - since
        }
        if m.isOnFoot {
            // A fresh on-foot reading is newer evidence than a still GPS fix.
            if !motion.isOnFoot { gpsStillSince = nil }
            if walkBoutStart == nil {
                walkBoutStart = ts
                runSecondsInBout = 0
                walkStartRaisedForBout = false
            }
            lastOnFootTs = ts
        } else if motion.isOnFoot {
            lastOnFootTs = ts
        }
        // Stopped driving inside a place: the visit starts now, not when the car crossed the edge.
        if m != .automotive, motion == .automotive, currentPlace != nil, let entered = placeEnteredAt {
            placeEnteredAt = max(entered, ts)
        }
        drivingSince = (m == .automotive) ? (drivingSince ?? ts) : nil
        motion = m
        lastMotionTs = ts
    }

    private mutating func applySpeed(_ mps: Double, at ts: Int) {
        guard mps >= 0 else { return }
        if mps > Self.gpsRunMaxMps {
            gpsOnFootSince = nil
            gpsStillSince = nil
            drivingSince = drivingSince ?? ts
            return
        }
        if mps >= Self.gpsWalkMinMps {
            gpsStillSince = nil
            gpsLastMovedTs = ts
            gpsOnFootSince = gpsOnFootSince ?? ts
            gpsRunning = mps > Self.gpsWalkMaxMps
            lastOnFootTs = ts
            if walkBoutStart == nil, currentPlace == nil {
                walkBoutStart = ts
                runSecondsInBout = 0
                walkStartRaisedForBout = false
            }
        } else {
            gpsOnFootSince = nil
            gpsStillSince = gpsStillSince ?? ts
        }
    }

    /// GPS has sat under walking pace for `gpsStillS`.
    private var gpsSaysStill: Bool {
        gpsStillSince.map { now - $0 >= Self.gpsStillS } ?? false
    }

    private func stoppedFor() -> Int? {
        // GPS still outranks the motion classifier, which can keep saying walking after you've sat down.
        if gpsSaysStill, let still = gpsStillSince { return now - still }
        if motion.isOnFoot || gpsOnFootSince != nil { return 0 }
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
        if let p = currentPlace { return .place(p) }
        if walkBoutStart != nil { return boutIsRun() ? .run : .walk }
        return nil
    }

    // MARK: - Evaluation

    private mutating func evaluate(_ out: inout [Action]) {
        if let stopped = stoppedFor(), walkBoutStart != nil, !motion.isOnFoot || gpsSaysStill {
            let walkFloor = config.restingBpm + Self.walkMarginBPM
            let calm = (windowMedian(seconds: 120) ?? 0) < walkFloor
            let boutOver = drivingSince != nil
                || (stopped >= Self.walkStopGraceS && (calm || stopped >= Self.walkStopMaxS))
            if boutOver {
                // Stopped by GPS: on foot until GPS went still (the classifier may never have said otherwise).
                let endTs = gpsSaysStill
                    ? max(lastOnFootTs ?? 0, gpsStillSince ?? now)
                    : (lastOnFootTs ?? now)
                if workoutActive, !endRaised, workoutContext == .walk || workoutContext == .run {
                    endRaised = true
                    out.append(.end(context: workoutContext, endTs: endTs,
                                    reason: drivingSince != nil ? .startedDriving : .stoppedMoving))
                }
                if let p = pendingStart, p.context.placeId == nil { clearPending(&out) }
                walkBoutStart = nil
                runSecondsInBout = 0
                walkStartRaisedForBout = false
            }
        }

        evaluateCalmWalkEnd(&out)

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
        if config.placesEnabled, let place = currentPlace, !placeStartRaised, let entered = placeEnteredAt,
           motion != .automotive, drivingSince == nil, now - entered >= Self.placeMinDwellS {
            let window = recent(seconds: Self.startWindowS).filter { $0.ts >= entered }
            if window.count >= Self.minHRCoverageSamples {
                let floor = max(config.restingBpm + placeParams.marginBPM,
                                (walkHRAtArrival ?? 0) + Self.liftOverWalkBPM)
                let elevated = window.filter { $0.bpm >= floor }.count
                if Double(elevated) / Double(window.count) >= Self.elevatedFraction {
                    let start = max(entered, elevatedStretchStart(floor: floor) ?? window[0].ts)
                    raise(.place(place), startTs: start, &out)
                    placeStartRaised = true
                    return
                }
            }
        }

        // Walking away from a place, by GPS pace: start from when you left (or began walking, if later).
        if config.walkEnabled, currentPlace == nil, !walkStartRaisedForBout, let exit = lastPlaceExitTs,
           now - exit < Self.postExitWindowS, let since = gpsOnFootSince, drivingSince == nil {
            let from = max(exit, since)
            if now - from >= Self.postExitWalkS {
                raise(gpsRunning ? .run : .walk, startTs: from, &out)
                walkStartRaisedForBout = true
                return
            }
        }

        if config.walkEnabled, currentPlace == nil, let bout0 = walkBoutStart, !walkStartRaisedForBout,
           motion.isOnFoot, !gpsSaysStill {
            // A bout that began inside a place counts only from when you left it.
            let bout = max(bout0, lastPlaceExitTs ?? bout0)
            let dur = now - bout
            let isRun = boutIsRun()
            let window = recent(seconds: Self.startWindowS)
            if window.count >= Self.minHRCoverageSamples {
                guard dur >= (isRun ? Self.runMinBoutS : Self.walkMinBoutS) else { return }
                let floor = config.restingBpm + (isRun ? Self.runMarginBPM : Self.walkMarginBPM)
                if let median = windowMedian(seconds: Self.startWindowS), median >= floor {
                    raise(isRun ? .run : .walk, startTs: bout, &out)
                    walkStartRaisedForBout = true
                }
            } else if dur >= Self.walkNoHRMinBoutS {
                raise(isRun ? .run : .walk, startTs: bout, &out)
                walkStartRaisedForBout = true
            }
        }
    }

    /// A walk or run whose heart rate has been back under the walk floor for `walkCalmEndS`, with no GPS
    /// movement in that time, is over: you stopped walking somewhere the motion classifier didn't notice.
    private mutating func evaluateCalmWalkEnd(_ out: inout [Action]) {
        guard workoutActive, !endRaised, workoutContext == .walk || workoutContext == .run,
              gpsOnFootSince == nil, let started = workoutStartedAt, now - started >= Self.walkCalmEndS
        else { return }
        // Moving by GPS within the window means still walking, just gently.
        if let moved = gpsLastMovedTs, now - moved < Self.walkCalmEndS { return }
        let floor = config.restingBpm + Self.walkMarginBPM
        let window = recent(seconds: Self.walkCalmEndS)
        guard window.count >= Self.walkCalmEndS / 6, let first = window.first,
              first.ts - (now - Self.walkCalmEndS) <= 60 else { return }
        let loud = window.filter { $0.bpm >= floor }
        guard Double(loud.count) / Double(window.count) <= 0.05 else { return }
        let lastLoud = hr.last { $0.ts >= started && $0.ts <= now && $0.bpm >= floor }?.ts
        endRaised = true
        out.append(.end(context: workoutContext, endTs: lastLoud ?? first.ts, reason: .stoppedMoving))
        if let p = pendingStart, p.context.placeId == nil { clearPending(&out) }
        walkBoutStart = nil
        runSecondsInBout = 0
        walkStartRaisedForBout = false
    }

    private mutating func evaluateEnd(_ out: inout [Action]) {
        let quietLine = config.restingBpm + Self.quietMarginBPM
        if endRaised, raisedEndReason == .arrivedAtPlace {
            // Walking around the place doesn't undo the hand-off; only leaving it again does.
            if currentPlace == nil {
                endRaised = false
                raisedEndReason = nil
                out.append(.withdrawEnd)
            }
            return
        }
        if endRaised {
            let resumedByHR = sustainedElevated(seconds: Self.resumeElevatedS, floor: quietLine + 5)
            let onFootContext = workoutContext == .walk || workoutContext == .run
            let resumedByFoot = onFootContext && motion.isOnFoot
                && (now - (walkBoutStart ?? now)) >= Self.walkStopGraceS
            let resumedAtPlace = workoutContext?.placeId != nil && currentPlace == workoutContext?.placeId
                && resumedByHR
            let resumed: Bool
            if workoutContext?.placeId != nil {
                resumed = resumedAtPlace
            } else {
                resumed = resumedByHR || resumedByFoot
            }
            if resumed {
                endRaised = false
                raisedEndReason = nil
                out.append(.withdrawEnd)
            }
            return
        }
        let quietSpan: Int
        switch workoutContext {
        case .place: quietSpan = workoutParams?.quietEndS ?? PlaceParams.lifting.quietEndS
        case .walk, .run: return   // motion drives walk/run ends
        case nil: quietSpan = Self.otherQuietEndS
        }
        guard let started = workoutStartedAt, now - started >= quietSpan else { return }
        let window = recent(seconds: quietSpan)
        guard window.count >= quietSpan / 6, let first = window.first, first.ts - (now - quietSpan) <= 60 else { return }
        let loud = window.filter { $0.bpm >= quietLine }
        if Double(loud.count) / Double(window.count) <= Self.quietTolerance {
            endRaised = true
            let endTs = loud.last?.ts ?? first.ts
            out.append(.end(context: workoutContext, endTs: endTs, reason: .heartRateRecovered))
        }
    }

    // MARK: - Helpers

    /// When heart rate dropped for the last time in this workout: the last sample at or above the
    /// workout's working floor. Falls back to `fallback` when there is no heart rate at all.
    private func lastElevatedTs(fallback: Int) -> Int {
        guard let started = workoutStartedAt else { return fallback }
        let margin = workoutParams?.marginBPM ?? PlaceParams.lifting.marginBPM
        let floor = config.restingBpm + margin
        let inWorkout = hr.filter { $0.ts >= started && $0.ts <= fallback }
        guard !inWorkout.isEmpty else { return fallback }
        if let last = inWorkout.last(where: { $0.bpm >= floor }) { return last.ts }
        return started
    }

    private mutating func raise(_ context: Context, startTs: Int, _ out: inout [Action]) {
        pendingStart = (context, startTs)
        pendingStartRaisedAt = now
        let bpms = heartRate(from: startTs, to: now).map(\.bpm)
        let avg = bpms.isEmpty ? nil : Int((Double(bpms.reduce(0, +)) / Double(bpms.count)).rounded())
        out.append(.start(context: context, startTs: startTs, avgBpm: avg))
    }

    private mutating func clearPending(_ out: inout [Action]) {
        guard pendingStart != nil else { return }
        pendingStart = nil
        pendingStartRaisedAt = nil
        out.append(.withdrawStart)
    }

    private func recent(seconds: Int) -> [(ts: Int, bpm: Int)] {
        let from = now - seconds
        // Samples are time-ordered: scan back from the end instead of filtering hours of history.
        var i = hr.count
        while i > 0, hr[i - 1].ts > from { i -= 1 }
        return Array(hr[i...])
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
        return Double(w.filter { $0.bpm >= floor }.count) / Double(w.count) >= Self.elevatedFraction
    }

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

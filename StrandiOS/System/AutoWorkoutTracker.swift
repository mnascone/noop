import Foundation
import Combine
import CoreLocation
import CoreMotion
import UIKit
import UserNotifications
import WhoopProtocol
import WhoopStore
import StrandAnalytics

// MARK: - Automatic workout tracking (iOS)
//
// Starts and ends workouts on its own, the way Apple Watch does, driven by `LiveWorkoutSuggestionEngine`.
// This file is the platform half: geofences for pinned places, the phone's motion classifier, the
// realtime-HR arm, and notifications. The engine decides; this file feeds it and acts.
//
// Two modes per category (places, walks), set in the Workouts tab:
//   - Automatic: the workout starts at the backdated start and ends at the backdated end without a tap.
//     A notification says what happened, with Discard / Undo.
//   - Ask: the same moments arrive as notifications to tap.
//
// Heart rate costs strap battery, so the realtime stream is armed only while the engine wants it, through
// AppModel's ref-counted `startRealtimeHR` / `stopRealtimeHR`.
//
// Background reach, which bounds what this can see: geofence crossings wake or relaunch the app (needs
// "Always" location). Once the stream is armed, each strap update wakes it. Motion transitions missed while
// suspended are replayed from the motion coprocessor on every wake. Significant location changes (about
// 500 m, needs "Always") are an extra wake for walks. A walk that starts while the app is suspended is
// noticed at the next wake.
//
// Everything stays on device.

@MainActor
final class AutoWorkoutTracker: NSObject, ObservableObject {

    static let shared = AutoWorkoutTracker()

    // MARK: Published state

    @Published private(set) var places: [WorkoutPlace] = []
    @Published private(set) var locationAuth: CLAuthorizationStatus = .notDetermined
    @Published private(set) var holdingRealtime = false
    @Published private(set) var currentPlaceId: String?
    /// The phone's position from the last one-off request (for centering the place editor map).
    @Published private(set) var lastKnownLocation: CLLocationCoordinate2D?

    // MARK: Notification identifiers

    static let askStartCategory = "NOOP_AUTO_ASK_START"
    static let askEndCategory = "NOOP_AUTO_ASK_END"
    static let startedCategory = "NOOP_AUTO_STARTED"
    static let savedCategory = "NOOP_AUTO_SAVED"
    private static let startRequestId = "noop.auto.start"
    private static let endRequestId = "noop.auto.end"
    private static let startAction = "NOOP_AUTO_START"
    private static let notNowAction = "NOOP_AUTO_NOT_NOW"
    private static let endAction = "NOOP_AUTO_END"
    private static let keepAction = "NOOP_AUTO_KEEP"
    private static let discardAction = "NOOP_AUTO_DISCARD"
    private static let undoAction = "NOOP_AUTO_UNDO"
    private static let regionPrefix = "noop.place."
    private static let legacyRegionId = "noop.liveworkout.gym"
    private static let kContext = "context", kTs = "ts", kSport = "sport", kEndTs = "endTs"

    // MARK: Internals

    private let locationManager = CLLocationManager()
    private let motionManager = CMMotionActivityManager()
    /// The phone's step counter, read a minute at a time during a walk or run: it keeps counting indoors,
    /// where GPS has no fix and the motion classifier can stick on walking.
    private let pedometer = CMPedometer()
    private var lastStepPoll = Date.distantPast
    private var engine = LiveWorkoutSuggestionEngine(config: .init(restingBpm: 60))
    private weak var model: AppModel?
    private var cancellables: Set<AnyCancellable> = []
    private var motionUpdatesRunning = false
    private var significantChangesRunning = false
    private var lastFedActivityStart: Date?
    private var lastFedMotion: LiveWorkoutSuggestionEngine.Motion?
    private var lastCatchUp = Date.distantPast
    private var startingContext: LiveWorkoutSuggestionEngine.Context?
    /// The active workout was started by this tracker in automatic mode, so it may also end it.
    private var autoStartedWorkoutTs: Int?
    private var foregroundTimer: Timer?
    private var pendingLocationRequest: ((CLLocation?) -> Void)?

    private override init() {
        super.init()
        locationAuth = locationManager.authorizationStatus
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        places = AutoTrackingPrefs.loadPlaces()
    }

    // MARK: - Wiring

    /// Called once from `StrandiOSApp.init`, early, so a geofence event that relaunched the app reaches a
    /// delegate. Safe to call again.
    func attach(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        registerCategories()
        LiveIntervalTracker.shared.attach(model: model)
        LiveRepTracker.shared.attach(model: model)
        BatteryLog.shared.attach(model: model)

        engine.config.restingBpm = Self.restingBpm(model.repo)
        model.repo.$days
            .sink { [weak self, weak model] _ in
                guard let self, let model else { return }
                DispatchQueue.main.async { self.engine.config.restingBpm = Self.restingBpm(model.repo) }
            }
            .store(in: &cancellables)

        // The strap's own heart rate, once per update (about 1 Hz while the stream is armed). Not the
        // smoothed `bpm`, which only republishes on change and would starve the coverage checks.
        model.live.$heartRate
            .sink { [weak self] hr in
                guard let self, let hr else { return }
                self.feed(.heartRate(hr))
                if Date().timeIntervalSince(self.lastCatchUp) > 60 { self.catchUpMotion() }
            }
            .store(in: &cancellables)

        model.$activeWorkout
            .map { $0.map { Int($0.start.timeIntervalSince1970) } }
            .removeDuplicates()
            .sink { [weak self] startTs in
                guard let self else { return }
                if startTs != nil {
                    let ctx = self.startingContext
                    self.startingContext = nil
                    self.removeNotification(Self.startRequestId)
                    self.feed(.workoutStarted(context: ctx))
                } else {
                    self.autoStartedWorkoutTs = nil
                    self.feed(.workoutEnded)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.wake() }
            .store(in: &cancellables)
        // The phone's battery, a line in the log at each 1% while the app runs, with what was on: so a
        // heavy drain can be put down to GPS, the live heart-rate stream, or neither.
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.logPhoneBattery() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.foregroundTimer?.invalidate(); self?.foregroundTimer = nil }
            .store(in: &cancellables)

        NotificationPresenter.shared.onWorkoutSuggestionResponse = { [weak self] response in
            let run = { () -> Bool in
                MainActor.assumeIsolated { self?.handle(response: response) ?? false }
            }
            return Thread.isMainThread ? run() : DispatchQueue.main.sync(execute: run)
        }

        applySettings()
    }

    /// Re-read settings and places, and start or stop the platform monitors to match.
    func applySettings() {
        let placesOn = AutoTrackingPrefs.placesEnabled
        let walkOn = AutoTrackingPrefs.walkEnabled
        engine.config.placesEnabled = placesOn
        engine.config.walkEnabled = walkOn
        places = AutoTrackingPrefs.loadPlaces()
        syncRegions(enabled: placesOn)

        // Motion runs for places too: it's how an arrival tells parking from driving past.
        if walkOn || placesOn, CMMotionActivityManager.isActivityAvailable() {
            if !motionUpdatesRunning {
                motionUpdatesRunning = true
                motionManager.startActivityUpdates(to: .main) { [weak self] activity in
                    guard let self, let activity else { return }
                    MainActor.assumeIsolated { self.ingest([activity]) }
                }
            }
            catchUpMotion()
        } else if motionUpdatesRunning {
            motionManager.stopActivityUpdates()
            motionUpdatesRunning = false
        }

        let wantSignificant = walkOn && locationManager.authorizationStatus == .authorizedAlways
            && CLLocationManager.significantLocationChangeMonitoringAvailable()
        if wantSignificant, !significantChangesRunning {
            locationManager.startMonitoringSignificantLocationChanges()
            significantChangesRunning = true
        } else if !wantSignificant, significantChangesRunning {
            locationManager.stopMonitoringSignificantLocationChanges()
            significantChangesRunning = false
        }

        syncRealtime()
        startForegroundTimerIfNeeded()
    }

    /// Register one geofence per place. Only regions that changed are re-registered: this runs at every
    /// launch, including the background launch iOS performs for a crossing, and dropping a region there
    /// could lose the event that woke the app.
    private func syncRegions(enabled: Bool) {
        let monitored = locationManager.monitoredRegions.compactMap { $0 as? CLCircularRegion }
            .filter { $0.identifier.hasPrefix(Self.regionPrefix) || $0.identifier == Self.legacyRegionId }
        var wanted: [String: CLCircularRegion] = [:]
        if enabled && CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) {
            // iOS allows 20 monitored regions per app.
            for p in places.prefix(19) {
                let center = CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude)
                // At least the wake size: smaller circles are checked by GPS once this fires.
                let radius = min(max(p.radiusM, Self.wakeRadiusM), locationManager.maximumRegionMonitoringDistance)
                let r = CLCircularRegion(center: center, radius: radius, identifier: Self.regionPrefix + p.id)
                r.notifyOnEntry = true
                r.notifyOnExit = true
                wanted[r.identifier] = r
            }
        }
        for region in monitored {
            if let w = wanted[region.identifier], Self.same(w, region) {
                locationManager.requestState(for: region)
            } else {
                locationManager.stopMonitoring(for: region)
                if let id = Self.placeId(from: region.identifier), engine.currentPlace == id {
                    feed(.placeExited(id: id))
                }
            }
        }
        let kept = Set(monitored.map(\.identifier).filter { id in
            guard let w = wanted[id], let m = monitored.first(where: { $0.identifier == id }) else { return false }
            return Self.same(w, m)
        })
        for (id, region) in wanted where !kept.contains(id) {
            locationManager.startMonitoring(for: region)
        }
    }

    private static func same(_ a: CLCircularRegion, _ b: CLCircularRegion) -> Bool {
        abs(a.center.latitude - b.center.latitude) < 1e-6 && abs(a.center.longitude - b.center.longitude) < 1e-6
            && abs(a.radius - b.radius) < 0.5
    }

    private static func placeId(from regionId: String) -> String? {
        regionId.hasPrefix(regionPrefix) ? String(regionId.dropFirst(regionPrefix.count)) : nil
    }

    func requestPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        switch locationManager.authorizationStatus {
        case .notDetermined, .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
        default:
            break
        }
        if AutoTrackingPrefs.walkEnabled, CMMotionActivityManager.isActivityAvailable() {
            let now = Date()
            motionManager.queryActivityStarting(from: now.addingTimeInterval(-60), to: now, to: .main) { _, _ in }
        }
    }

    // MARK: - Places

    func savePlace(_ place: WorkoutPlace) {
        var all = AutoTrackingPrefs.loadPlaces()
        if let i = all.firstIndex(where: { $0.id == place.id }) { all[i] = place } else { all.append(place) }
        AutoTrackingPrefs.savePlaces(all)
        applySettings()
    }

    func deletePlace(id: String) {
        AutoTrackingPrefs.savePlaces(AutoTrackingPrefs.loadPlaces().filter { $0.id != id })
        applySettings()
    }

    func place(id: String?) -> WorkoutPlace? {
        guard let id else { return nil }
        return places.first { $0.id == id }
    }

    /// One-off location fix, for "use my location" in the place editor.
    func requestCurrentLocation(_ done: @escaping (CLLocation?) -> Void) {
        switch locationManager.authorizationStatus {
        case .denied, .restricted:
            done(nil)
            return
        case .notDetermined:
            locationManager.requestAlwaysAuthorization()
        default:
            break
        }
        pendingLocationRequest = done
        locationManager.requestLocation()
    }

    // MARK: - Engine plumbing

    private func feed(_ event: LiveWorkoutSuggestionEngine.Event, at date: Date = Date()) {
        let actions = engine.handle(event, at: Int(date.timeIntervalSince1970))
        for action in actions {
            switch action {
            case .withdrawStart, .withdrawEnd: perform(action)
            case .start, .end: if AutoTrackingPrefs.anyEnabled { perform(action) }
            }
        }
        if currentPlaceId != engine.currentPlace { currentPlaceId = engine.currentPlace }
        syncRealtime()
        syncLocationUpdates()
        pollStepsIfWalking()
    }

    /// During a walk or run, once a minute: the last five minutes' steps, a minute at a time.
    private func pollStepsIfWalking() {
        guard engine.workoutActive, engine.workoutContext == .walk || engine.workoutContext == .run,
              CMPedometer.isStepCountingAvailable(), Date().timeIntervalSince(lastStepPoll) >= 60 else { return }
        lastStepPoll = Date()
        let thisMinute = (Int(Date().timeIntervalSince1970) / 60) * 60
        for back in 1...5 {
            let start = thisMinute - back * 60
            let from = Date(timeIntervalSince1970: TimeInterval(start))
            pedometer.queryPedometerData(from: from, to: from.addingTimeInterval(60)) { [weak self] data, _ in
                guard let data else { return }
                let steps = data.numberOfSteps.intValue
                DispatchQueue.main.async {
                    self?.feed(.steps(minuteStart: start, count: steps))
                }
            }
        }
    }

    /// GPS speed while the engine wants it: during a walk or run (so it can tell when you've stopped, even
    /// when the motion classifier still says walking), while a walking bout is being judged, and in the
    /// window after leaving a place. Off the rest of the time: continuous location costs phone battery.
    private var watchingSpeed = false
    /// GPS is on, for walking pace or for checking an arrival.
    private var updatingLocation = false
    /// The last good fix, for working out speed when a fix carries none.
    private var lastSpeedFix: CLLocation?

    // MARK: Arrivals
    //
    // iOS geofences are coarse (they fire somewhere around 100-200 m out, and late), so a crossing only
    // WAKES the check. A place counts as arrived when precise GPS puts you inside YOUR circle, slower than
    // walking pace and not in a car, for `arrivalConfirmS`. Driving past, stopping at the light outside,
    // or the coffee shop next door never gets that far. The visit, and its dwell, start at the first fix
    // that held.

    /// The registered geofence is at least this big, whatever the circle: iOS doesn't fire reliably on
    /// smaller ones. The circle itself is checked by GPS.
    static let wakeRadiusM = 120.0
    static let arrivalConfirmS: TimeInterval = 45
    /// Stop checking a crossing that hasn't become an arrival after this long.
    static let arrivalWatchMaxS: TimeInterval = 20 * 60
    /// Inside the geofence, not yet confirmed: when the check began, and the first fix that's held since.
    private var arriving: [String: (since: Date, heldFrom: Date?)] = [:]

    /// A check that didn't become an arrival isn't started again for this long: living or working near a
    /// place would otherwise keep precise GPS on, a check at every wake.
    static let arrivalRetryS: TimeInterval = 30 * 60
    private var lastFailedArrivalCheck: [String: Date] = [:]

    private func beginArrivalCheck(_ id: String) {
        guard engine.currentPlace != id, arriving[id] == nil else { return }
        if let failed = lastFailedArrivalCheck[id], Date().timeIntervalSince(failed) < Self.arrivalRetryS { return }
        arriving[id] = (Date(), nil)
        if let p = place(id: id) { log("auto: near \(p.name), checking you've arrived") }
        syncLocationUpdates()
    }

    /// One fix against every place being checked.
    private func checkArrivals(_ fix: CLLocation) {
        guard !arriving.isEmpty else { return }
        // Time out first, whatever the fix: indoors every fix can be too loose to use, and a check that
        // never times out keeps precise GPS on for good.
        for (id, state) in arriving where Date().timeIntervalSince(state.since) > Self.arrivalWatchMaxS {
            arriving[id] = nil
            lastFailedArrivalCheck[id] = Date()
            log("auto: didn't settle at \(place(id: id)?.name ?? id), stopped checking")
        }
        guard !arriving.isEmpty, fix.horizontalAccuracy >= 0, fix.horizontalAccuracy < 100,
              Date().timeIntervalSince(fix.timestamp) < 30 else {
            syncLocationUpdates()
            return
        }
        for (id, state) in arriving {
            guard let p = place(id: id) else { arriving[id] = nil; continue }
            let centre = CLLocation(latitude: p.latitude, longitude: p.longitude)
            // Half the fix's uncertainty (at most 40 m) counts in your favour: indoors GPS is loose.
            let inside = fix.distance(from: centre) - min(fix.horizontalAccuracy * 0.5, 40) <= p.radiusM
            let slow = fix.speed < 0 || fix.speed < 2.0
            let notDriving = lastFedMotion != .automotive
            guard inside, slow, notDriving else {
                arriving[id] = (state.since, nil)
                continue
            }
            let held = state.heldFrom ?? fix.timestamp
            if fix.timestamp.timeIntervalSince(held) >= Self.arrivalConfirmS {
                arriving[id] = nil
                log("auto: arrived at \(p.name)")
                feed(.placeEntered(id: id, params: p.params), at: held)
            } else {
                arriving[id] = (state.since, held)
            }
        }
        syncLocationUpdates()
    }

    private func syncLocationUpdates() {
        let authorized = locationAuth == .authorizedAlways || locationAuth == .authorizedWhenInUse
        let wantSpeed = engine.wantsLocationUpdates && AutoTrackingPrefs.walkEnabled && authorized
        let wantArrival = !arriving.isEmpty && AutoTrackingPrefs.placesEnabled && authorized
        if wantSpeed != watchingSpeed {
            watchingSpeed = wantSpeed
            lastSpeedFix = nil
            if wantSpeed { log("auto: watching walking pace by GPS") }
        }
        let want = wantSpeed || wantArrival
        locationManager.desiredAccuracy = wantArrival ? kCLLocationAccuracyBest : kCLLocationAccuracyNearestTenMeters
        if want, !updatingLocation {
            updatingLocation = true
            if locationAuth == .authorizedAlways { locationManager.allowsBackgroundLocationUpdates = true }
            // Keep fixes coming while standing still: a stop, or settling in, is exactly what this watches for.
            locationManager.pausesLocationUpdatesAutomatically = false
            locationManager.activityType = .fitness
            locationManager.startUpdatingLocation()
        } else if !want, updatingLocation {
            updatingLocation = false
            locationManager.stopUpdatingLocation()
            locationManager.allowsBackgroundLocationUpdates = false
            lastSpeedFix = nil
        }
    }

    private func syncRealtime() {
        guard let model else { return }
        let want = engine.wantsRealtime && AutoTrackingPrefs.anyEnabled
        if want, !holdingRealtime {
            holdingRealtime = true
            model.startRealtimeHR()
            log("auto: live heart rate on")
        } else if !want, holdingRealtime {
            holdingRealtime = false
            model.stopRealtimeHR()
            log("auto: live heart rate off")
        }
    }

    private func logPhoneBattery() {
        let level = UIDevice.current.batteryLevel
        guard level >= 0, let model else { return }
        let charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        var on: [String] = []
        if updatingLocation { on.append(watchingSpeed ? "GPS (walk pace)" : "GPS (arriving)") }
        if model.ble.realtimeStreaming { on.append(holdingRealtime ? "live HR (auto tracking)" : "live HR") }
        if model.activeWorkout != nil { on.append("workout") }
        let app = UIApplication.shared.applicationState == .active ? "on screen" : "background"
        log("phone battery \(Int((level * 100).rounded()))%\(charging ? " charging" : "") · \(app)"
            + (on.isEmpty ? "" : " · " + on.joined(separator: ", ")))
    }

    private func wake() {
        feed(.tick)
        catchUpMotion()
        startForegroundTimerIfNeeded()
    }

    private func startForegroundTimerIfNeeded() {
        guard foregroundTimer == nil, UIApplication.shared.applicationState == .active,
              AutoTrackingPrefs.anyEnabled else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.feed(.tick) }
        }
        t.tolerance = 5
        foregroundTimer = t
    }

    private static func restingBpm(_ repo: Repository) -> Int {
        repo.today?.restingHr ?? repo.days.last(where: { $0.restingHr != nil })?.restingHr ?? 60
    }

    // MARK: - Motion

    private static func classify(_ a: CMMotionActivity) -> LiveWorkoutSuggestionEngine.Motion {
        if a.automotive && a.confidence != .low { return .automotive }
        if a.cycling { return .cycling }
        if a.running { return .running }
        if a.walking { return .walking }
        if a.stationary { return .stationary }
        return .unknown
    }

    private func ingest(_ activities: [CMMotionActivity]) {
        for a in activities.sorted(by: { $0.startDate < $1.startDate }) {
            if let last = lastFedActivityStart, a.startDate <= last { continue }
            let m = Self.classify(a)
            lastFedActivityStart = a.startDate
            guard m != .unknown, m != lastFedMotion else { continue }
            lastFedMotion = m
            feed(.motion(m), at: a.startDate)
        }
    }

    private func catchUpMotion() {
        guard AutoTrackingPrefs.anyEnabled, CMMotionActivityManager.isActivityAvailable() else { return }
        lastCatchUp = Date()
        let now = Date()
        let from = max(lastFedActivityStart ?? .distantPast, now.addingTimeInterval(-45 * 60))
        motionManager.queryActivityStarting(from: from, to: now, to: .main) { [weak self] activities, _ in
            guard let self, let activities else { return }
            MainActor.assumeIsolated {
                self.ingest(activities)
                self.feed(.tick)
            }
        }
    }

    // MARK: - Acting on the engine

    private func mode(for context: LiveWorkoutSuggestionEngine.Context?) -> AutoTrackingPrefs.Mode {
        switch context {
        case .place: return AutoTrackingPrefs.placesMode
        case .walk, .run: return AutoTrackingPrefs.walkMode
        case nil: return .ask
        }
    }

    private func sport(for context: LiveWorkoutSuggestionEngine.Context) -> String {
        switch context {
        case .place(let id): return place(id: id)?.sport ?? "Strength"
        case .walk: return "Walking"
        case .run: return "Running"
        }
    }

    private func contextLabel(_ context: LiveWorkoutSuggestionEngine.Context) -> String {
        switch context {
        case .place(let id): return place(id: id)?.name ?? String(localized: "your spot")
        case .walk: return String(localized: "a walk")
        case .run: return String(localized: "a run")
        }
    }

    private func perform(_ action: LiveWorkoutSuggestionEngine.Action) {
        switch action {
        case let .start(context, startTs, avgBpm):
            let apply = { [weak self] (start: Int) in
                guard let self else { return }
                if self.mode(for: context) == .auto {
                    self.autoStart(context: context, startTs: start)
                } else {
                    self.postAskStart(context: context, startTs: start, avgBpm: avgBpm)
                }
            }
            if context == .walk || context == .run {
                refineOnFootStart(startTs) { apply($0) }
            } else {
                apply(startTs)
            }
        case .withdrawStart:
            removeNotification(Self.startRequestId)
        case let .end(context, endTs, reason):
            let auto = autoStartedWorkoutTs != nil || (context != nil && mode(for: context) == .auto)
            if auto {
                autoEnd(endTs: endTs, reason: reason)
            } else {
                postAskEnd(endTs: endTs, reason: reason)
            }
        case .withdrawEnd:
            removeNotification(Self.endRequestId)
        }
    }

    // MARK: When a walk really began

    /// Good GPS fixes from the last half hour, while GPS is on for walking pace.
    private var recentFixes: [CLLocation] = []
    /// A walk is detected some minutes in (the motion classifier is slow to say "walking", and a bout must
    /// hold before it counts). Its start goes back to when you actually set off: the earliest minute of
    /// the walking stretch the pedometer counted (it keeps counting while the app sleeps), or the first GPS
    /// fix of the moving track, whichever is earlier. At most 20 minutes back, never before the last
    /// workout ended.
    static let refineBackS = 20 * 60
    static let walkingStepsPerMin = 40

    private func refineOnFootStart(_ startTs: Int, done: @escaping (Int) -> Void) {
        let floorTs = max(startTs - Self.refineBackS, model?.lastWorkout?.endTs ?? 0)
        var candidates = [startTs]
        if let gps = gpsTrackStart(before: startTs), gps >= floorTs { candidates.append(gps) }
        guard CMPedometer.isStepCountingAvailable() else {
            done(candidates.min() ?? startTs)
            return
        }
        // Per-minute steps from 20 minutes before the detected start to a minute after it.
        let first = (floorTs / 60) * 60
        let last = (startTs / 60) * 60 + 60
        let minutes = Array(stride(from: first, through: last, by: 60))
        var counts: [Int: Int] = [:]
        let group = DispatchGroup()
        let lock = NSLock()
        for m in minutes {
            group.enter()
            let from = Date(timeIntervalSince1970: TimeInterval(m))
            pedometer.queryPedometerData(from: from, to: from.addingTimeInterval(60)) { data, _ in
                if let n = data?.numberOfSteps.intValue { lock.lock(); counts[m] = n; lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            // Walk back from the detected start while minutes are walking; one slow minute (a crossing)
            // doesn't break the stretch, two do.
            var earliest: Int?
            var slow = 0
            var m = (startTs / 60) * 60
            while m >= first {
                if (counts[m] ?? 0) >= Self.walkingStepsPerMin {
                    earliest = m
                    slow = 0
                } else {
                    slow += 1
                    if slow >= 2 { break }
                }
                m -= 60
            }
            if let e = earliest, e >= floorTs { candidates.append(e) }
            let refined = candidates.min() ?? startTs
            if refined < startTs { self?.log("auto: walk start moved back \((startTs - refined) / 60) min by steps/GPS") }
            done(refined)
        }
    }

    /// The first fix of the moving track that ends at the detected start: walk back while each fix is at
    /// least walking pace from the one before.
    private func gpsTrackStart(before startTs: Int) -> Int? {
        // One fix per 20 s or more, so the distance between them outruns GPS noise.
        var fixes: [CLLocation] = []
        for f in recentFixes where Int(f.timestamp.timeIntervalSince1970) <= startTs + 60 {
            if let last = fixes.last, f.timestamp.timeIntervalSince(last.timestamp) < 20 { continue }
            fixes.append(f)
        }
        guard fixes.count >= 2 else { return nil }
        var earliest: Int?
        var i = fixes.count - 1
        while i > 0 {
            let a = fixes[i - 1], b = fixes[i]
            let dt = b.timestamp.timeIntervalSince(a.timestamp)
            guard dt > 0, dt <= 120 else { break }
            let moved = b.distance(from: a) - (a.horizontalAccuracy + b.horizontalAccuracy) / 2
            guard moved / dt >= LiveWorkoutSuggestionEngine.gpsWalkMinMps * 0.8 else { break }
            earliest = Int(a.timestamp.timeIntervalSince1970)
            i -= 1
        }
        return earliest
    }

    private func autoStart(context: LiveWorkoutSuggestionEngine.Context, startTs: Int) {
        guard let model, model.activeWorkout == nil else { return }
        let sportName = sport(for: context)
        begin(model: model, context: context, sport: sportName, startTs: startTs)
        autoStartedWorkoutTs = model.activeWorkout.map { Int($0.start.timeIntervalSince1970) }
        let at = Self.time(startTs)
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(sportName) started")
        content.body = String(localized: "Heart rate went up at \(contextLabel(context)), so it's on from \(at). It'll stop on its own.")
        content.categoryIdentifier = Self.startedCategory
        content.userInfo = [Self.kTs: autoStartedWorkoutTs ?? startTs, Self.kSport: sportName]
        content.threadIdentifier = "noop.auto"
        add(id: Self.startRequestId, content: content, quiet: true)
        log("auto: started \(sportName) context=\(context.key) backdate=\(Int(Date().timeIntervalSince1970) - startTs)s")
    }

    private func autoEnd(endTs: Int, reason: LiveWorkoutSuggestionEngine.EndReason) {
        guard let model, model.activeWorkout != nil else { return }
        model.endWorkout(endedAt: Date(timeIntervalSince1970: TimeInterval(endTs)))
        removeNotification(Self.startRequestId)
        guard let row = model.lastWorkout else {
            log("auto: ended, too short to keep")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(row.sport) saved")
        var body = String(localized: "\(Self.time(row.startTs))–\(Self.time(row.endTs)), \(Self.duration(row.endTs - row.startTs)).")
        switch reason {
        case .leftPlace: body += " " + String(localized: "Ended when your heart rate last dropped, before you left.")
        case .heartRateRecovered: body += " " + String(localized: "Ended when your heart rate settled.")
        case .stoppedMoving: body += " " + String(localized: "Ended when you stopped moving.")
        case .startedDriving: body += " " + String(localized: "Ended when you got in a car.")
        case .arrivedAtPlace: body += " " + String(localized: "Ended when you arrived. The next workout starts when your heart rate climbs past your walking level.")
        }
        if let notes = row.notes, !notes.isEmpty { body += "\n" + notes }
        content.body = body
        content.categoryIdentifier = Self.savedCategory
        content.userInfo = [Self.kTs: row.startTs, Self.kSport: row.sport, Self.kEndTs: row.endTs]
        content.threadIdentifier = "noop.auto"
        add(id: Self.endRequestId, content: content, quiet: true)
        log("auto: saved \(row.sport) reason=\(reason.rawValue)")
    }

    private func postAskStart(context: LiveWorkoutSuggestionEngine.Context, startTs: Int, avgBpm: Int?) {
        let sportName = sport(for: context)
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(sportName)?")
        var body = String(localized: "Heart rate's up at \(contextLabel(context)) since \(Self.time(startTs)). Tap to start it from then.")
        if let avgBpm { body += " " + String(localized: "Averaging \(avgBpm) bpm.") }
        content.body = body
        content.categoryIdentifier = Self.askStartCategory
        content.userInfo = [Self.kContext: context.key, Self.kTs: startTs, Self.kSport: sportName]
        content.threadIdentifier = "noop.auto"
        add(id: Self.startRequestId, content: content, quiet: false)
        log("auto: asked to start context=\(context.key)")
    }

    private func postAskEnd(endTs: Int, reason: LiveWorkoutSuggestionEngine.EndReason) {
        let at = Self.time(endTs)
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Done?")
        switch reason {
        case .leftPlace: content.body = String(localized: "You left. Your heart rate last dropped at \(at). End it there?")
        case .stoppedMoving: content.body = String(localized: "You stopped moving at \(at). End it there?")
        case .startedDriving: content.body = String(localized: "Looks like you're in a car. End it at \(at)?")
        case .heartRateRecovered: content.body = String(localized: "Heart rate's been low since \(at). End it there?")
        case .arrivedAtPlace: content.body = String(localized: "You arrived at \(at). End the walk there?")
        }
        content.categoryIdentifier = Self.askEndCategory
        content.userInfo = [Self.kEndTs: endTs]
        content.threadIdentifier = "noop.auto"
        add(id: Self.endRequestId, content: content, quiet: false)
        log("auto: asked to end reason=\(reason.rawValue)")
    }

    private func begin(model: AppModel, context: LiveWorkoutSuggestionEngine.Context?, sport: String, startTs: Int) {
        let nowTs = Int(Date().timeIntervalSince1970)
        let seeds = engine.heartRate(from: startTs, to: nowTs).map { HRSample(ts: $0.ts, bpm: $0.bpm) }
        startingContext = context
        model.startWorkout(sport: sport, startedAt: Date(timeIntervalSince1970: TimeInterval(startTs)),
                           seedSamples: seeds)
    }

    // MARK: - Notifications

    private func add(id: String, content: UNMutableNotificationContent, quiet: Bool) {
        content.sound = quiet ? nil : .default
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    private func removeNotification(_ id: String) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    private func registerCategories() {
        func action(_ id: String, _ title: String, destructive: Bool = false) -> UNNotificationAction {
            UNNotificationAction(identifier: id, title: title, options: destructive ? [.destructive] : [])
        }
        let cats: [UNNotificationCategory] = [
            UNNotificationCategory(identifier: Self.askStartCategory,
                                   actions: [action(Self.startAction, String(localized: "Start")),
                                             action(Self.notNowAction, String(localized: "Not now"))],
                                   intentIdentifiers: [], options: [.customDismissAction]),
            UNNotificationCategory(identifier: Self.askEndCategory,
                                   actions: [action(Self.endAction, String(localized: "End it"), destructive: true),
                                             action(Self.keepAction, String(localized: "Keep going"))],
                                   intentIdentifiers: [], options: [.customDismissAction]),
            UNNotificationCategory(identifier: Self.startedCategory,
                                   actions: [action(Self.discardAction, String(localized: "Discard"), destructive: true)],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.savedCategory,
                                   actions: [action(Self.undoAction, String(localized: "Delete it"), destructive: true)],
                                   intentIdentifiers: [], options: []),
        ]
        let ours = Set(cats.map(\.identifier))
        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { existing in
            var all = existing.filter { !ours.contains($0.identifier) }
            for c in cats { all.insert(c) }
            center.setNotificationCategories(all)
        }
    }

    /// Route a tapped notification. Returns false for notifications this feature doesn't own.
    func handle(response: UNNotificationResponse) -> Bool {
        let content = response.notification.request.content
        let info = content.userInfo
        switch content.categoryIdentifier {
        case Self.askStartCategory:
            switch response.actionIdentifier {
            case Self.startAction, UNNotificationDefaultActionIdentifier:
                acceptAskStart(info)
            default:
                feed(.startDismissed)
            }
            return true
        case Self.askEndCategory:
            switch response.actionIdentifier {
            case Self.endAction:
                if let endTs = info[Self.kEndTs] as? Int {
                    model?.endWorkout(endedAt: Date(timeIntervalSince1970: TimeInterval(endTs)))
                }
            case Self.keepAction, UNNotificationDismissActionIdentifier:
                feed(.endDismissed)
            default:
                break
            }
            return true
        case Self.startedCategory:
            if response.actionIdentifier == Self.discardAction { discard(info) }
            return true
        case Self.savedCategory:
            if response.actionIdentifier == Self.undoAction { deleteSaved(info) }
            return true
        default:
            return false
        }
    }

    private func acceptAskStart(_ info: [AnyHashable: Any]) {
        guard let model, model.activeWorkout == nil else { return }
        let ctx = (info[Self.kContext] as? String).flatMap(LiveWorkoutSuggestionEngine.Context.init(key:))
        let startTs = (info[Self.kTs] as? Int) ?? Int(Date().timeIntervalSince1970)
        let sportName = (info[Self.kSport] as? String) ?? ctx.map(sport(for:)) ?? WorkoutCatalog.defaultSportName
        begin(model: model, context: ctx, sport: sportName, startTs: startTs)
    }

    /// Discard an auto-started workout: drop it if it's still running, delete it if it already saved.
    private func discard(_ info: [AnyHashable: Any]) {
        guard let model, let ts = info[Self.kTs] as? Int else { return }
        if let w = model.activeWorkout, Int(w.start.timeIntervalSince1970) == ts {
            model.discardWorkout()
            feed(.startDismissed)
            log("auto: discarded running workout")
        } else {
            deleteSaved(info)
        }
    }

    private func deleteSaved(_ info: [AnyHashable: Any]) {
        guard let model, let ts = info[Self.kTs] as? Int, let sport = info[Self.kSport] as? String else { return }
        let box = BackgroundTaskBox()
        box.id = UIApplication.shared.beginBackgroundTask(withName: "noop.auto.delete") { box.end() }
        Task { @MainActor [weak self] in
            defer { box.end() }
            let rows = await model.repo.workoutRows(days: 30)
            if let row = rows.first(where: { $0.startTs == ts && $0.sport == sport && $0.source == "manual" }) {
                await model.repo.deleteWorkout(row)
                await model.repo.refresh()
                self?.log("auto: deleted saved workout")
            }
        }
    }

    // MARK: - Formatting / log

    static func time(_ ts: Int) -> String {
        AppClock.hourMinuteFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    static func duration(_ seconds: Int) -> String {
        let m = max(0, seconds) / 60
        return m >= 60 ? String(localized: "\(m / 60)h \(m % 60)m") : String(localized: "\(m) min")
    }

    private func log(_ line: String) {
        model?.live.append(log: AppModel.stamped(line))
    }
}

@MainActor
private final class BackgroundTaskBox {
    var id: UIBackgroundTaskIdentifier = .invalid
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

// MARK: - CLLocationManagerDelegate

extension AutoWorkoutTracker: @preconcurrency CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        locationAuth = manager.authorizationStatus
        applySettings()
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard let id = Self.placeId(from: region.identifier), let p = place(id: id) else { return }
        switch state {
        case .inside:
            // Near, not yet there: GPS confirms you've stopped inside your circle, out of the car.
            beginArrivalCheck(id)
        case .outside:
            arriving[id] = nil
            if engine.currentPlace == id { log("auto: left \(p.name)") }
            feed(.placeExited(id: id))
            syncLocationUpdates()
        case .unknown:
            break
        }
        catchUpMotion()
    }

    func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        if Self.placeId(from: region.identifier) != nil { manager.requestState(for: region) }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let done = pendingLocationRequest {
            pendingLocationRequest = nil
            let best = locations.min(by: { $0.horizontalAccuracy < $1.horizontalAccuracy })
            if let best { lastKnownLocation = best.coordinate }
            done(best)
            return
        }
        if !arriving.isEmpty, let best = locations.min(by: { $0.horizontalAccuracy < $1.horizontalAccuracy }) {
            checkArrivals(best)
        }
        if watchingSpeed {
            // Kept for working out, at a start, when the walk really began.
            for loc in locations where loc.horizontalAccuracy >= 0 && loc.horizontalAccuracy < 30 {
                recentFixes.append(loc)
            }
            if let f = recentFixes.first, Date().timeIntervalSince(f.timestamp) > 1800 {
                recentFixes.removeAll { Date().timeIntervalSince($0.timestamp) > 1800 }
            }
            for loc in locations where loc.horizontalAccuracy >= 0 && loc.horizontalAccuracy < 50 {
                if let mps = Self.speed(of: loc, after: lastSpeedFix) { feed(.speed(mps), at: loc.timestamp) }
                // The reference fix for derived speed moves on only every 45 s, so the distance between
                // them outruns GPS noise.
                if lastSpeedFix.map({ loc.timestamp.timeIntervalSince($0.timestamp) >= 45 }) ?? true,
                   loc.horizontalAccuracy < 20 {
                    lastSpeedFix = loc
                }
            }
        }
        // Fixes can come every second while watching; motion history only needs replaying once a minute.
        feed(.tick)
        if Date().timeIntervalSince(lastCatchUp) > 60 { catchUpMotion() }
        startForegroundTimerIfNeeded()
    }

    /// The fix's own speed, or distance over time from the fix before when it has none (indoors, weak
    /// signal). nil when neither can be trusted.
    private static func speed(of loc: CLLocation, after prev: CLLocation?) -> Double? {
        if loc.speed >= 0, loc.speedAccuracy < 0 || loc.speedAccuracy < 1.5 { return loc.speed }
        guard let prev, loc.horizontalAccuracy < 20 else { return nil }
        let dt = loc.timestamp.timeIntervalSince(prev.timestamp)
        guard dt >= 45, dt <= 180 else { return nil }
        let d = loc.distance(from: prev)
        // Movement within the fixes' own uncertainty is no movement.
        let noise = loc.horizontalAccuracy + prev.horizontalAccuracy
        return d <= noise ? 0 : (d - noise) / dt
    }

    /// iOS paused updates because the phone stopped moving: that's a stop.
    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        if watchingSpeed { feed(.speed(0)) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let done = pendingLocationRequest {
            pendingLocationRequest = nil
            done(nil)
        }
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        if let r = region, Self.placeId(from: r.identifier) != nil {
            log("auto: a place geofence failed to start")
        }
    }
}

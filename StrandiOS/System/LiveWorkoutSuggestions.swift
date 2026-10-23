import Foundation
import Combine
import CoreLocation
import CoreMotion
import UIKit
import UserNotifications
import WhoopProtocol
import StrandAnalytics

// MARK: - Live workout suggestions (iOS)
//
// Apple-Watch-style "start workout?" / "end workout?" notifications for the iPhone, driven by
// `LiveWorkoutSuggestionEngine`. This file is the platform half: it owns the gym geofence, the phone's
// motion classifier, the realtime-HR arm, and the actionable notifications. The engine decides; this file
// only feeds it and acts on what it returns.
//
// Hybrid heart rate: the realtime HR stream costs strap battery, so it is armed only while the engine asks
// for it (gym arrival until a start suggestion is resolved, a sustained walking bout, an active workout).
// The arm goes through AppModel's ref-counted `startRealtimeHR` / `stopRealtimeHR`, so it composes with the
// Live screen and live sessions instead of fighting them.
//
// How the app gets CPU time in the background, which bounds what this can see:
//   - Gym geofence: iOS wakes (or relaunches) the app on region entry and exit. Needs "Always" location.
//   - Realtime HR notifies: once armed, each beat-rate update from the strap wakes the app, which keeps
//     the engine ticking for the whole gym visit or walk.
//   - Motion: CMMotionActivity updates are only delivered while the app runs, so missed transitions are
//     replayed from the coprocessor's history on every wake (`catchUpMotion`). Significant location
//     changes (about 500 m of movement, needs "Always") are subscribed as an extra wake source for walks.
//   A walk that starts while the app is suspended is only noticed at the next wake. That is the honest
//   limit of a third-party app; Apple Watch has system-level access this cannot have.
//
// Everything stays on device. Nothing is started or ended without a tap.

enum LiveWorkoutSuggestionPrefs {
    static let gymEnabledKey = "noopLiveGymSuggest"
    static let walkEnabledKey = "noopLiveWalkSuggest"
    static let gymLatKey = "noopLiveGymLat"
    static let gymLonKey = "noopLiveGymLon"
    static let gymRadiusKey = "noopLiveGymRadius"
    static let gymSportKey = "noopLiveGymSport"

    /// iOS region monitoring is unreliable under about 100 m. 150 m covers a large gym and its car park.
    static let defaultRadiusM = 150.0
    static let minRadiusM = 100.0
    static let maxRadiusM = 400.0
    static let defaultGymSport = "Strength"

    static var gymEnabled: Bool { UserDefaults.standard.bool(forKey: gymEnabledKey) }
    static var walkEnabled: Bool { UserDefaults.standard.bool(forKey: walkEnabledKey) }

    static var gymSport: String {
        let s = UserDefaults.standard.string(forKey: gymSportKey) ?? ""
        return s.isEmpty ? defaultGymSport : s
    }
}

@MainActor
final class LiveWorkoutSuggestions: NSObject, ObservableObject {

    static let shared = LiveWorkoutSuggestions()

    struct GymPlace: Equatable {
        let latitude: Double
        let longitude: Double
        let radiusM: Double
    }

    // MARK: Published state (Settings reads these)

    @Published private(set) var gym: GymPlace?
    @Published private(set) var locationAuth: CLAuthorizationStatus = .notDetermined
    @Published private(set) var capturingGym = false
    @Published private(set) var captureError: String?
    @Published private(set) var holdingRealtime = false
    @Published private(set) var inGym = false

    // MARK: Notification identifiers

    static let startCategory = "NOOP_LIVE_WORKOUT_START"
    static let endCategory = "NOOP_LIVE_WORKOUT_END"
    static let startRequestId = "noop.liveworkout.start"
    static let endRequestId = "noop.liveworkout.end"
    private static let startAction = "NOOP_LIVE_WORKOUT_START_ACTION"
    private static let notNowAction = "NOOP_LIVE_WORKOUT_NOT_NOW"
    private static let endAction = "NOOP_LIVE_WORKOUT_END_ACTION"
    private static let keepAction = "NOOP_LIVE_WORKOUT_KEEP"
    private static let gymRegionId = "noop.liveworkout.gym"
    private static let userInfoContext = "context"
    private static let userInfoTs = "ts"
    private static let userInfoSport = "sport"

    // MARK: Internals

    private let locationManager = CLLocationManager()
    private let motionManager = CMMotionActivityManager()
    private var engine = LiveWorkoutSuggestionEngine(config: .init(restingBpm: 60))
    private weak var model: AppModel?
    private var cancellables: Set<AnyCancellable> = []
    private var motionUpdatesRunning = false
    private var significantChangesRunning = false
    /// Start date of the last motion activity fed to the engine, so live updates and history replay
    /// never feed the same transition twice.
    private var lastFedActivityStart: Date?
    private var lastFedMotion: LiveWorkoutSuggestionEngine.Motion?
    private var lastCatchUp = Date.distantPast
    /// Context of a suggestion being accepted right now, read by the activeWorkout sink.
    private var startingContext: LiveWorkoutSuggestionEngine.Context?
    private var foregroundTimer: Timer?

    private override init() {
        super.init()
        locationAuth = locationManager.authorizationStatus
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        gym = Self.loadGym()
    }

    // MARK: - Wiring

    /// Called once from `StrandiOSApp.init`, early, so a region event that relaunched the app reaches a
    /// delegate. Safe to call again (no-op).
    func attach(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        registerCategories()

        engine.config.restingBpm = Self.restingBpm(model.repo)
        model.repo.$days
            .sink { [weak self, weak model] _ in
                guard let self, let model else { return }
                // $days fires in willSet; read on the next turn when the value has landed.
                DispatchQueue.main.async { self.engine.config.restingBpm = Self.restingBpm(model.repo) }
            }
            .store(in: &cancellables)

        model.$bpm
            .sink { [weak self] bpm in
                guard let self, let bpm else { return }
                self.feed(.heartRate(bpm))
                // Realtime notifies are the main background wake; use them to replay missed motion too.
                if Date().timeIntervalSince(self.lastCatchUp) > 60 { self.catchUpMotion() }
            }
            .store(in: &cancellables)

        model.$activeWorkout
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] active in
                guard let self else { return }
                if active {
                    let ctx = self.startingContext
                    self.startingContext = nil
                    self.removeNotification(Self.startRequestId)
                    self.feed(.workoutStarted(context: ctx))
                } else {
                    self.feed(.workoutEnded)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.wake(reason: "foreground") }
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

    /// Re-read the toggles and gym, and start or stop the platform monitors to match. Settings calls this
    /// after every change.
    func applySettings() {
        let gymOn = LiveWorkoutSuggestionPrefs.gymEnabled
        let walkOn = LiveWorkoutSuggestionPrefs.walkEnabled
        engine.config.gymEnabled = gymOn
        engine.config.walkEnabled = walkOn
        gym = Self.loadGym()

        // Gym geofence. Re-register only when the place or radius changed: this runs at every launch,
        // including the background launch iOS performs FOR a geofence crossing, and stopping the region
        // there could drop the very event that woke the app.
        let existing = locationManager.monitoredRegions
            .first { $0.identifier == Self.gymRegionId } as? CLCircularRegion
        if gymOn, let g = gym, CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) {
            let radius = min(g.radiusM, locationManager.maximumRegionMonitoringDistance)
            let same = existing.map {
                abs($0.center.latitude - g.latitude) < 1e-6 && abs($0.center.longitude - g.longitude) < 1e-6
                    && abs($0.radius - radius) < 0.5
            } ?? false
            if same, let existing {
                locationManager.requestState(for: existing)
            } else {
                if let existing { locationManager.stopMonitoring(for: existing) }
                let region = CLCircularRegion(
                    center: CLLocationCoordinate2D(latitude: g.latitude, longitude: g.longitude),
                    radius: radius, identifier: Self.gymRegionId)
                region.notifyOnEntry = true
                region.notifyOnExit = true
                locationManager.startMonitoring(for: region)
                // Learn whether we are already inside (opening the app at the gym).
                locationManager.requestState(for: region)
            }
        } else {
            if let existing { locationManager.stopMonitoring(for: existing) }
            if engine.inGym { feed(.gymExited) }
        }

        // Motion classifier.
        if walkOn, CMMotionActivityManager.isActivityAvailable() {
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

        // Significant location changes: an extra background wake for walks (needs Always).
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

    /// Ask for everything the enabled features need: Always location (gym, wakes), Motion (walks),
    /// notifications. Each prompt only appears while its status is undecided.
    func requestPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        switch locationManager.authorizationStatus {
        case .notDetermined, .authorizedWhenInUse:
            // From notDetermined iOS shows the When-In-Use prompt with a provisional Always, and asks
            // about Always later. From When-In-Use it shows the upgrade prompt once.
            locationManager.requestAlwaysAuthorization()
        default:
            break
        }
        if LiveWorkoutSuggestionPrefs.walkEnabled, CMMotionActivityManager.isActivityAvailable() {
            // The first query triggers the Motion & Fitness prompt.
            let now = Date()
            motionManager.queryActivityStarting(from: now.addingTimeInterval(-60), to: now, to: .main) { _, _ in }
        }
    }

    // MARK: - Gym place

    /// Save the phone's current position as the gym. Meant to be tapped while standing in the gym.
    func captureGymHere() {
        captureError = nil
        switch locationManager.authorizationStatus {
        case .denied, .restricted:
            captureError = String(localized: "Location access is off for NOOP. Turn it on in iOS Settings.")
            return
        case .notDetermined:
            locationManager.requestAlwaysAuthorization()
        default:
            break
        }
        capturingGym = true
        locationManager.requestLocation()
    }

    func clearGym() {
        let d = UserDefaults.standard
        d.removeObject(forKey: LiveWorkoutSuggestionPrefs.gymLatKey)
        d.removeObject(forKey: LiveWorkoutSuggestionPrefs.gymLonKey)
        d.removeObject(forKey: LiveWorkoutSuggestionPrefs.gymRadiusKey)
        applySettings()
    }

    func setGymRadius(_ meters: Double) {
        let r = min(LiveWorkoutSuggestionPrefs.maxRadiusM, max(LiveWorkoutSuggestionPrefs.minRadiusM, meters))
        UserDefaults.standard.set(r, forKey: LiveWorkoutSuggestionPrefs.gymRadiusKey)
        applySettings()
    }

    private static func loadGym() -> GymPlace? {
        let d = UserDefaults.standard
        guard d.object(forKey: LiveWorkoutSuggestionPrefs.gymLatKey) != nil,
              d.object(forKey: LiveWorkoutSuggestionPrefs.gymLonKey) != nil else { return nil }
        let r = d.double(forKey: LiveWorkoutSuggestionPrefs.gymRadiusKey)
        return GymPlace(latitude: d.double(forKey: LiveWorkoutSuggestionPrefs.gymLatKey),
                        longitude: d.double(forKey: LiveWorkoutSuggestionPrefs.gymLonKey),
                        radiusM: r > 0 ? r : LiveWorkoutSuggestionPrefs.defaultRadiusM)
    }

    private func saveGym(_ location: CLLocation) {
        let d = UserDefaults.standard
        d.set(location.coordinate.latitude, forKey: LiveWorkoutSuggestionPrefs.gymLatKey)
        d.set(location.coordinate.longitude, forKey: LiveWorkoutSuggestionPrefs.gymLonKey)
        if d.object(forKey: LiveWorkoutSuggestionPrefs.gymRadiusKey) == nil {
            d.set(LiveWorkoutSuggestionPrefs.defaultRadiusM, forKey: LiveWorkoutSuggestionPrefs.gymRadiusKey)
        }
        applySettings()
        log("liveWorkout: gym place saved (radius \(Int(gym?.radiusM ?? 0)) m)")
    }

    // MARK: - Engine plumbing

    private func feed(_ event: LiveWorkoutSuggestionEngine.Event, at date: Date = Date()) {
        let actions = engine.handle(event, at: Int(date.timeIntervalSince1970))
        // With both toggles off the engine still tracks state (so turning one on mid-workout is coherent), but
        // nothing reaches the wearer. Withdrawals always pass, so a stale card cannot outlive the toggle.
        let featureOn = LiveWorkoutSuggestionPrefs.gymEnabled || LiveWorkoutSuggestionPrefs.walkEnabled
        for action in actions {
            switch action {
            case .withdrawStart, .withdrawEnd: perform(action)
            case .suggestStart, .suggestEnd: if featureOn { perform(action) }
            }
        }
        if inGym != engine.inGym { inGym = engine.inGym }
        syncRealtime()
    }

    private func syncRealtime() {
        guard let model else { return }
        let want = engine.wantsRealtime && (LiveWorkoutSuggestionPrefs.gymEnabled || LiveWorkoutSuggestionPrefs.walkEnabled)
        if want, !holdingRealtime {
            holdingRealtime = true
            model.startRealtimeHR()
            log("liveWorkout: realtime HR armed for suggestions")
        } else if !want, holdingRealtime {
            holdingRealtime = false
            model.stopRealtimeHR()
            log("liveWorkout: realtime HR released")
        }
    }

    private func wake(reason: String) {
        feed(.tick)
        catchUpMotion()
        startForegroundTimerIfNeeded()
    }

    /// While the app is in the foreground, tick every 30 s so time-based rules fire without new samples.
    /// Timers do not run while suspended; in the background the HR notifies and wakes drive the engine.
    private func startForegroundTimerIfNeeded() {
        guard foregroundTimer == nil, UIApplication.shared.applicationState == .active,
              LiveWorkoutSuggestionPrefs.gymEnabled || LiveWorkoutSuggestionPrefs.walkEnabled else { return }
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
        // Automotive at low confidence is common at traffic lights on foot, so require medium or better.
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
            // .unknown carries no information; keep the previous state rather than ending a bout on it.
            guard m != .unknown, m != lastFedMotion else { continue }
            lastFedMotion = m
            feed(.motion(m), at: a.startDate)
        }
    }

    /// Replay activity transitions the coprocessor recorded while the app was suspended.
    private func catchUpMotion() {
        guard LiveWorkoutSuggestionPrefs.walkEnabled, CMMotionActivityManager.isActivityAvailable() else { return }
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

    // MARK: - Actions → notifications

    private func perform(_ action: LiveWorkoutSuggestionEngine.Action) {
        switch action {
        case let .suggestStart(context, startTs, avgBpm):
            postStart(context: context, startTs: startTs, avgBpm: avgBpm)
        case .withdrawStart:
            removeNotification(Self.startRequestId)
            log("liveWorkout: start suggestion withdrawn")
        case let .suggestEnd(context, endTs, reason):
            postEnd(context: context, endTs: endTs, reason: reason)
        case .withdrawEnd:
            removeNotification(Self.endRequestId)
            log("liveWorkout: end suggestion withdrawn")
        }
    }

    private func sport(for context: LiveWorkoutSuggestionEngine.Context) -> String {
        switch context {
        case .gym: return LiveWorkoutSuggestionPrefs.gymSport
        case .walk: return "Walking"
        case .run: return "Running"
        }
    }

    private func postStart(context: LiveWorkoutSuggestionEngine.Context, startTs: Int, avgBpm: Int?) {
        let sportName = sport(for: context)
        let since = AppClock.hourMinuteFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(startTs)))
        let title: String
        var body: String
        switch context {
        case .gym:
            title = String(localized: "Working out?")
            body = String(localized: "Your heart rate is up at the gym. Tap to start \(sportName) from \(since).")
        case .walk:
            title = String(localized: "Out for a walk?")
            body = String(localized: "You've been walking since \(since). Tap to start a walk from then.")
        case .run:
            title = String(localized: "Out for a run?")
            body = String(localized: "You've been running since \(since). Tap to start a run from then.")
        }
        if let avgBpm {
            body += " " + String(localized: "Average heart rate \(avgBpm).")
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.startCategory
        content.userInfo = [Self.userInfoContext: context.rawValue, Self.userInfoTs: startTs,
                            Self.userInfoSport: sportName]
        content.threadIdentifier = "noop.liveworkout"
        add(id: Self.startRequestId, content: content)
        log("liveWorkout: suggestStart context=\(context.rawValue) backdate=\(Int(Date().timeIntervalSince1970) - startTs)s")
    }

    private func postEnd(context: LiveWorkoutSuggestionEngine.Context?,
                         endTs: Int, reason: LiveWorkoutSuggestionEngine.EndReason) {
        let at = AppClock.hourMinuteFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(endTs)))
        let body: String
        switch reason {
        case .leftGym:
            body = String(localized: "You left the gym at \(at). End your workout at \(at)?")
        case .stoppedMoving:
            body = String(localized: "You stopped moving at \(at). End your workout at \(at)?")
        case .startedDriving:
            body = String(localized: "Looks like you're in a vehicle. End your workout at \(at)?")
        case .heartRateRecovered:
            body = String(localized: "Your heart rate has been near resting since \(at). End your workout at \(at)?")
        }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Workout still running")
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.endCategory
        content.userInfo = [Self.userInfoTs: endTs]
        content.threadIdentifier = "noop.liveworkout"
        add(id: Self.endRequestId, content: content)
        log("liveWorkout: suggestEnd reason=\(reason.rawValue) context=\(context?.rawValue ?? "manual")")
    }

    private func add(id: String, content: UNMutableNotificationContent) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            // A fixed identifier replaces any earlier suggestion of the same kind instead of stacking.
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    private func removeNotification(_ id: String) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    private func registerCategories() {
        let start = UNNotificationAction(identifier: Self.startAction,
                                         title: String(localized: "Start workout"), options: [])
        let notNow = UNNotificationAction(identifier: Self.notNowAction,
                                          title: String(localized: "Not now"), options: [])
        let end = UNNotificationAction(identifier: Self.endAction,
                                       title: String(localized: "End workout"), options: [.destructive])
        let keep = UNNotificationAction(identifier: Self.keepAction,
                                        title: String(localized: "Keep going"), options: [])
        let startCat = UNNotificationCategory(identifier: Self.startCategory, actions: [start, notNow],
                                              intentIdentifiers: [], options: [.customDismissAction])
        let endCat = UNNotificationCategory(identifier: Self.endCategory, actions: [end, keep],
                                            intentIdentifiers: [], options: [.customDismissAction])
        let center = UNUserNotificationCenter.current()
        // Merge rather than replace, so a category another feature registers later is not clobbered.
        center.getNotificationCategories { existing in
            var all = existing.filter { $0.identifier != Self.startCategory && $0.identifier != Self.endCategory }
            all.insert(startCat)
            all.insert(endCat)
            center.setNotificationCategories(all)
        }
    }

    // MARK: - Responses

    /// Route a tapped suggestion. Returns false for notifications this feature does not own.
    func handle(response: UNNotificationResponse) -> Bool {
        let content = response.notification.request.content
        switch content.categoryIdentifier {
        case Self.startCategory:
            switch response.actionIdentifier {
            case Self.startAction, UNNotificationDefaultActionIdentifier:
                acceptStart(userInfo: content.userInfo)
            default:   // Not now, or swiped away
                feed(.startDismissed)
                log("liveWorkout: start suggestion declined")
            }
            return true
        case Self.endCategory:
            switch response.actionIdentifier {
            case Self.endAction:
                acceptEnd(userInfo: content.userInfo)
            case Self.keepAction, UNNotificationDismissActionIdentifier:
                feed(.endDismissed)
                log("liveWorkout: end suggestion declined")
            default:
                break   // a tap on the body just opens the app; ending stays an explicit choice
            }
            return true
        default:
            return false
        }
    }

    private func acceptStart(userInfo: [AnyHashable: Any]) {
        guard let model, model.activeWorkout == nil else { return }
        let ctx = (userInfo[Self.userInfoContext] as? String).flatMap(LiveWorkoutSuggestionEngine.Context.init(rawValue:))
        let startTs = (userInfo[Self.userInfoTs] as? Int) ?? Int(Date().timeIntervalSince1970)
        let sportName = (userInfo[Self.userInfoSport] as? String) ?? ctx.map(sport(for:)) ?? WorkoutCatalog.defaultSportName
        let startDate = Date(timeIntervalSince1970: TimeInterval(startTs))
        let nowTs = Int(Date().timeIntervalSince1970)
        let held = engine.heartRate(from: startTs, to: nowTs).map { HRSample(ts: $0.ts, bpm: $0.bpm) }

        // The in-memory buffer covers the span unless the app was relaunched since the suggestion. Then read
        // whatever the store banked for the span, under a background-task assertion so iOS lets it finish.
        let coversSpan = (held.first?.ts ?? Int.max) - startTs <= 120
        if coversSpan {
            begin(model: model, context: ctx, sport: sportName, start: startDate, seeds: held)
            return
        }
        let task = BackgroundTaskBox()
        task.id = UIApplication.shared.beginBackgroundTask(withName: "noop.liveworkout.start") {
            task.end()
        }
        Task { @MainActor [weak self, weak model] in
            defer { task.end() }
            guard let self, let model, model.activeWorkout == nil else { return }
            let stored = await model.repo.hrSamples(from: startTs, to: nowTs, limit: 20_000)
            var byTs: [Int: HRSample] = [:]
            for s in stored { byTs[s.ts] = s }
            for s in held { byTs[s.ts] = s }
            self.begin(model: model, context: ctx, sport: sportName, start: startDate,
                       seeds: byTs.values.sorted { $0.ts < $1.ts })
        }
    }

    private func begin(model: AppModel, context: LiveWorkoutSuggestionEngine.Context?,
                       sport: String, start: Date, seeds: [HRSample]) {
        guard model.activeWorkout == nil else { return }
        startingContext = context
        model.startWorkout(sport: sport, startedAt: start, seedSamples: seeds)
        log("liveWorkout: started from suggestion (\(seeds.count) seeded samples)")
    }

    private func acceptEnd(userInfo: [AnyHashable: Any]) {
        guard let model, model.activeWorkout != nil else { return }
        let endTs = userInfo[Self.userInfoTs] as? Int
        model.endWorkout(endedAt: endTs.map { Date(timeIntervalSince1970: TimeInterval($0)) })
        log("liveWorkout: ended from suggestion")
    }

    // MARK: - Log

    /// Suggestions are rare events, so they are always logged (not gated on Test Centre): when one fires
    /// at the wrong time, the strap log is the only evidence of why.
    private func log(_ line: String) {
        model?.live.append(log: AppModel.stamped(line))
    }
}

/// Holds a background-task id so both the expiration handler and the work can end it exactly once.
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

extension LiveWorkoutSuggestions: @preconcurrency CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        locationAuth = manager.authorizationStatus
        applySettings()
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard region.identifier == Self.gymRegionId else { return }
        switch state {
        case .inside:
            if !engine.inGym { log("liveWorkout: arrived at gym") }
            feed(.gymEntered)
        case .outside:
            if engine.inGym { log("liveWorkout: left gym") }
            feed(.gymExited)
        case .unknown:
            break
        }
        catchUpMotion()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if capturingGym, let best = locations.min(by: { $0.horizontalAccuracy < $1.horizontalAccuracy }) {
            capturingGym = false
            if best.horizontalAccuracy < 0 || best.horizontalAccuracy > 150 {
                captureError = String(localized: "Couldn't get a precise location. Try again near a window or by the entrance.")
            } else {
                saveGym(best)
            }
            return
        }
        // A significant-change wake: replay motion and let time-based rules run.
        wake(reason: "location")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if capturingGym {
            capturingGym = false
            captureError = String(localized: "Couldn't get your location. Try again.")
        }
    }

    func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        // requestState straight after startMonitoring can race the registration; ask again once it is live.
        if region.identifier == Self.gymRegionId { manager.requestState(for: region) }
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        guard region?.identifier == Self.gymRegionId else { return }
        log("liveWorkout: gym geofence failed to start")
    }
}

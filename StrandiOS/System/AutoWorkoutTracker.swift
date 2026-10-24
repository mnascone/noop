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
                let radius = min(p.radiusM, locationManager.maximumRegionMonitoringDistance)
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
        guard AutoTrackingPrefs.walkEnabled, CMMotionActivityManager.isActivityAvailable() else { return }
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
            if mode(for: context) == .auto {
                autoStart(context: context, startTs: startTs)
            } else {
                postAskStart(context: context, startTs: startTs, avgBpm: avgBpm)
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
            if engine.currentPlace != id { log("auto: arrived at \(p.name)") }
            feed(.placeEntered(id: id, params: p.params))
        case .outside:
            if engine.currentPlace == id { log("auto: left \(p.name)") }
            feed(.placeExited(id: id))
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
        wake()
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

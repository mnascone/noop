#if os(iOS)
import Foundation
import ActivityKit
import Combine
import UIKit
import WhoopStore
import StrandAnalytics

/// Starts, updates, and ends the live-HR Live Activity on the Lock Screen and in the Dynamic Island: the heart rate
/// while the strap measures it, the dash while it does not. It follows the strap from process start (`follow`).
@MainActor
final class LiveActivityController {
    private var activity: Activity<NOOPActivityAttributes>?
    /// What the banner reads — the live heart rate, the link, the day's recovery and effort — set once by `follow`.
    private weak var model: AppModel?
    /// Whether the Lift Log banner is on screen, which the heart rate banner makes room for.
    private var standsAside: () -> Bool = { false }
    private var cancellables: Set<AnyCancellable> = []
    private var lastPush: Date = .distantPast
    /// What the banner was last pushed with, so an unchanged banner is not pushed again
    /// (`LiveHRBannerPushPolicy`). Nil until this controller pushes, and again once it ends the activity.
    private var shownState: NOOPActivityAttributes.ContentState?
    /// Cached `ActivityAuthorizationInfo` — `update` runs at ~1 Hz off the live HR stream, and
    /// instantiating this system bridge per tick is needless allocation. ActivityKit's auth status
    /// only changes via Settings, so caching for the controller's lifetime is safe.
    private let authInfo = ActivityAuthorizationInfo()
    /// Synchronous gate against concurrent `Activity.request` calls. The `else` branch below is
    /// re-entered while the first request is still in flight (it hasn't assigned `self.activity`
    /// yet), so without this guard two close-together HR samples could both fire `Activity.request`
    /// and create duplicate Live Activities.
    private var isStarting = false
    /// When the banner being fed was started, for iOS's eight-hour limit (`LiveHRBannerLifecycle.renewAfter`). Kept in
    /// the defaults with the banner's id, because a banner outlives the run that started it. Nil when unknown.
    private var startedAt: Date?
    private static let startedKey = "liveActivity.hr.startedAt"
    /// An end is in flight, so the ticks that arrive meanwhile neither end it again nor log it twice.
    private var isEnding = false
    /// iOS refused a start, and it was logged: once, not on every tick while NOOP is on screen.
    private var refusalLogged = false
    /// Banners NOOP has asked iOS to remove (`removeLeftovers`), so a tick that arrives before iOS has dropped one from
    /// its list neither asks again nor logs it twice.
    private var removing: Set<String> = []
    /// How long after the last push iOS treats the banner as fresh; after that the banner draws the dash
    /// (`NOOPLiveActivity.shownBpm`). A WHOOP 5.0 taken off the wrist goes quiet, and with nothing arriving iOS
    /// suspends NOOP, so no timer of NOOP's can clear the number: iOS's own stale date is what does it, in at most
    /// this long (a tester's log, 23 Sep 2026). A steady number is re-pushed once half of this has passed
    /// (`LiveHRBannerPushPolicy`), so a banner fed by a worn strap never goes stale.
    static let staleAfter: TimeInterval = 30

    /// Follow the strap from process start, not from a screen. iOS starts NOOP in the background — the strap
    /// reconnecting, a sync, the Sync Strap shortcut — and a process started that way need not build any screen (the
    /// shortcut's never does), while a banner the previous run left on the Lock Screen is there to be picked up and
    /// fed from the first reading. Called once, from the app's `init`, like the Lift Log's own resume.
    func follow(_ model: AppModel, standsAside: @escaping () -> Bool) {
        self.model = model
        self.standsAside = standsAside
        // Refreshed once a change has landed, never from inside it (`LiveHRBannerInputs`). AppModel's median (`bpm`)
        // is an input in its own right: it moves on the R-R alone, and a clear that reached it that way refreshed
        // nothing, so the banner kept the last number until iOS's stale date drew the dash.
        LiveHRBannerInputs.settled([model.live.$heartRate.map { _ in () }.eraseToAnyPublisher(),
                                    model.live.$connected.map { _ in () }.eraseToAnyPublisher(),
                                    model.$bpm.map { _ in () }.eraseToAnyPublisher()])
            .sink { [weak self] in self?.refreshBanner() }
            .store(in: &cancellables)
        // Workout and set/rest changes reach the banner without waiting for the next heart-rate tick.
        model.$activeWorkout.map { $0.map { Int($0.start.timeIntervalSince1970) } }.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshBanner() }
            .store(in: &cancellables)
        LiveIntervalTracker.shared.$summary.map { $0.map { "\($0.count)|\($0.phase)" } }.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshBanner() }
            .store(in: &cancellables)
        // A change to the chosen fields shows at once. The prefs are read here, once per settings change,
        // never on the heart-rate tick.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .map { _ in BannerPrefs.load() }
            .removeDuplicates()
            .sink { [weak self] p in
                guard let self, p != self.prefs else { return }
                self.prefs = p
                self.refreshBanner()
            }
            .store(in: &cancellables)
        // The switch is the one way to be rid of the banner, so it acts at once — not at the next heart-rate tick,
        // which a strap off the wrist may not send for hours.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .map { _ in UnitPrefs.liveActivityEnabled() }
            .prepend(UnitPrefs.liveActivityEnabled())
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.refreshBanner() }
            .store(in: &cancellables)
    }

    /// NOOP came on screen, the only time iOS lets it start the banner: offered now rather than at the next heart-rate
    /// change, which a strap off the wrist may not bring for a long while. Said by the caller, from the scene phase,
    /// because `applicationState` can still read inactive while the scene turns active.
    func appBecameActive() {
        refreshBanner(appActive: true)
    }

    /// #911: recovery and effort come from the SAME shared `Repository.widgetAnchor` the widget and the watch use, so
    /// the banner cannot name a different day at the rollover; memoized, because this runs on every heart-rate tick
    /// (re-deriving it once scanned the whole history, #1051).
    private func refreshBanner(appActive: Bool? = nil) {
        guard let model else { return }
        let connected = model.live.connected
        let day = model.repo.cachedWidgetAnchor()
        update(bpm: connected ? (model.bpm ?? model.live.heartRate) : nil,
               recovery: day?.recovery.map { Int($0.rounded()) }, connected: connected, standsAside: standsAside(),
               appActive: appActive ?? (UIApplication.shared.applicationState == .active),
               effort: day?.strain.map { Int($0.rounded()) },
               extras: bannerExtras(model, day: day))
    }

    /// The banner settings, read once per settings change rather than on every tick.
    struct BannerPrefs: Equatable {
        var fields: [LiveBannerField]
        var workoutFields: [LiveBannerField]?
        var islandField: LiveBannerField?
        var layout: LiveBannerLayout
        var showLabels: Bool
        var title: String?

        static func load() -> BannerPrefs {
            BannerPrefs(fields: LiveBannerPrefs.load(), workoutFields: LiveBannerPrefs.loadWorkout(),
                        islandField: LiveBannerPrefs.islandField(), layout: LiveBannerPrefs.layout(),
                        showLabels: LiveBannerPrefs.showLabels(), title: LiveBannerPrefs.title())
        }
    }
    private var prefs = BannerPrefs.load()
    /// Last night's sleep score for the banner, keyed by day and data version so it's scored once per
    /// change instead of once per heart-rate tick.
    private var restCache: (key: String, value: Int?)?

    /// The customizable part of the banner: which fields, plus the values only some fields need.
    struct BannerExtras: Equatable {
        var fields: [LiveBannerField] = LiveBannerPrefs.defaultFields
        var rest: Int?
        var workoutStart: Date?
        var workoutSport: String?
        var restSince: Date?
        var setCount: Int?
        var steps: Int?
        var calories: Int?
        var zone: Int?
        var hrv: Int?
        var restingHr: Int?
        var islandField: LiveBannerField?
        var layout: LiveBannerLayout = .featured
        var showLabels = true
        var title: String?
        var texts: [String: String] = [:]
    }

    /// Pre-formatted values for the later banner fields, only for the ones on show.
    private func bannerTexts(_ model: AppModel, day: DailyMetric?, wanted: Set<LiveBannerField>) -> [String: String] {
        var t: [String: String] = [:]
        func put(_ f: LiveBannerField, _ v: String?) { if wanted.contains(f), let v { t[f.rawValue] = v } }
        let system = UnitSystem(rawValue: UserDefaults.standard.string(forKey: UnitPrefs.systemKey) ?? "") ?? .metric
        let distanceSystem = UnitPrefs.resolveDistance(
            system: system, override: UserDefaults.standard.string(forKey: UnitPrefs.distanceSystemKey) ?? "")

        if let pct = model.live.batteryPct {
            put(.battery, "\(Int(pct.rounded()))%" + (model.live.charging == true ? " ⚡︎" : ""))
        }
        put(.batteryTime, model.live.batteryEstimate.map { BatteryEstimator.label(hours: $0.remainingHours) })
        if let mins = day?.totalSleepMin, mins > 0 {
            let m = Int(mins.rounded())
            put(.sleepTime, "\(m / 60)h \(m % 60)m")
        }
        if let dev = day?.skinTempDevC, abs(dev) < 5 {
            // Deviation from baseline, in the user's temperature unit.
            let v = system == .imperial ? dev * 1.8 : dev
            put(.skinTemp, String(format: "%+.1f°", v))
        }
        put(.respiration, day?.respRateBpm.map { String(format: "%.1f", $0) })
        put(.spo2, day?.spo2Pct.map { "\(Int($0.rounded()))%" })
        if let w = model.activeWorkout {
            put(.workoutEffort, String(format: "%.1f", w.liveStrain))
            if w.avgHr > 0 { put(.avgHr, "\(w.avgHr)") }
            if w.peakHr > 0 { put(.peakHr, "\(w.peakHr)") }
            let gps = model.gpsRecorder
            if gps.isRecording, gps.pointCount > 0 {
                put(.distance, UnitFormatter.distanceFromMeters(gps.distanceM, system: distanceSystem))
                put(.pace, UnitFormatter.paceFromSecPerKm(gps.paceSecPerKm, system: distanceSystem))
            }
        }
        return t
    }

    private func bannerExtras(_ model: AppModel, day: DailyMetric?) -> BannerExtras {
        var e = BannerExtras(fields: prefs.fields)
        // A separate set of fields while a workout runs, when one is chosen.
        if model.activeWorkout != nil, let workoutFields = prefs.workoutFields {
            e.fields = workoutFields
        }
        e.islandField = prefs.islandField
        e.layout = prefs.layout
        e.showLabels = prefs.showLabels
        e.title = prefs.title
        let today = model.repo.today
        if e.fields.contains(.steps) { e.steps = today?.steps ?? day?.steps }
        if e.fields.contains(.calories) {
            e.calories = (today?.activeKcalEst ?? day?.activeKcalEst).map { Int($0.rounded()) }
        }
        if e.fields.contains(.hrv) { e.hrv = day?.avgHrv.map { Int($0.rounded()) } }
        if e.fields.contains(.restingHr) { e.restingHr = day?.restingHr }
        if e.fields.contains(.zone) || e.islandField == .zone, let bpm = model.bpm ?? model.live.heartRate {
            e.zone = model.profile.hrZoneSet.zoneNumber(forBPM: Double(bpm))
        }
        e.texts = bannerTexts(model, day: day, wanted: Set(e.fields + [e.islandField].compactMap { $0 }))
        if e.fields.contains(.rest) || e.islandField == .rest, let day {
            let key = "\(day.day)|\(model.repo.refreshSeq)|\(model.intelligence.lastSleepNeedHours ?? -1)"
            if let cached = restCache, cached.key == key {
                e.rest = cached.value
            } else {
                let inputs = SleepScoreInputs.resolve(intelligence: model.intelligence, days: model.repo.days,
                                                      age: model.profile.age)
                e.rest = AnalyticsEngine.Rest.composite(daily: day, needHours: inputs.needHours,
                                                        consistency: inputs.consistency).map { Int($0.rounded()) }
                restCache = (key, e.rest)
            }
        }
        if let w = model.activeWorkout {
            // Paused time is left out of the clock by shifting its start forward.
            e.workoutStart = w.start.addingTimeInterval(w.pausedDuration)
            e.workoutSport = w.sport
            let tracker = LiveIntervalTracker.shared
            if let s = tracker.summary, tracker.mode != nil {
                e.setCount = s.count
                if case .resting(let since) = s.phase { e.restSince = Date(timeIntervalSince1970: TimeInterval(since)) }
            }
        }
        return e
    }

    /// Drive the activity from the latest live values (`LiveHRBannerLifecycle` decides start / push / end). Starts
    /// only in the foreground (`appActive`), with the strap CONNECTED (the live link, not the sticky "paired" flag),
    /// before a heart rate arrives if need be; a running banner shows the dash through a dropped link or a strap
    /// that is not measuring, and ends only when its switch is off or the Lift Log banner takes the screen
    /// (`standsAside`). Pushed when what it shows changes, and often enough to stay fresh (`LiveHRBannerPushPolicy`,
    /// `staleAfter`).
    private func update(bpm: Int?, recovery: Int?, connected: Bool, standsAside: Bool, appActive: Bool,
                        effort: Int?, extras: BannerExtras = BannerExtras()) {
        guard authInfo.areActivitiesEnabled else { return }

        // A banner iOS ended (after about eight hours) or the user swiped away is gone: forget it, so the next time
        // NOOP is on screen it starts one again rather than pushing to nothing. (One NOOP is ending is not gone yet.)
        if !isEnding, let activity, !Self.isShowing(activity) {
            self.activity = nil
            shownState = nil
            startedAt = nil
            log((Self.listed(activity) == .ended ? "ended by iOS" : "gone from the Lock Screen (dismissed)")
                + "; started again when NOOP is next on screen")
        }
        // Re-adopt an activity that outlived a previous app session. ActivityKit keeps Live Activities
        // alive across launches/relaunches, but a fresh controller starts with `activity == nil`, so
        // without recovering the handle here we can neither update nor END an already-showing activity
        // — which made the #336 opt-out a no-op (#341: toggle off, heart stays) and risked spawning a
        // duplicate on the start path below. Done on the HR tick rather than in `init` because
        // `Activity.activities` isn't reliably hydrated at the instant of process launch. A banner iOS ended is
        // removed here too, whichever run fed it: it can only show its last number.
        if activity == nil {
            let listed = Activity<NOOPActivityAttributes>.activities
            removeLeftovers(listed, beside: nil)
            if let adopted = listed.first(where: Self.isShowing) {
                activity = adopted
                startedAt = (UserDefaults.standard.dictionary(forKey: Self.startedKey)?[adopted.id] as? Double)
                    .map(Date.init(timeIntervalSince1970:))
                log("picked up the one already on the Lock Screen")
            }
        }

        // The switch (#336) and the gym banner on screen end it; nothing that passes does (`LiveHRBannerLifecycle`).
        let now = Date()
        let switchOn = UnitPrefs.liveActivityEnabled()
        let age = startedAt.map { now.timeIntervalSince($0) }
        let step = LiveHRBannerLifecycle.step(
            switchOn: switchOn, standsAside: standsAside, linkUp: connected,
            showing: activity != nil, age: age, appActive: appActive)
        switch step {
        case .nothing: return
        case .end:
            guard !isEnding else { return }
            isEnding = true
            log(switchOn ? "ended: the Lift Log banner takes its place" : "ended: its switch is off")
            Task { await end() }
            return
        case .start, .push, .renew: break
        }

        // Link down: the dash, never the last number (`bonded` stays true across a disconnect, and keying off it once
        // left a fabricated "live" HR standing). No timed end: a timer in a suspended app fires at its next wake,
        // which is typically the strap coming back — exactly when the banner should stay.
        // Timers are sent as start dates, so the Lock Screen counts them itself without a push per second.
        let state = NOOPActivityAttributes.ContentState(
            bpm: connected ? bpm : nil, recovery: recovery, bonded: connected, effort: effort,
            fields: extras.fields, rest: extras.rest, workoutStart: extras.workoutStart,
            workoutSport: extras.workoutSport,
            restSince: extras.restSince,
            setCount: extras.setCount,
            steps: extras.steps, calories: extras.calories, zone: extras.zone, hrv: extras.hrv,
            restingHr: extras.restingHr, islandField: extras.islandField, layout: extras.layout,
            showLabels: extras.showLabels, title: extras.title, texts: extras.texts)

        if step == .renew, activity != nil {
            // The fresh banner first, then the old one goes, so the Lock Screen is never without one; if iOS refuses
            // the fresh one, the old one stays.
            if start(state, at: now) {
                log("renewed after \(age.map { "\(Int($0 / 60)) min" } ?? "an unknown time"), "
                    + "so iOS's eight-hour limit starts again")
                removeLeftovers(Activity<NOOPActivityAttributes>.activities, beside: activity)
            }
        } else if let activity {
            // The number giving way to the dash (the strap off the wrist, the link dropping) is pushed at once: no
            // tick follows it, so a push skipped for spacing would leave the last number standing.
            guard LiveHRBannerPushPolicy.due(shown: shownState, next: state, reading: \.bpm,
                                             sinceLastPush: now.timeIntervalSince(lastPush),
                                             staleAfter: Self.staleAfter) else { return }
            if let shown = shownState, (shown.bpm == nil) != (state.bpm == nil) { logReading(state) }
            lastPush = now
            shownState = state
            let staleDate = now.addingTimeInterval(Self.staleAfter)
            Task { await activity.update(ActivityContent(state: state, staleDate: staleDate)) }
        } else if start(state, at: now) {
            log(state.bpm == nil ? "started, showing – until a heart rate arrives" : "started")
            removeLeftovers(Activity<NOOPActivityAttributes>.activities, beside: activity)
        }
    }

    /// Removes at once each banner in `listed` that `LiveHRBannerLifecycle.removes` says goes: one iOS has ended, which
    /// stays on the Lock Screen frozen on its last number and takes no update, and — once NOOP has started `fresh` —
    /// any other one still showing. Each removal of an ended one leaves a line: it is what a second banner beside the
    /// live one would have been.
    private func removeLeftovers(_ listed: [Activity<NOOPActivityAttributes>],
                                 beside fresh: Activity<NOOPActivityAttributes>?) {
        for act in listed where act.id != fresh?.id {
            let state = Self.listed(act)
            guard LiveHRBannerLifecycle.removes(state, besideFresh: fresh != nil),
                  removing.insert(act.id).inserted else { continue }
            if state == .ended { log("removed one iOS had ended, which could only show its last number") }
            Task { await act.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Ask iOS for a new banner, which it grants only while NOOP is on screen. Returns whether it did.
    @discardableResult
    private func start(_ state: NOOPActivityAttributes.ContentState, at now: Date) -> Bool {
        // Set the start gate SYNCHRONOUSLY before any await so a second `update` arriving on the
        // main actor while `Activity.request` is still in flight bails here instead of issuing a
        // second request. The 2-second throttle above only guards the update path.
        guard !isStarting else { return false }
        isStarting = true
        defer { isStarting = false }
        do {
            let started = try Activity.request(
                attributes: NOOPActivityAttributes(title: String(localized: "Live HR")),
                content: ActivityContent(state: state, staleDate: now.addingTimeInterval(Self.staleAfter)),
                pushType: nil
            )
            activity = started
            startedAt = now
            UserDefaults.standard.set([started.id: now.timeIntervalSince1970], forKey: Self.startedKey)
            lastPush = now
            shownState = state
            refusalLogged = false
            return true
        } catch {
            if !refusalLogged {
                refusalLogged = true
                log("iOS did not start it: \(error.localizedDescription)")
            }
            return false
        }
    }

    /// The banner turning to the dash, or back to a number: pushed at once (`LiveHRBannerPushPolicy`), and logged.
    private func logReading(_ state: NOOPActivityAttributes.ContentState) {
        if state.bpm != nil {
            log("heart rate again")
        } else {
            log(state.bonded ? "– (strap connected, no heart rate)" : "– (strap not connected)")
        }
    }

    /// One line in NOOP's strap log for each thing that happens to the banner: started, picked up, renewed, ended,
    /// gone, and each turn to the dash and back. Rare, so always on. A tester's banner once showed the dash for a
    /// strap he was wearing, and a log without a word about the banner could not say why (24 Sep 2026).
    private func log(_ line: String) {
        model?.live.append(log: AppModel.stamped("Live HR banner: " + line))
    }

    /// Still on the Lock Screen and able to take an update: not ended by iOS, the user or NOOP.
    private static func isShowing(_ activity: Activity<NOOPActivityAttributes>) -> Bool {
        listed(activity) == .showing
    }

    /// The banner's state in `LiveHRBannerLifecycle`'s terms. `pending` (a start iOS 26 schedules) never comes from
    /// NOOP, which only starts banners at once, so it counts as gone: not NOOP's to feed or remove.
    private static func listed(_ activity: Activity<NOOPActivityAttributes>) -> LiveHRBannerLifecycle.Listed {
        switch activity.activityState {
        case .active, .stale: return .showing
        case .ended: return .ended
        default: return .gone
        }
    }

    private func end() async {
        // End every NOOP Live Activity, not just our cached handle — covers a straggler from a prior
        // session we never re-adopted (#341) and any rare duplicate. Iterating the live list is the
        // only way to reach activities this controller instance never started.
        for act in Activity<NOOPActivityAttributes>.activities {
            await act.end(nil, dismissalPolicy: .immediate)
        }
        self.activity = nil
        shownState = nil
        startedAt = nil
        isEnding = false
    }
}
#endif

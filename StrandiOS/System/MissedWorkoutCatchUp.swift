import Foundation
import UIKit
import UserNotifications
import WhoopProtocol
import WhoopStore
import StrandAnalytics

// MARK: - Workouts recorded while the phone was away
//
// Live auto tracking sees only what the phone sees. With the phone left behind, the strap keeps recording
// and hands its heart rate, wrist motion and steps over at the next sync. After each sync this looks back
// over the last two days of that data for walks, runs and other workouts nothing logged, using
// `MissedWorkoutFinder`, and treats each like a live one. Walks and runs come from the strap's steps. A
// workout found from heart rate is recorded only when the phone was at one of your places for it
// (`PlaceVisitLog`), as that place's sport: heart rate alone recorded stressful hours as lifts. Walks and
// Places settings decide whether each is looked for and whether it's saved (Automatic) or offered (Ask).
// Each is acted on once: one you delete or discard isn't offered again, and nor is a live one you said no
// to.

extension AutoWorkoutTracker {
    static let missedCategory = "NOOP_AUTO_MISSED"
    static let missedSaveAction = "NOOP_AUTO_MISSED_SAVE"
    static let missedDiscardAction = "NOOP_AUTO_MISSED_DISCARD"
    private static let kAvg = "avg", kPeak = "peak"
    private static let offeredKey = "noopAutoOfferedSpans"
    /// How far back each scan looks. The first ever scan looks back only `firstLookbackS`, so turning
    /// this on doesn't fill the log with two days of walks at once.
    private static let lookbackS = 48 * 3600
    private static let firstLookbackS = 12 * 3600
    private static let sinceKey = "noopAutoMissedSince"
    /// A bout must have ended this long ago: until then, with the phone around, the live path owns it.
    private static let liveGraceS = 20 * 60

    // MARK: Offered spans

    /// Spans already saved, offered, discarded or declined: never offered again. Kept a week.
    static var offeredSpans: [ClosedRange<Int>] {
        (UserDefaults.standard.stringArray(forKey: offeredKey) ?? []).compactMap { token in
            let p = token.split(separator: ":").compactMap { Int($0) }
            return p.count == 2 && p[0] <= p[1] ? p[0]...p[1] : nil
        }
    }

    static func rememberOffered(_ span: ClosedRange<Int>) {
        let cutoff = Int(Date().timeIntervalSince1970) - 7 * 86_400
        var kept = offeredSpans.filter { $0.upperBound >= cutoff }
        kept.append(span)
        UserDefaults.standard.set(kept.suffix(300).map { "\($0.lowerBound):\($0.upperBound)" }, forKey: offeredKey)
    }

    // MARK: Scanning

    /// Look for workouts the strap recorded that nothing logged. Cheap to call often: one runs at a time,
    /// at most every two minutes.
    func scanForMissedWorkouts() {
        guard let model, AutoTrackingPrefs.anyEnabled, !MissedScan.running,
              Date().timeIntervalSince(MissedScan.last) > 120 else { return }
        MissedScan.running = true
        MissedScan.last = Date()
        let box = BackgroundTaskBox()
        box.id = UIApplication.shared.beginBackgroundTask(withName: "noop.auto.missed") { box.end() }
        Task { @MainActor [weak self] in
            defer { MissedScan.running = false; box.end() }
            await self?.scan(model: model)
        }
    }

    private func scan(model: AppModel) async {
        let repo = model.repo
        let now = Int(Date().timeIntervalSince1970)
        let d = UserDefaults.standard
        if d.object(forKey: Self.sinceKey) == nil { d.set(now - Self.firstLookbackS, forKey: Self.sinceKey) }
        let from = max(now - Self.lookbackS, d.integer(forKey: Self.sinceKey))
        let hr = await repo.hrSamples(from: from, to: now, limit: 200_000)
        let steps = await repo.strapStepSamples(from: from, to: now)
        let dataEnd = max(hr.map(\.ts).max() ?? 0, steps.map(\.ts).max() ?? 0)
        guard dataEnd > from else { return }
        let gravity = await repo.gravitySamplesUnion(from: from, to: now)
        let sleeps = await repo.sleepSessions(from: from - 12 * 3600, to: now, limit: 20)
            .filter { $0.endTs >= $0.effectiveStartTs }
            .map { $0.effectiveStartTs...$0.endTs }
        let rows = await repo.workoutRows(days: 60)

        // Left alone: anything logged, the workout running now, sleep, and what was already offered.
        var exclude = rows.filter { $0.endTs > from }.map { $0.startTs...max($0.startTs, $0.endTs) }
        exclude += sleeps
        exclude += Self.offeredSpans
        if let w = model.activeWorkout { exclude.append(Int(w.start.timeIntervalSince1970)...now) }

        let scale = Self.stepTicksPerStep
        let minutes = StepsCounter.perMinute(steps).map {
            MissedWorkoutFinder.StepMinute(start: $0.start, steps: Int(Double($0.ticks) / scale),
                                           runSteps: Int(Double($0.runTicks) / scale))
        }
        let motion = WorkoutDetector.activitySeries(gravity).map {
            MissedWorkoutFinder.MotionPoint(ts: $0.ts, intensity: $0.intensity)
        }
        let found = MissedWorkoutFinder.find(
            steps: minutes, hr: hr.map { .init(ts: $0.ts, bpm: $0.bpm) }, motion: motion,
            restingBpm: Self.restingBpm(repo), exclude: exclude, dataEnd: dataEnd)
            .filter { $0.end <= now - Self.liveGraceS }

        let visits = PlaceVisitLog.spans(now: now)
        for bout in found {
            let isWalk = bout.kind != .effort
            guard isWalk ? AutoTrackingPrefs.walkEnabled : AutoTrackingPrefs.placesEnabled else { continue }
            var f = bout
            var sport: String
            if isWalk {
                sport = missedSport(f, rows: rows, hr: hr, gravity: gravity, steps: steps)
            } else {
                // Heart rate alone can't tell a lift from a stressful hour: one is recorded only when the
                // phone was at one of your places for it, and then as that place's sport, within the visit.
                guard let pv = placeVisit(for: f, visits: visits) else {
                    if MissedScan.unconfirmed.insert(f.start).inserted {
                        log("auto: heart rate up \(Self.time(f.start))–\(Self.time(f.end)), not at one of your places: not recorded")
                    }
                    continue
                }
                let (place, visit) = pv
                let start = max(f.start, visit.lowerBound - Self.visitSlackS)
                let end = min(f.end, visit.upperBound + Self.visitSlackS)
                guard end - start >= MissedWorkoutFinder.effortMinS else { continue }
                f = MissedWorkoutFinder.Found(start: start, end: end, kind: .effort, avgBpm: f.avgBpm, peakBpm: f.peakBpm)
                sport = place.sport
            }
            Self.rememberOffered(f.start...f.end)
            log("auto: found \(sport) \(Self.time(f.start))–\(Self.time(f.end)) in strap data (\(f.kind.rawValue))")
            switch isWalk ? AutoTrackingPrefs.walkMode : AutoTrackingPrefs.placesMode {
            case .auto:
                await saveMissed(f.start, f.end, sport: sport, avg: f.avgBpm, peak: f.peakBpm)
                let content = UNMutableNotificationContent()
                content.title = String(localized: "\(sport) saved")
                content.body = String(localized: "\(Self.time(f.start))–\(Self.time(f.end)), \(Self.duration(f.end - f.start)). From your strap, while your phone was away.")
                content.categoryIdentifier = Self.savedCategory
                content.userInfo = [Self.kTs: f.start, Self.kSport: sport, Self.kEndTs: f.end]
                content.threadIdentifier = "noop.auto"
                add(id: "noop.auto.missed.\(f.start)", content: content, quiet: true)
            case .ask:
                let content = UNMutableNotificationContent()
                content.title = String(localized: "\(sport)?")
                content.body = String(localized: "Your strap saw \(Self.duration(f.end - f.start)) from \(Self.time(f.start)) to \(Self.time(f.end)). Save it?")
                content.categoryIdentifier = Self.missedCategory
                var info: [String: Any] = [Self.kTs: f.start, Self.kEndTs: f.end, Self.kSport: sport]
                if let a = f.avgBpm { info[Self.kAvg] = a }
                if let p = f.peakBpm { info[Self.kPeak] = p }
                content.userInfo = info
                content.threadIdentifier = "noop.auto"
                add(id: "noop.auto.missed.\(f.start)", content: content, quiet: false)
            }
        }
    }

    /// A visit's ends are loose (a geofence fires late, iOS rounds visits): this much either side counts.
    private static let visitSlackS = 5 * 60

    /// The place a heart-rate workout was at: the phone's visit there covers at least half of it, or 10
    /// minutes. The place with the most overlap wins.

    private func placeVisit(for f: MissedWorkoutFinder.Found,
                            visits: [(placeId: String, span: ClosedRange<Int>)]) -> (WorkoutPlace, ClosedRange<Int>)? {
        let bout = f.start...f.end
        let need = min(10 * 60, (f.end - f.start) / 2)
        var best: (WorkoutPlace, ClosedRange<Int>, Int)?
        for v in visits {
            guard let p = place(id: v.placeId) else { continue }
            let widened = (v.span.lowerBound - Self.visitSlackS)...(v.span.upperBound + Self.visitSlackS)
            let o = max(0, min(bout.upperBound, widened.upperBound) - max(bout.lowerBound, widened.lowerBound))
            if o >= need, o > (best?.2 ?? 0) { best = (p, v.span, o) }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// Save an offered one from its notification.
    func saveMissed(_ info: [AnyHashable: Any]) {
        guard let start = info[Self.kTs] as? Int, let end = info[Self.kEndTs] as? Int,
              let sport = info[Self.kSport] as? String else { return }
        let box = BackgroundTaskBox()
        box.id = UIApplication.shared.beginBackgroundTask(withName: "noop.auto.missed.save") { box.end() }
        Task { @MainActor [weak self] in
            defer { box.end() }
            await self?.saveMissed(start, end, sport: sport, avg: info[Self.kAvg] as? Int, peak: info[Self.kPeak] as? Int)
        }
    }

    private func saveMissed(_ start: Int, _ end: Int, sport: String, avg: Int?, peak: Int?) async {
        guard let model else { return }
        let row = WorkoutRow(startTs: start, endTs: end, sport: sport, source: "manual",
                             durationS: Double(end - start), energyKcal: nil, avgHr: avg, maxHr: peak,
                             strain: nil, distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
        await model.repo.saveManualWorkout(row)
        // Effort, calories and zones from the strap's heart rate for the window, as a hand-logged one gets.
        await model.intelligence.analyzeRecent()
        await model.repo.refresh()
        log("auto: saved \(sport) from strap data")
    }

    // MARK: Sport

    /// Walks and runs say so. Anything else takes the sport you usually log at that time on that weekday
    /// (twice or more in the last 8 weeks), else what its shape looks like: a lift reads as your gym's
    /// sport, or Strength; cycling as Cycling; otherwise Workout. Change it on the workout any time.
    private func missedSport(_ f: MissedWorkoutFinder.Found, rows: [WorkoutRow], hr: [HRSample],
                             gravity: [GravitySample], steps: [StepSample]) -> String {
        switch f.kind {
        case .walk: return "Walking"
        case .run: return "Running"
        case .effort: break
        }
        let cal = Calendar.current
        let start = Date(timeIntervalSince1970: TimeInterval(f.start))
        let weekday = cal.component(.weekday, from: start)
        func minuteOfDay(_ d: Date) -> Int { cal.component(.hour, from: d) * 60 + cal.component(.minute, from: d) }
        let at = minuteOfDay(start)
        let onFoot: Set<String> = ["walking", "running", "hiking", "treadmill walk", "treadmill run"]
        var counts: [String: Int] = [:]
        for r in rows where r.startTs > f.start - 56 * 86_400 && r.startTs < f.start - 3600 {
            let d = Date(timeIntervalSince1970: TimeInterval(r.startTs))
            guard cal.component(.weekday, from: d) == weekday, !onFoot.contains(r.sport.lowercased()) else { continue }
            let diff = abs(minuteOfDay(d) - at)
            if min(diff, 1440 - diff) <= 90 { counts[r.sport, default: 0] += 1 }
        }
        if let best = counts.max(by: { $0.value < $1.value }), best.value >= 2 { return best.key }

        let features = WorkoutTypeFeatureExtractor.extract(hr: hr, gravity: gravity, steps: steps,
                                                           start: f.start, end: f.end,
                                                           restingHR: model.map { Double(Self.restingBpm($0.repo)) })
        switch features.map(WorkoutTypeClassifier.classify)?.predictedClass {
        case .strength:
            return places.first { LiveIntervalModes.mode(forSport: $0.sport) == .lifting }?.sport ?? "Strength"
        case .cycle:
            return "Cycling"
        default:
            return "Workout"
        }
    }

    private static var stepTicksPerStep: Double {
        let v = UserDefaults.standard.object(forKey: "profile.stepTicksPerStep") as? Double ?? 1.0
        return min(max(v, 0.5), 30.0)
    }
}

/// One scan at a time, and not too often.
@MainActor
private enum MissedScan {
    static var running = false
    static var last = Date.distantPast
    /// Heart-rate stretches already logged as not at a place, so the log says it once.
    static var unconfirmed: Set<Int> = []
}

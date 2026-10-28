import Foundation
import StrandAnalytics

/// A pinned place where a sport happens: the gym, the rink, the track.
struct WorkoutPlace: Codable, Identifiable, Equatable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var latitude: Double
    var longitude: Double
    var radiusM: Double = AutoTrackingPrefs.defaultRadiusM
    /// Catalogue sport name saved on workouts started here.
    var sport: String
    /// Heart rate at or above resting + this counts as working.
    var marginBPM: Int
    /// End after this many minutes of heart rate near resting while still here.
    var quietEndMin: Int

    var params: LiveWorkoutSuggestionEngine.PlaceParams {
        .init(marginBPM: marginBPM, quietEndS: quietEndMin * 60)
    }

    /// Sensible starting thresholds for a sport: lifting barely moves heart rate between sets, games move
    /// it a lot and have long benches.
    static func defaults(for sport: String) -> (marginBPM: Int, quietEndMin: Int) {
        LiveIntervalModes.mode(forSport: sport) == .lifting ? (20, 10) : (30, 15)
    }
}

enum AutoTrackingPrefs {
    static let placesEnabledKey = "noopAutoPlacesEnabled"
    static let walkEnabledKey = "noopAutoWalkEnabled"
    /// "auto" (default) starts and ends workouts on its own. "ask" sends a notification to tap instead.
    static let placesModeKey = "noopAutoPlacesMode"
    static let walkModeKey = "noopAutoWalkMode"
    static let intervalSensitivityKey = "noopIntervalSensitivity"
    static let placesKey = "noopWorkoutPlaces"

    /// Your circle. Small ones work: the geofence only wakes the check, and GPS decides you're inside.
    static let defaultRadiusM = 60.0
    static let minRadiusM = 20.0
    static let maxRadiusM = 500.0

    enum Mode: String, CaseIterable, Identifiable {
        case auto, ask
        var id: String { rawValue }
    }

    static var placesEnabled: Bool { UserDefaults.standard.bool(forKey: placesEnabledKey) }
    static var walkEnabled: Bool { UserDefaults.standard.bool(forKey: walkEnabledKey) }
    static var anyEnabled: Bool { placesEnabled || walkEnabled }

    static var placesMode: Mode {
        Mode(rawValue: UserDefaults.standard.string(forKey: placesModeKey) ?? "") ?? .auto
    }
    static var walkMode: Mode {
        Mode(rawValue: UserDefaults.standard.string(forKey: walkModeKey) ?? "") ?? .auto
    }

    static var intervalSensitivity: Double {
        let v = UserDefaults.standard.double(forKey: intervalSensitivityKey)
        return v > 0 ? v : 1.0
    }

    static func loadPlaces() -> [WorkoutPlace] {
        migrateLegacyGymIfNeeded()
        guard let data = UserDefaults.standard.data(forKey: placesKey),
              let places = try? JSONDecoder().decode([WorkoutPlace].self, from: data) else { return [] }
        return places
    }

    static func savePlaces(_ places: [WorkoutPlace]) {
        if let data = try? JSONEncoder().encode(places) {
            UserDefaults.standard.set(data, forKey: placesKey)
        }
    }

    /// The first version saved one gym under separate keys and used different toggle keys. Carry both
    /// over once.
    private static func migrateLegacyGymIfNeeded() {
        let d = UserDefaults.standard
        let flag = "noopAutoTrackingMigratedV2"
        guard !d.bool(forKey: flag) else { return }
        d.set(true, forKey: flag)
        if d.bool(forKey: "noopLiveGymSuggest") { d.set(true, forKey: placesEnabledKey) }
        if d.bool(forKey: "noopLiveWalkSuggest") { d.set(true, forKey: walkEnabledKey) }
        guard d.data(forKey: placesKey) == nil,
              d.object(forKey: "noopLiveGymLat") != nil,
              d.object(forKey: "noopLiveGymLon") != nil else { return }
        let sport = d.string(forKey: "noopLiveGymSport").flatMap { $0.isEmpty ? nil : $0 } ?? "Strength"
        let r = d.double(forKey: "noopLiveGymRadius")
        let defaults = WorkoutPlace.defaults(for: sport)
        let gym = WorkoutPlace(name: "Gym", latitude: d.double(forKey: "noopLiveGymLat"),
                               longitude: d.double(forKey: "noopLiveGymLon"),
                               radiusM: r > 0 ? r : defaultRadiusM, sport: sport,
                               marginBPM: defaults.marginBPM, quietEndMin: defaults.quietEndMin)
        savePlaces([gym])
    }
}

/// When you were at each of your places, from the geofence crossings and from iOS's visit detection. Lets
/// a workout found afterwards in the strap's heart rate be confirmed by where the phone was: heart rate
/// alone can't tell a lift from a stressful hour. Kept a week, on device.
@MainActor
enum PlaceVisitLog {
    struct Visit: Codable, Equatable {
        let placeId: String
        var start: Int
        /// nil while you're still there.
        var end: Int?
    }

    private static let key = "noopPlaceVisits"
    /// A visit with no exit is taken to last at most this long.
    static let openMaxS = 4 * 3600
    /// A visit left and re-entered within this is one visit.
    static let rejoinS = 10 * 60

    static var all: [Visit] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let v = try? JSONDecoder().decode([Visit].self, from: data) else { return [] }
        return v
    }

    private static func store(_ v: [Visit]) {
        let cutoff = Int(Date().timeIntervalSince1970) - 7 * 86_400
        let kept = v.filter { ($0.end ?? $0.start + openMaxS) >= cutoff }.suffix(200)
        if let data = try? JSONEncoder().encode(Array(kept)) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func entered(_ placeId: String, at ts: Int) {
        var v = all
        if let i = v.lastIndex(where: { $0.placeId == placeId && ($0.end == nil || ts - ($0.end ?? 0) <= rejoinS) }) {
            v[i].start = min(v[i].start, ts)
            v[i].end = nil
        } else {
            v.append(Visit(placeId: placeId, start: ts, end: nil))
        }
        store(v)
    }

    static func left(_ placeId: String, at ts: Int) {
        var v = all
        guard let i = v.lastIndex(where: { $0.placeId == placeId && $0.end == nil }) else { return }
        v[i].end = max(v[i].start, ts)
        store(v)
    }

    /// A visit iOS detected afterwards: joined with any it overlaps at the same place.
    static func visited(_ placeId: String, from start: Int, to end: Int?) {
        var v = all
        let span = start...(end ?? start + openMaxS)
        if let i = v.firstIndex(where: { $0.placeId == placeId && ($0.start...($0.end ?? $0.start + openMaxS)).overlaps(span) }) {
            v[i].start = min(v[i].start, start)
            if let e = end, let old = v[i].end { v[i].end = max(old, e) }
        } else {
            v.append(Visit(placeId: placeId, start: start, end: end))
        }
        store(v)
    }

    /// Visits as spans, an open one up to now (at most `openMaxS`).
    static func spans(now: Int) -> [(placeId: String, span: ClosedRange<Int>)] {
        all.map { v in
            let end = v.end ?? min(now, v.start + openMaxS)
            return (v.placeId, v.start...max(v.start, end))
        }
    }
}

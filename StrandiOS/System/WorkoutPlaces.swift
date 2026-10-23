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

    static let defaultRadiusM = 150.0
    static let minRadiusM = 100.0
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

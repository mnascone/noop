import Foundation

/// What the live heart-rate banner (Lock Screen + Dynamic Island) can show. The app picks the order and
/// sends it in the activity's state; the widget draws whatever it's given. Raw values cross into the widget
/// extension through ActivityKit, so they must never change.
public enum LiveBannerField: String, CaseIterable, Codable, Hashable, Sendable {
    case heartRate
    case zone
    case charge
    case effort
    case rest
    case steps
    case calories
    case hrv
    case restingHr
    case workoutTime
    case restTimer
    case sets

    public var label: String {
        switch self {
        case .heartRate: return "Heart rate"
        case .zone: return "Zone"
        case .charge: return "Charge"
        case .effort: return "Effort"
        case .rest: return "Sleep"
        case .steps: return "Steps"
        case .calories: return "Calories"
        case .hrv: return "HRV"
        case .restingHr: return "Resting HR"
        case .workoutTime: return "Workout"
        case .restTimer: return "Rest"
        case .sets: return "Sets"
        }
    }

    public var symbol: String {
        switch self {
        case .heartRate: return "heart.fill"
        case .zone: return "gauge.with.dots.needle.67percent"
        case .charge: return "battery.100.bolt"
        case .effort: return "flame.fill"
        case .rest: return "bed.double.fill"
        case .steps: return "figure.walk"
        case .calories: return "bolt.heart.fill"
        case .hrv: return "waveform.path.ecg"
        case .restingHr: return "heart.text.square.fill"
        case .workoutTime: return "stopwatch.fill"
        case .restTimer: return "pause.circle.fill"
        case .sets: return "dumbbell.fill"
        }
    }

    /// Fields that only have a value during a workout. Shown only while one is running.
    public var workoutOnly: Bool {
        self == .workoutTime || self == .restTimer || self == .sets
    }
}

/// How the banner arranges its fields.
public enum LiveBannerLayout: String, CaseIterable, Codable, Hashable, Sendable {
    /// The first field large, the rest small beside it.
    case featured
    /// All fields the same size, side by side.
    case equal

    public var label: String {
        switch self {
        case .featured: return "First one big"
        case .equal: return "All the same size"
        }
    }
}

public enum LiveBannerPrefs {
    public static let fieldsKey = "liveActivity.fields"
    public static let islandFieldKey = "liveActivity.islandField"
    public static let layoutKey = "liveActivity.layout"
    public static let showLabelsKey = "liveActivity.showLabels"
    public static let titleKey = "liveActivity.title"
    public static let workoutFieldsKey = "liveActivity.workoutFields"

    /// The banner as it always was: heart rate, Charge, Effort.
    public static let defaultFields: [LiveBannerField] = [.heartRate, .charge, .effort]
    /// What to show instead while a workout runs (nil = the same fields as always).
    public static let defaultWorkoutFields: [LiveBannerField] = [.restTimer, .heartRate, .sets, .workoutTime]
    public static let maxFields = 4

    public static func load(_ d: UserDefaults = .standard) -> [LiveBannerField] {
        decode(d.array(forKey: fieldsKey)) ?? defaultFields
    }

    public static func save(_ fields: [LiveBannerField], _ d: UserDefaults = .standard) {
        d.set(encode(fields), forKey: fieldsKey)
    }

    /// Fields while a workout runs. nil = "same as normal" (the setting is off).
    public static func loadWorkout(_ d: UserDefaults = .standard) -> [LiveBannerField]? {
        decode(d.array(forKey: workoutFieldsKey))
    }

    public static func saveWorkout(_ fields: [LiveBannerField]?, _ d: UserDefaults = .standard) {
        if let fields { d.set(encode(fields), forKey: workoutFieldsKey) } else { d.removeObject(forKey: workoutFieldsKey) }
    }

    /// nil = follow the first field.
    public static func islandField(_ d: UserDefaults = .standard) -> LiveBannerField? {
        d.string(forKey: islandFieldKey).flatMap(LiveBannerField.init(rawValue:))
    }

    public static func layout(_ d: UserDefaults = .standard) -> LiveBannerLayout {
        d.string(forKey: layoutKey).flatMap(LiveBannerLayout.init(rawValue:)) ?? .featured
    }

    public static func showLabels(_ d: UserDefaults = .standard) -> Bool {
        d.object(forKey: showLabelsKey) == nil ? true : d.bool(forKey: showLabelsKey)
    }

    /// Custom title line. nil = the first field's name (or the workout's sport).
    public static func title(_ d: UserDefaults = .standard) -> String? {
        let t = (d.string(forKey: titleKey) ?? "").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : String(t.prefix(24))
    }

    private static func decode(_ raw: [Any]?) -> [LiveBannerField]? {
        guard let raw = raw as? [String] else { return nil }
        let fields = raw.compactMap(LiveBannerField.init(rawValue:))
        return fields.isEmpty ? nil : Array(fields.prefix(maxFields))
    }

    private static func encode(_ fields: [LiveBannerField]) -> [String] {
        var seen = Set<LiveBannerField>()
        return Array(fields.filter { seen.insert($0).inserted }.prefix(maxFields)).map(\.rawValue)
    }
}

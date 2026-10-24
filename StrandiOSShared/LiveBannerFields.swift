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
    // Added later: values arrive pre-formatted in `ContentState.texts`, keyed by raw value.
    case battery
    case batteryTime
    case sleepTime
    case skinTemp
    case respiration
    case spo2
    case workoutEffort
    case avgHr
    case peakHr
    case distance
    case pace
    /// Battery drawn as a gauge with the time left under it.
    case batteryFull
    /// Lifting: green / yellow / red for starting the next set, from heart-rate recovery.
    case setReady
    /// Stress 0-100: live from beat-to-beat HRV, else today's latest scored hour.
    case stress

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
        case .battery: return "WHOOP battery"
        case .batteryTime: return "WHOOP battery left"
        case .sleepTime: return "Slept"
        case .skinTemp: return "Skin temp"
        case .respiration: return "Breathing"
        case .spo2: return "Blood O₂"
        case .workoutEffort: return "Workout effort"
        case .avgHr: return "Avg HR"
        case .peakHr: return "Peak HR"
        case .distance: return "Distance"
        case .pace: return "Pace"
        case .batteryFull: return "Complete battery"
        case .setReady: return "Ready for next set"
        case .stress: return "Stress"
        }
    }

    /// The value is its own picture (the battery gauge), so the banner leaves off the icon above it.
    public var drawsOwnIcon: Bool { self == .batteryFull }

    /// The name on the banner itself, where space is tight. Same as `label` except where that runs long.
    public var bannerLabel: String {
        switch self {
        case .battery, .batteryTime, .batteryFull: return "Battery"
        case .restingHr: return "RHR"
        case .workoutEffort: return "Effort"
        case .setReady: return "Next set"
        default: return label
        }
    }

    public var symbol: String {
        switch self {
        case .heartRate: return "heart.fill"
        case .zone: return "gauge.with.dots.needle.67percent"
        case .charge: return "arrow.clockwise.heart.fill"
        case .effort: return "flame.fill"
        case .rest: return "bed.double.fill"
        case .steps: return "figure.walk"
        case .calories: return "bolt.heart.fill"
        case .hrv: return "waveform.path.ecg"
        case .restingHr: return "heart.text.square.fill"
        case .workoutTime: return "stopwatch.fill"
        case .restTimer: return "pause.circle.fill"
        case .sets: return "dumbbell.fill"
        case .battery: return "battery.75percent"
        case .batteryTime: return "hourglass"
        case .sleepTime: return "moon.zzz.fill"
        case .skinTemp: return "thermometer.medium"
        case .respiration: return "lungs.fill"
        case .spo2: return "drop.fill"
        case .workoutEffort: return "flame.circle.fill"
        case .avgHr: return "heart.circle"
        case .peakHr: return "arrow.up.heart.fill"
        case .distance: return "point.topleft.down.to.point.bottomright.curvepath"
        case .pace: return "speedometer"
        case .batteryFull: return "battery.100percent"
        case .setReady: return "light.beacon.max"
        case .stress: return "gauge.with.dots.needle.33percent"
        }
    }

    /// The icon colour out of the box, as RGB hex. Each field gets its own so they're easy to tell apart.
    public var defaultColorHex: String {
        switch self {
        case .heartRate, .avgHr, .peakHr: return "FF453A"
        case .zone: return "FF9F0A"
        case .charge: return "30D158"
        case .effort, .workoutEffort: return "FF9F0A"
        case .rest, .sleepTime: return "8E7CFF"
        case .steps: return "64D2FF"
        case .calories: return "FF6B3D"
        case .hrv: return "BF5AF2"
        case .restingHr: return "FF375F"
        case .workoutTime, .restTimer: return "FFD60A"
        case .sets: return "5AC8FA"
        case .battery, .batteryTime: return "34C759"
        case .skinTemp: return "FFB340"
        case .respiration: return "64D2FF"
        case .spo2: return "0A84FF"
        case .distance, .pace: return "66D4CF"
        case .batteryFull: return "34C759"
        case .setReady: return "30D158"
        case .stress: return "FFB340"
        }
    }

    /// Fields that only have a value during a workout. Shown only while one is running.
    public var workoutOnly: Bool {
        switch self {
        case .workoutTime, .restTimer, .sets, .workoutEffort, .avgHr, .peakHr, .distance, .pace, .setReady: return true
        default: return false
        }
    }

    /// Grouping for the picker.
    public var group: String {
        switch self {
        case .heartRate, .zone, .stress: return "Live"
        case .charge, .effort, .rest, .steps, .calories: return "Today"
        case .hrv, .restingHr, .sleepTime, .skinTemp, .respiration, .spo2: return "Last night"
        case .battery, .batteryTime, .batteryFull: return "WHOOP strap"
        case .workoutTime, .restTimer, .sets, .workoutEffort, .avgHr, .peakHr, .distance, .pace, .setReady:
            return "Workout"
        }
    }

    /// Value comes pre-formatted in `ContentState.texts`.
    public var usesText: Bool {
        switch self {
        case .battery, .batteryTime, .sleepTime, .skinTemp, .respiration, .spo2, .workoutEffort, .avgHr,
             .peakHr, .distance, .pace, .batteryFull, .setReady, .stress: return true
        default: return false
        }
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
    /// Icon colour overrides: field raw value → RGB hex.
    public static let colorsKey = "liveActivity.colors"

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

    /// The user's colour overrides (field raw value → hex). Missing fields use `defaultColorHex`.
    public static func colors(_ d: UserDefaults = .standard) -> [String: String] {
        (d.dictionary(forKey: colorsKey) as? [String: String]) ?? [:]
    }

    public static func setColor(_ hex: String?, for field: LiveBannerField, _ d: UserDefaults = .standard) {
        var c = colors(d)
        c[field.rawValue] = hex
        if c.isEmpty { d.removeObject(forKey: colorsKey) } else { d.set(c, forKey: colorsKey) }
    }

    public static func colorHex(_ field: LiveBannerField, overrides: [String: String]) -> String {
        overrides[field.rawValue] ?? field.defaultColorHex
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

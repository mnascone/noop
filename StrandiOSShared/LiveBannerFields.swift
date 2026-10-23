import Foundation

/// What the live heart-rate banner (Lock Screen + Dynamic Island) can show. The app picks the order and
/// sends it in the activity's state; the widget draws whatever it's given. Raw values cross into the widget
/// extension through ActivityKit, so they must never change.
public enum LiveBannerField: String, CaseIterable, Codable, Hashable, Sendable {
    case heartRate
    case charge
    case effort
    case rest
    case workoutTime
    case restTimer
    case sets

    public var label: String {
        switch self {
        case .heartRate: return "Heart rate"
        case .charge: return "Charge"
        case .effort: return "Effort"
        case .rest: return "Sleep"
        case .workoutTime: return "Workout"
        case .restTimer: return "Rest"
        case .sets: return "Sets"
        }
    }

    public var symbol: String {
        switch self {
        case .heartRate: return "heart.fill"
        case .charge: return "battery.100.bolt"
        case .effort: return "flame.fill"
        case .rest: return "bed.double.fill"
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

public enum LiveBannerPrefs {
    public static let fieldsKey = "liveActivity.fields"
    /// The banner as it always was: heart rate, Charge, Effort.
    public static let defaultFields: [LiveBannerField] = [.heartRate, .charge, .effort]
    /// The first field is drawn large; up to three more sit beside it.
    public static let maxFields = 4

    public static func load(_ defaults: UserDefaults = .standard) -> [LiveBannerField] {
        guard let raw = defaults.array(forKey: fieldsKey) as? [String] else { return defaultFields }
        let fields = raw.compactMap(LiveBannerField.init(rawValue:))
        return fields.isEmpty ? defaultFields : Array(fields.prefix(maxFields))
    }

    public static func save(_ fields: [LiveBannerField], _ defaults: UserDefaults = .standard) {
        var seen = Set<LiveBannerField>()
        let unique = fields.filter { seen.insert($0).inserted }
        defaults.set(Array(unique.prefix(maxFields)).map(\.rawValue), forKey: fieldsKey)
    }
}

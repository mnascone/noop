#if os(iOS)
import Foundation
import ActivityKit

/// Live Activity attributes for an active live-HR / workout session. Shared between the app (which
/// starts/updates the activity) and the widget extension (which renders it on the Lock Screen and in
/// the Dynamic Island).
public struct NOOPActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var bpm: Int?
        public var recovery: Int?
        public var bonded: Bool
        // Effort / strain on NOOP's 0–100 axis (#446) — one more stat in the Dynamic Island expanded
        // region. OPTIONAL with a nil default so an activity started by an older build still decodes.
        public var effort: Int?
        // Customizable banner (personal build). All OPTIONAL, so an activity from an older build still decodes.
        /// The fields to draw, in order. nil = the classic heart rate / Charge / Effort.
        public var fields: [LiveBannerField]?
        /// Last night's sleep score, 0–100.
        public var rest: Int?
        /// The running workout, if any. Timers count on the Lock Screen on their own, from these dates.
        public var workoutStart: Date?
        public var workoutSport: String?
        /// When the current rest began; nil while working or with no tracked workout.
        public var restSince: Date?
        public var setCount: Int?
        public var steps: Int?
        public var calories: Int?
        public var zone: Int?
        public var hrv: Int?
        public var restingHr: Int?
        /// Banner look: Dynamic Island field (nil = first field), layout, labels, title (nil = automatic).
        public var islandField: LiveBannerField?
        public var layout: LiveBannerLayout?
        public var showLabels: Bool?
        public var title: String?
        /// Pre-formatted values for the later fields, keyed by `LiveBannerField.rawValue`.
        public var texts: [String: String]?

        public init(bpm: Int?, recovery: Int?, bonded: Bool, effort: Int? = nil,
                    fields: [LiveBannerField]? = nil, rest: Int? = nil, workoutStart: Date? = nil,
                    workoutSport: String? = nil, restSince: Date? = nil, setCount: Int? = nil,
                    steps: Int? = nil, calories: Int? = nil, zone: Int? = nil, hrv: Int? = nil,
                    restingHr: Int? = nil, islandField: LiveBannerField? = nil, layout: LiveBannerLayout? = nil,
                    showLabels: Bool? = nil, title: String? = nil, texts: [String: String]? = nil) {
            self.bpm = bpm
            self.recovery = recovery
            self.bonded = bonded
            self.effort = effort
            self.fields = fields
            self.rest = rest
            self.workoutStart = workoutStart
            self.workoutSport = workoutSport
            self.restSince = restSince
            self.setCount = setCount
            self.steps = steps
            self.calories = calories
            self.zone = zone
            self.hrv = hrv
            self.restingHr = restingHr
            self.islandField = islandField
            self.layout = layout
            self.showLabels = showLabels
            self.title = title
            self.texts = texts
        }
    }

    /// Static title shown for the session.
    public var title: String

    public init(title: String = "Live HR") {
        self.title = title
    }
}
#endif

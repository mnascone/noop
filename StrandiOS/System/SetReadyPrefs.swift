import Foundation
import StrandAnalytics

/// Settings for the lifting "ready for the next set" light and the rest timer.
enum SetReadyPrefs {
    static let enabledKey = "noop.setReady.enabled"
    static let autoKey = "noop.setReady.auto"
    static let greenKey = "noop.setReady.greenBpm"
    static let yellowKey = "noop.setReady.yellowBpm"
    static let minRestKey = "noop.setReady.minRestS"
    static let targetRestKey = "noop.setReady.targetRestS"
    static let buzzKey = "noop.setReady.buzz"

    private static var d: UserDefaults { .standard }

    /// On unless switched off.
    static var enabled: Bool { d.object(forKey: enabledKey) == nil ? true : d.bool(forKey: enabledKey) }
    static var buzz: Bool { d.bool(forKey: buzzKey) }

    static var config: SetReadiness.Config {
        func int(_ k: String, _ fallback: Int) -> Int { d.object(forKey: k) == nil ? fallback : d.integer(forKey: k) }
        return SetReadiness.Config(
            auto: d.object(forKey: autoKey) == nil ? true : d.bool(forKey: autoKey),
            greenBpm: int(greenKey, 110), yellowBpm: int(yellowKey, 125),
            minRestS: int(minRestKey, 45), targetRestS: int(targetRestKey, 120))
    }
}

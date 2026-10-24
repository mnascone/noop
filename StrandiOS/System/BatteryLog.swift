import Foundation
import Combine
import StrandAnalytics

/// A rolling log of the strap's battery level with the phone-side features that were on, for the battery
/// page's chart and per-feature drain. One reading per level change (or every 15 minutes at a steady
/// level), kept for 14 days, on this device only.
@MainActor
final class BatteryLog: ObservableObject {
    static let shared = BatteryLog()
    static let storeKey = "noop.batteryLog.v1"
    static let keepDays = 14.0

    @Published private(set) var samples: [BatteryDrainAnalysis.Sample] = []

    private weak var model: AppModel?
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let decoded = try? JSONDecoder().decode([BatteryDrainAnalysis.Sample].self, from: data) {
            samples = decoded
        }
    }

    func attach(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        model.live.$batteryPct
            .combineLatest(model.live.$charging)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pct, charging in self?.record(pct: pct, charging: charging == true) }
            .store(in: &cancellables)
        // A steady level still gets a reading now and then, and a feature switching on or off gets one at
        // once, so each stretch is charged to the features that were really on.
        Timer.publish(every: 600, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.recordNow() }
            .store(in: &cancellables)
        model.$activeWorkout.map { $0 != nil }.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recordNow() }
            .store(in: &cancellables)
    }

    private func recordNow() {
        guard let model else { return }
        record(pct: model.live.batteryPct, charging: model.live.charging == true)
    }

    /// The features on right now, as `BatteryDrainAnalysis.Feature` bits.
    func currentFeatures() -> Int {
        guard let model else { return 0 }
        var f = 0
        if model.ble.realtimeStreaming { f |= BatteryDrainAnalysis.Feature.liveHeartRate.rawValue }
        if model.ble.repImuActive { f |= BatteryDrainAnalysis.Feature.motionStream.rawValue }
        if model.activeWorkout != nil { f |= BatteryDrainAnalysis.Feature.workout.rawValue }
        if PuffinExperiment.keepRealtimeForDataEnabled { f |= BatteryDrainAnalysis.Feature.continuousHrv.rawValue }
        if UserDefaults.standard.bool(forKey: "enableRawCapture") { f |= BatteryDrainAnalysis.Feature.rawCapture.rawValue }
        if UnitPrefs.liveActivityEnabled() { f |= BatteryDrainAnalysis.Feature.lockScreenBanner.rawValue }
        return f
    }

    private func record(pct: Double?, charging: Bool) {
        guard let pct, pct > 0, model?.live.connected == true else { return }
        let now = Date().timeIntervalSince1970
        let features = currentFeatures()
        if let last = samples.last, abs(last.pct - pct) < 0.5, last.charging == charging,
           last.features == features, now - last.ts < 15 * 60 { return }
        samples.append(.init(ts: now, pct: pct, charging: charging, features: features))
        let cutoff = now - Self.keepDays * 86_400
        if let first = samples.first, first.ts < cutoff { samples.removeAll { $0.ts < cutoff } }
        if let data = try? JSONEncoder().encode(samples) { UserDefaults.standard.set(data, forKey: Self.storeKey) }
    }
}

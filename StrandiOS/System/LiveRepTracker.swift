import Foundation
import Combine
import StrandAnalytics
import WhoopProtocol

/// Counts reps from the strap's wrist motion during a lifting workout (WHOOP 5.0/MG, opt-in).
///
/// While a lifting workout runs and the setting is on, the strap streams raw accelerometer and gyroscope
/// data; `RepCounter` turns it into sets with rep counts. The stream stops when the workout ends, so it
/// costs strap battery only while lifting. Experimental: counts are estimates to check against your log.
@MainActor
final class LiveRepTracker: ObservableObject {
    static let shared = LiveRepTracker()
    static let enabledKey = "noop.repCounting"

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    @Published private(set) var active = false
    @Published private(set) var sets: [RepCounter.RepSet] = []
    @Published private(set) var currentReps: Int?

    private var counter: RepCounter?
    private weak var model: AppModel?
    private var cancellables: Set<AnyCancellable> = []
    private var frameSub: AnyCancellable?
    private var trackedStart: Int?
    private var wasConnected = false

    private init() {}

    func attach(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        model.$activeWorkout
            .sink { [weak self] _ in DispatchQueue.main.async { self?.evaluate() } }
            .store(in: &cancellables)
        LiveIntervalTracker.shared.$mode
            .sink { [weak self] _ in DispatchQueue.main.async { self?.evaluate() } }
            .store(in: &cancellables)
        model.live.$connected
            .removeDuplicates()
            .sink { [weak self] connected in
                DispatchQueue.main.async { self?.connectionChanged(connected) }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .map { _ in LiveRepTracker.enabled }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &cancellables)
    }

    private var wanted: Bool {
        guard let model, Self.enabled, model.activeWorkout != nil, model.live.connected,
              LiveIntervalTracker.shared.mode == .lifting, model.ble.supportsLiveImu else { return false }
        return true
    }

    private func evaluate() {
        guard let model else { return }
        let start = model.activeWorkout.map { Int($0.start.timeIntervalSince1970) }
        if start != trackedStart {
            // A new workout (or none): start fresh.
            sets = []
            currentReps = nil
            counter = nil
            trackedStart = start
        }
        if wanted, !active {
            guard model.ble.startRepImu() else { return }
            if counter == nil { counter = RepCounter() }
            active = true
            frameSub = model.ble.imuFrames
                .receive(on: DispatchQueue.main)
                .sink { [weak self] frame in self?.ingest(frame) }
        } else if !wanted, active {
            stopStream()
        }
    }

    private func connectionChanged(_ connected: Bool) {
        defer { wasConnected = connected }
        guard let model else { return }
        if connected, !wasConnected, active {
            // The strap drops the stream with the link; ask for it again.
            Task { @MainActor in
                await model.ble.stopRepImu()
                model.ble.startRepImu()
            }
        }
        evaluate()
    }

    private func stopStream() {
        active = false
        frameSub = nil
        counter?.finish()
        publish()
        currentReps = nil
        if let model { Task { await model.ble.stopRepImu() } }
    }

    private func ingest(_ frame: Whoop5ImuFrame) {
        guard active, model?.activeWorkout?.isPaused != true else { return }
        let samples = frame.samples.enumerated().map { i, s in
            RepCounter.Sample(t: frame.ts(of: i), ax: s.ax, ay: s.ay, az: s.az, gx: s.gx, gy: s.gy, gz: s.gz)
        }
        counter?.feed(samples)
        publish()
    }

    private func publish() {
        guard let c = counter else { return }
        if c.sets != sets { sets = c.sets }
        let cur = c.currentReps
        if cur != currentReps { currentReps = cur }
    }

    /// "Reps 10 · 8 · 12" for the workout's notes, or nil when nothing was counted.
    func notesLine(start: Int) -> String? {
        guard trackedStart == start, !sets.isEmpty else { return nil }
        return String(localized: "Reps \(sets.map { String($0.reps) }.joined(separator: " · ")) (from wrist motion)")
    }
}

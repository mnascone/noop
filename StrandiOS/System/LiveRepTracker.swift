import Foundation
import Combine
import StrandAnalytics
import WhoopProtocol

/// Counts reps from the strap's wrist motion during a lifting workout (WHOOP 5.0/MG, opt-in).
///
/// While a lifting workout runs and the setting is on, the strap streams raw accelerometer and gyroscope
/// data; `RepCounter` turns its steady, rhythmic stretches into candidate sets. A candidate becomes a set
/// only when heart rate rises with it (`hrRiseBPM` above where it started, by `confirmWindowS` after it
/// ends), so a warm-up swing or a walk between machines with a steady arm doesn't count. The stream stops when the workout ends, so it
/// costs strap battery only while lifting. Experimental: counts are estimates to check against your log.
@MainActor
final class LiveRepTracker: ObservableObject {
    static let shared = LiveRepTracker()
    static let enabledKey = "noop.repCounting"

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    @Published private(set) var active = false
    /// Sets confirmed by both motion and heart rate.
    @Published private(set) var sets: [RepCounter.RepSet] = []
    @Published private(set) var currentReps: Int?
    /// When the set in progress began (unix seconds), while one is counting.
    @Published private(set) var currentSetStart: Double?
    /// What the counter sees right now (the set in progress, or the last stretch of motion), for the
    /// motion map. Refreshed about twice a second.
    @Published private(set) var analysis: RepCounter.Analysis?
    private var lastAnalysisAt = Date.distantPast

    /// Heart rate must climb this far above its level at the set's start.
    static let hrRiseBPM = 6
    /// How long after a set ends its heart-rate rise may still arrive.
    static let confirmWindowS = 60.0

    /// Recent heart rate, unix seconds, for confirming sets.
    private(set) var hr: [(ts: Double, bpm: Int)] = []

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
        model.live.$heartRate
            .sink { [weak self] bpm in
                guard let self, let bpm, bpm > 0, self.active || self.counter != nil else { return }
                let now = Date().timeIntervalSince1970
                self.hr.append((now, bpm))
                if let f = self.hr.first, now - f.ts > 3 * 3600 { self.hr.removeAll { now - $0.ts > 3 * 3600 } }
                self.publish()
            }
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
            currentSetStart = nil
            analysis = nil
            counter = nil
            hr = []
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
        currentSetStart = nil
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
        // A set shows once its heart rate has risen; one that never rises within the window never shows.
        let confirmed = c.sets.filter { set in
            guard let rise = hrRise(set) else {
                // No heart rate at all: keep motion's call rather than lose every set.
                return hr.isEmpty
            }
            return rise >= Self.hrRiseBPM
        }
        if confirmed != sets { sets = confirmed }
        let cur = c.currentReps.flatMap { $0 >= RepCounter.minReps ? $0 : nil }
        if cur != currentReps { currentReps = cur }
        let start = cur == nil ? nil : c.inProgressStart
        if start != currentSetStart { currentSetStart = start }
        if Date().timeIntervalSince(lastAnalysisAt) >= 0.5 {
            lastAnalysisAt = Date()
            let a = c.currentAnalysis
            if a != analysis { analysis = a }
        }
    }

    /// How far heart rate climbed from the set's start to its peak during the set or within
    /// `confirmWindowS` after it. nil with no heart rate around the set.
    func hrRise(_ set: RepCounter.RepSet) -> Int? {
        let before = hr.filter { $0.ts >= set.start - 15 && $0.ts <= set.start + 3 }.map(\.bpm)
        let during = hr.filter { $0.ts >= set.start && $0.ts <= set.end + Self.confirmWindowS }.map(\.bpm)
        guard let peak = during.max() else { return nil }
        let base = before.isEmpty ? (during.first ?? peak) : before.sorted()[before.count / 2]
        return peak - base
    }

    /// Peak heart rate of a set (during it or just after, where it usually lands).
    func peakHR(_ set: RepCounter.RepSet) -> Int? {
        hr.filter { $0.ts >= set.start && $0.ts <= set.end + 30 }.map(\.bpm).max()
    }

    /// "Reps 10 · 8 · 12" for the workout's notes, or nil when nothing was counted.
    func notesLine(start: Int) -> String? {
        guard trackedStart == start, !sets.isEmpty else { return nil }
        return String(localized: "Reps \(sets.map { String($0.reps) }.joined(separator: " · ")) (from wrist motion, confirmed by heart rate)")
    }
}

import Foundation
import Combine
import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// The one place "stress now" comes from, shared by the Today ring, the Stress screen, Pace, the coach
/// and the Lock Screen, so they can't disagree. It is the all-day stress level (`StressLevel`, 0-100,
/// Garmin's bands): the newest stored 3-minute value, or, while beats stream, the current stretch scored
/// the same way against the same baseline. Every reading carries its kind and its time.
///
/// In order, the first that exists wins:
///   1. Live: beats arriving in the last 15 s, the last three minutes of them.
///   2. Measured: a one-minute measurement taken in the last 30 minutes.
///   3. Recent: the newest stored 3-minute value, when it's from the last 15 minutes.
///   4. Earlier: the newest stored value today, shown with its time.
/// A stretch spent moving reads Active, never a stale number.
///
/// The morning factors (last night's resting heart rate and HRV against your 30 days, the 0-3 score)
/// stay available as `daily` for the Stress screen's breakdown, and tilt the level through the baseline.
///
/// Beats are taken from each packet as it is published, never re-read later: reading `rr` after a hop
/// to the main queue could see a newer packet twice, and doubled beats make RMSSD read low (stress high).
@MainActor
final class StressNow: ObservableObject {
    static let shared = StressNow()

    enum Kind: Equatable {
        case live, estimate
        case measured(Date)
        /// A stored 3-minute value from the last 15 minutes.
        case recent(Date)
        /// The newest stored value today, older than that.
        case earlier(Date)
    }

    struct Reading: Equatable {
        /// 0-100.
        let value: Double
        let kind: Kind
        /// Moving: heart rate is up from activity, so it says nothing about stress.
        var active = false

        /// A reading from now rather than from earlier today.
        var isCurrent: Bool {
            switch kind {
            case .live, .estimate, .measured, .recent: return true
            case .earlier: return false
            }
        }
    }

    /// A measurement settles once it has HRV and this much time; it runs to `measureMaxSeconds` otherwise.
    static let measureSeconds: TimeInterval = 60
    static let measureMaxSeconds: TimeInterval = 90

    @Published private(set) var measureEnd: Date?
    @Published private(set) var measured: (value: Double, at: Date)?
    /// Bumped on each beat packet, so views showing live values redraw.
    @Published private(set) var beatTick = 0
    /// This morning's factors as 0-100 (the 0-3 score scaled), for the breakdown.
    @Published private(set) var daily: Double?

    private var beats: [(t: Date, ms: Int)] = []
    private var liveState: (value: Double, withHRV: Bool, active: Bool, at: Date)?
    private var measureStartedAt: Date?
    private weak var model: AppModel?
    private var cancellables: Set<AnyCancellable> = []
    private var endTask: Task<Void, Never>?
    private var ticker: Timer?

    private init() {}

    func attach(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        let live = model.live
        live.$rrSeq
            .removeDuplicates()
            // Synchronously, as the packet is published: `rr` already holds this packet's beats.
            .map { [weak live] _ in live?.rr ?? [] }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] packet in self?.ingest(packet) }
            .store(in: &cancellables)
        // With no beats at all (some straps send heart rate only), heart rate still drives an estimate.
        live.$heartRate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.measureEnd != nil, !self.streaming else { return }
                self.updateLive()
            }
            .store(in: &cancellables)
        // A new 3-minute value every 3 minutes while the app is open.
        StressLevelService.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: TimeInterval(StressLevel.epochSeconds), repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let repo = self.model?.repo else { return }
                await self.refreshStored(repo: repo)
            }
        }
    }

    private func ingest(_ packet: [Int]) {
        let now = Date()
        for ms in packet where ms >= 300 && ms <= 2000 { beats.append((now, ms)) }
        if let f = beats.first, now.timeIntervalSince(f.t) > 240 {
            beats.removeAll { now.timeIntervalSince($0.t) > 240 }
        }
        updateLive()
        beatTick &+= 1
    }

    // MARK: Measuring

    var measuring: Bool { measureEnd.map { $0 > Date() } ?? false }

    /// Live and measuring both read the last three minutes of beats, the length of one stored value.
    var freshBeats: [Int] {
        let from = Date().addingTimeInterval(-TimeInterval(StressLevel.epochSeconds))
        return beats.filter { $0.t >= from }.map(\.ms)
    }

    /// The last beat arrived in the last 15 seconds.
    var streaming: Bool { beats.last.map { Date().timeIntervalSince($0.t) < 15 } ?? false }

    func toggleMeasure() {
        if measureEnd != nil { finish() } else { start() }
    }

    func start() {
        guard let model, measureEnd == nil else { return }
        model.startRealtimeHR()
        let started = Date()
        measureStartedAt = started
        measureEnd = started.addingTimeInterval(Self.measureSeconds)
        updateLive()
        endTask?.cancel()
        endTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.measureSeconds * 1_000_000_000))
            guard let self, !Task.isCancelled, self.measureStartedAt == started else { return }
            if self.liveState?.withHRV == true { self.finish(); return }
            self.measureEnd = started.addingTimeInterval(Self.measureMaxSeconds)
            try? await Task.sleep(nanoseconds: UInt64((Self.measureMaxSeconds - Self.measureSeconds) * 1_000_000_000))
            guard !Task.isCancelled, self.measureStartedAt == started else { return }
            self.finish()
        }
    }

    func finish() {
        guard measureEnd != nil else { return }
        if let l = liveState, !l.active, Date().timeIntervalSince(l.at) < 15 {
            measured = (l.value, Date())
        }
        measureEnd = nil
        measureStartedAt = nil
        endTask?.cancel()
        model?.stopRealtimeHR()
    }

    // MARK: Inputs

    var restingHR: Double? {
        guard let days = model?.repo.days else { return nil }
        let v = days.suffix(14).compactMap(\.restingHr)
        return v.isEmpty ? nil : Double(v.sorted()[v.count / 2])
    }

    /// The baseline live readings are scored against: today's stored one, else a provisional one.
    private var baseline: StressLevel.Baseline {
        StressLevelService.shared.baseline
            ?? .init(calmHR: (restingHR ?? 60) + 8, typicalRMSSD: nil,
                     morning: daily.map { $0 / 100 * 3 }, source: "resting")
    }

    /// Re-score today from what's stored, and the morning factors. Call when data changes.
    func refreshStored(repo: Repository) async {
        let series = await repo.series(key: "stress", source: "my-whoop")
        daily = StressModel(days: repo.days, stored: series).map { min(100, max(0, $0.score / 3 * 100)) }
        await StressLevelService.shared.refresh(repo: repo)
    }

    // MARK: The reading

    /// The reading to show now. See the type's notes for the order.
    func reading() -> Reading? {
        let now = Date()
        if let l = liveState, now.timeIntervalSince(l.at) < (measureEnd != nil ? 60 : 15),
           streaming || measureEnd != nil {
            return Reading(value: l.value, kind: l.withHRV || streaming ? .live : .estimate, active: l.active)
        }
        if let m = measured, now.timeIntervalSince(m.at) < 1800 {
            return Reading(value: m.value, kind: .measured(m.at))
        }
        let service = StressLevelService.shared
        if let s = service.latestState, now.timeIntervalSince1970 - Double(s.start) < 15 * 60,
           s.state == .active || s.state == .afterActivity {
            return Reading(value: 0, kind: .recent(Date(timeIntervalSince1970: TimeInterval(s.start))), active: true)
        }
        if let e = service.latest, let v = e.level {
            let at = Date(timeIntervalSince1970: TimeInterval(e.start + StressLevel.epochSeconds))
            let kind: Kind = now.timeIntervalSince(at) < 15 * 60 ? .recent(at) : .earlier(at)
            return Reading(value: Double(v), kind: kind)
        }
        return nil
    }

    // MARK: Maths

    /// Recompute the live value from the window and smooth it (time constant 15 s, reset after a gap).
    private func updateLive() {
        let now = Date()
        guard let raw = rawLive() else { return }
        var value = raw.value
        if let prev = liveState, now.timeIntervalSince(prev.at) < 30, prev.active == raw.active {
            let alpha = 1 - exp(-now.timeIntervalSince(prev.at) / 15)
            value = prev.value + alpha * (raw.value - prev.value)
        }
        liveState = (value, raw.withHRV, raw.active, now)
        if let started = measureStartedAt, raw.withHRV, now.timeIntervalSince(started) >= Self.measureSeconds {
            finish()
        }
    }

    /// The window scored exactly as a stored 3-minute value is: mean heart rate from the beats (or the
    /// current heart rate), RMSSD when the beats are clean, against today's baseline.
    private func rawLive() -> (value: Double, withHRV: Bool, active: Bool)? {
        let rr = freshBeats
        let beatHR: Double? = rr.count >= 10 ? 60_000 / (Double(rr.reduce(0, +)) / Double(rr.count)) : nil
        guard let hr = beatHR ?? model?.live.heartRate.map(Double.init) else { return nil }
        let b = baseline
        let active = model?.activeWorkout != nil || hr > b.calmHR + StressLevel.exertionOverCalmBPM
        let rmssd = StressLevel.cleanRMSSD(rr)
        return (Double(StressLevel.level(meanHR: hr, rmssd: rmssd, baseline: b)), rmssd != nil, active)
    }

    /// The level's band: Rest, Low, Medium, High (Garmin's 25 / 50 / 75 cuts).
    static func band(_ v: Double) -> StressLevel.Band { StressLevel.Band(level: Int(v.rounded())) }

    static func color(_ v: Double) -> Color { band(v).color }

    /// "Live", "Measured 11:58", "Now", "2:41 PM".
    static func label(_ k: Kind) -> String {
        switch k {
        case .live: return String(localized: "Live")
        case .estimate: return String(localized: "From heart rate")
        case .measured(let at): return String(localized: "Measured \(at.formatted(date: .omitted, time: .shortened))")
        case .recent: return String(localized: "Now")
        case .earlier(let at): return String(localized: "At \(at.formatted(date: .omitted, time: .shortened))")
        }
    }
}

extension StressLevel.Band {
    var title: String {
        switch self {
        case .rest: return String(localized: "REST")
        case .low: return String(localized: "LOW")
        case .medium: return String(localized: "MEDIUM")
        case .high: return String(localized: "HIGH")
        }
    }

    /// Garmin's colours: blue at rest, then oranges that deepen with stress.
    var color: Color {
        switch self {
        case .rest: return StrandPalette.effortColor
        case .low: return StrandPalette.metricAmber
        case .medium: return StrandPalette.statusWarning
        case .high: return StrandPalette.metricRose
        }
    }

    /// The level range: "0-25".
    var range: String {
        switch self {
        case .rest: return "0-25"
        case .low: return "26-50"
        case .medium: return "51-75"
        case .high: return "76-100"
        }
    }
}

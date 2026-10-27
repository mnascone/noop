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
///   1. Live: beats or live heart rate in the last 15 s, the last three minutes of them.
///   2. Measured: a one-minute measurement taken in the last 30 minutes.
///   3. Recent: the newest stored 3-minute value, when it's from the last 15 minutes.
///   4. Earlier: the newest stored value today, shown with its time.
/// While you're moving (a workout running, the phone walking, the strap's newest stretch active) the
/// reading is marked active and carries your last measured value, so nothing reads as stress from effort.
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
        /// Moving: heart rate is up from activity, so it says nothing about stress. `value` is then the
        /// last measured level, when there is one (`hasValue`).
        var active = false
        var hasValue = true

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
    /// Live heart rate as published, for the current reading when no beats arrive.
    private var hrBuf: [(t: Date, bpm: Int)] = []
    private var liveState: (value: Double, withHRV: Bool, active: Bool, at: Date)?
    private var measureStartedAt: Date?
    private weak var model: AppModel?
    private var cancellables: Set<AnyCancellable> = []
    private var endTask: Task<Void, Never>?
    private var ticker: Timer?
    /// When the phone last saw walking, running or cycling, and when that was last asked.
    private var phoneMovingAt: Date?
    private var phoneAskedAt: Date?
    private var lastActiveReason: String?

    private init() {}

    func attach(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        StressLevelService.shared.log = { [weak model] line in model?.live.append(log: AppModel.stamped(line)) }
        let live = model.live
        live.$rrSeq
            .removeDuplicates()
            // Synchronously, as the packet is published: `rr` already holds this packet's beats.
            .map { [weak live] _ in live?.rr ?? [] }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] packet in self?.ingest(packet) }
            .store(in: &cancellables)
        // Live heart rate keeps the reading current between stored values, beats or not.
        live.$heartRate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hr in
                guard let self, let hr, hr > 25 else { return }
                let now = Date()
                self.hrBuf.append((now, hr))
                if let f = self.hrBuf.first, now.timeIntervalSince(f.t) > 240 {
                    self.hrBuf.removeAll { now.timeIntervalSince($0.t) > 240 }
                }
                self.updateLive()
            }
            .store(in: &cancellables)
        // A running workout is activity, not stress, from its start.
        model.$activeWorkout
            .map { $0.map { Int($0.start.timeIntervalSince1970) } }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { start in StressLevelService.shared.activeWorkoutStart = start }
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

    /// Beats or live heart rate arrived in the last 15 seconds.
    var streaming: Bool {
        let now = Date()
        return (beats.last.map { now.timeIntervalSince($0.t) < 15 } ?? false)
            || (hrBuf.last.map { now.timeIntervalSince($0.t) < 15 } ?? false)
    }

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
        let service = StressLevelService.shared
        let last = service.latest?.level.map(Double.init)
        if let l = liveState, now.timeIntervalSince(l.at) < (measureEnd != nil ? 60 : 20),
           streaming || measureEnd != nil {
            if l.active { return Reading(value: last ?? 0, kind: .live, active: true, hasValue: last != nil) }
            return Reading(value: l.value, kind: .live)
        }
        if let m = measured, now.timeIntervalSince(m.at) < 1800 {
            return Reading(value: m.value, kind: .measured(m.at))
        }
        // The strap's newest stretch was movement, in the last 10 minutes. Coming down after it isn't
        // shown as activity: the last measured value stands.
        if let s = service.latestState, s.state == .active, now.timeIntervalSince1970 - Double(s.start) < 600 {
            let hr = s.meanHR.map { String(Int($0)) } ?? "?"
            note(active: "stored 3-min stretch at \(Self.clock(s.start)), HR \(hr)")
            return Reading(value: last ?? 0, kind: .recent(Date(timeIntervalSince1970: TimeInterval(s.start))),
                           active: true, hasValue: last != nil)
        }
        if !streaming { note(active: nil) }
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
        let from = Date().addingTimeInterval(-TimeInterval(StressLevel.epochSeconds))
        let window = hrBuf.filter { $0.t >= from }.map(\.bpm)
        let bufHR: Double? = window.isEmpty ? nil : Double(window.reduce(0, +)) / Double(window.count)
        guard let hr = beatHR ?? bufHR ?? model?.live.heartRate.map(Double.init) else { return nil }
        let b = baseline
        // Moving: a workout running, the phone walking in the last 2 minutes, or the strap's newest stored
        // stretch (in the last 10 minutes) was movement and heart rate is still up. Heart rate alone isn't
        // movement: high while still is stress.
        askPhone()
        let now = Date()
        let strapMoved = StressLevelService.shared.latestState.map {
            $0.state == .active && now.timeIntervalSince1970 - Double($0.start) < 600
        } ?? false
        let phoneMoving = phoneMovingAt.map { now.timeIntervalSince($0) < 120 } ?? false
        let reason: String? = model?.activeWorkout != nil ? "workout running"
            : phoneMoving ? "phone saw walking, running or cycling"
            : strapMoved && hr > b.calmHR + StressLevel.afterActivityBPM ? "strap moved, HR \(Int(hr)) still up"
            : nil
        let active = reason != nil
        note(active: reason.map { "live: \($0)" })
        let rmssd = StressLevel.cleanRMSSD(rr)
        return (Double(StressLevel.level(meanHR: hr, rmssd: rmssd, baseline: b)), rmssd != nil, active)
    }

    /// Ask the phone's motion history, at most once a minute, whether you were moving in the last 3 minutes.
    private func askPhone() {
        let now = Date()
        if let a = phoneAskedAt, now.timeIntervalSince(a) < 60 { return }
        phoneAskedAt = now
        let to = Int(now.timeIntervalSince1970)
        Task { @MainActor [weak self] in
            let ranges = await StressLevelService.phoneActivity(from: to - 180, to: to)
            if let end = ranges.map(\.upperBound).max() {
                self?.phoneMovingAt = Date(timeIntervalSince1970: TimeInterval(end))
            }
        }
    }

    /// Log why the reading is active, once each time the reason changes.
    private func note(active reason: String?) {
        guard reason != lastActiveReason else { return }
        lastActiveReason = reason
        guard let reason, let live = model?.live else { return }
        // Not during a view update: the log is published.
        let line = AppModel.stamped("stress: active, \(reason)")
        Task { @MainActor in live.append(log: line) }
    }

    private static func clock(_ ts: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts)).formatted(date: .omitted, time: .shortened)
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

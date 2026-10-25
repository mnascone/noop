import Foundation
import Combine
import SwiftUI
import StrandAnalytics
import WhoopStore

/// The one place stress "right now" comes from, shared by the Today dial, the Stress screen and the Lock
/// Screen, so they can't disagree. Every reading carries its kind and its time, and only a reading from
/// beats arriving now is ever called live.
///
/// Live readings are scored on the SAME curve as the Stress screen's hours: mean heart rate and RMSSD
/// from the beats in the window, against the reference today's hours were scored with
/// (`DaytimeStress.score`). A minute or two is far noisier than an hour, so the reference's spreads are
/// floored (`minHRSD`, `minRMSSDShare`) and the window's deviation counts half (`windowShrink`) before
/// scoring, the result is smoothed over about 15 s, and
/// heart rate `activeOverCalmBPM` above your calm level reads Active (moving), not stress. Before today
/// has a scored hour, live falls back to RMSSD against an awake share of your nightly HRV.
///
/// Beats are taken from each packet as it is published, never re-read later: reading `rr` after a hop
/// to the main queue could see a newer packet twice, and doubled beats make RMSSD read low (stress high).
///
/// In order, the first that exists wins:
///   1. Live: beats arriving in the last 15 s, with enough of them for HRV.
///   2. Estimate: measuring, before there are enough beats for HRV: heart rate alone.
///   3. Measured: the result of a measurement in the last 30 minutes.
///   4. This morning's score: from last night's resting heart rate and HRV (the Stress screen's daily card).
/// Today's hourly timeline is NOT a "right now" reading: an hour scored against the day's calmest hours
/// reads High for an ordinary busy hour (a meal, errands), and shown as "now" it looked random. It stays
/// on the Stress screen as the day's timeline.
/// All are on the Stress screen's 0-100 scale (its 0-3 score times 33.3) and its Low / Medium / High bands,
/// coloured as its band pills are: green, amber, red.
@MainActor
final class StressNow: ObservableObject {
    static let shared = StressNow()

    enum Kind: Equatable {
        case live, estimate
        case measured(Date)
        case today
    }

    struct Reading: Equatable {
        /// 0-100.
        let value: Double
        let kind: Kind
        /// Heart rate is up from moving, where HRV says nothing about stress.
        var active = false
    }

    /// A measurement settles once it has HRV and this much time; it runs to `measureMaxSeconds` otherwise.
    static let measureSeconds: TimeInterval = 30
    static let measureMaxSeconds: TimeInterval = 60
    /// Awake, still RMSSD as a share of the nightly average: the calm reference for the fallback.
    static let awakeShare = 0.65
    /// Floors on the reference spreads for a short window (an hour's spread is far tighter).
    static let minHRSD = 6.0
    static let minRMSSDShare = 0.3
    /// A short window's deviation counts 1/this of an hour's. On a typical day 4 bpm up with RMSSD 5 ms down stays Medium,
    /// 10 bpm up with RMSSD 15 ms down reads High.
    static let windowShrink = 2.0
    /// Heart rate this far over your calm level is movement, not stress.
    static let activeOverCalmBPM = 20.0

    @Published private(set) var measureEnd: Date?
    @Published private(set) var measured: (value: Double, at: Date)?
    /// Bumped on each beat packet, so views showing live values redraw.
    @Published private(set) var beatTick = 0
    @Published private(set) var daily: Double?
    /// What today's hours were scored against, for scoring the live window on the same curve.
    private(set) var reference: DaytimeStress.Reference?

    private var beats: [(t: Date, ms: Int)] = []
    /// The smoothed live value, updated on each packet.
    private var liveState: (value: Double, withHRV: Bool, active: Bool, at: Date)?
    private var measureStartedAt: Date?
    private weak var model: AppModel?
    private var cancellables: Set<AnyCancellable> = []
    private var endTask: Task<Void, Never>?

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
    }

    private func ingest(_ packet: [Int]) {
        let now = Date()
        for ms in packet where ms >= 300 && ms <= 2000 { beats.append((now, ms)) }
        if let f = beats.first, now.timeIntervalSince(f.t) > 150 {
            beats.removeAll { now.timeIntervalSince($0.t) > 150 }
        }
        updateLive()
        beatTick &+= 1
    }

    // MARK: Measuring

    var measuring: Bool { measureEnd.map { $0 > Date() } ?? false }

    /// Live: the last two minutes. Measuring: the last minute (beats from just before the tap count, so
    /// a strap already streaming gives a number at once).
    private var window: TimeInterval { measureEnd != nil ? 60 : 120 }

    var freshBeats: [Int] {
        let from = Date().addingTimeInterval(-window)
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
            // No HRV yet (the stream was slow to start): give it up to the full minute.
            self.measureEnd = started.addingTimeInterval(Self.measureMaxSeconds)
            try? await Task.sleep(nanoseconds: UInt64((Self.measureMaxSeconds - Self.measureSeconds) * 1_000_000_000))
            guard !Task.isCancelled, self.measureStartedAt == started else { return }
            self.finish()
        }
    }

    func finish() {
        guard measureEnd != nil else { return }
        if let l = liveState, l.withHRV, !l.active, Date().timeIntervalSince(l.at) < 15 {
            measured = (l.value, Date())
        }
        measureEnd = nil
        measureStartedAt = nil
        endTask?.cancel()
        model?.stopRealtimeHR()
    }

    // MARK: Inputs

    var hrvBaseline: Double? {
        guard let days = model?.repo.days else { return nil }
        let v = days.suffix(30).compactMap(\.avgHrv).filter { $0 > 0 }
        return v.count >= 3 ? v.sorted()[v.count / 2] : nil
    }

    var restingHR: Double? {
        guard let days = model?.repo.days else { return nil }
        let v = days.suffix(14).compactMap(\.restingHr)
        return v.isEmpty ? nil : Double(v.sorted()[v.count / 2])
    }

    /// Re-read the stored readings: today's daytime curve and the daily score. Call when data changes.
    func refreshStored(repo: Repository) async {
        // The same lens the Stress screen scores its hours with, so live sits on its curve.
        let day = await StressDayCurve.today(repo: repo,
                                             personalBaseline: PuffinExperiment.stressPersonalBaselineEnabled)
        reference = day?.result.reference
        let series = await repo.series(key: "stress", source: "my-whoop")
        daily = StressModel(days: repo.days, stored: series).map { min(100, max(0, $0.score / 3 * 100)) }
    }

    // MARK: The reading

    /// The reading to show now. See the type's notes for the order.
    func reading() -> Reading? {
        let now = Date()
        // Heart rate alone only republishes when it changes, so while measuring an estimate stays up longer.
        if let l = liveState, now.timeIntervalSince(l.at) < (measureEnd != nil ? 60 : 15),
           streaming || measureEnd != nil {
            if l.withHRV { return Reading(value: l.value, kind: .live, active: l.active) }
            if measureEnd != nil { return Reading(value: l.value, kind: .estimate, active: l.active) }
        }
        if let m = measured, now.timeIntervalSince(m.at) < 1800 {
            return Reading(value: m.value, kind: .measured(m.at))
        }
        if let d = daily { return Reading(value: d, kind: .today) }
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
        // Settled early: HRV for the minimum time, then stop measuring.
        if let started = measureStartedAt, raw.withHRV, now.timeIntervalSince(started) >= Self.measureSeconds {
            finish()
        }
    }

    /// The window's reading before smoothing. Heart rate comes from the beats when there are enough
    /// (the published heart rate only changes on change, so it can't be averaged), else the current one.
    private func rawLive() -> (value: Double, withHRV: Bool, active: Bool)? {
        let rr = freshBeats
        let beatHR: Double? = rr.count >= 10 ? 60_000 / (Double(rr.reduce(0, +)) / Double(rr.count)) : nil
        guard let hr = beatHR ?? model?.live.heartRate.map(Double.init) else { return nil }
        let recent = Array(rr.suffix(30))
        let recentHR = recent.count >= 10 ? 60_000 / (Double(recent.reduce(0, +)) / Double(recent.count)) : hr
        let calm = reference?.heartRate ?? restingHR.map { $0 + 10 }
        let active = calm.map { recentHR > $0 + Self.activeOverCalmBPM } ?? false
        let rmssd = rr.count >= HRVAnalyzer.minBeats ? HRVAnalyzer.analyze(rawRR: rr.map(Double.init)).rmssd : nil
        if let ref = reference, ref.heartRate != nil {
            // Floored spreads, then doubled: a minute or two is weaker evidence than an hour, so its
            // deviation counts half (shrunk toward your calm level) before it reaches the same curve.
            let floored = DaytimeStress.Reference(
                heartRate: ref.heartRate,
                heartRateSD: Self.windowShrink * max(ref.heartRateSD, Self.minHRSD),
                rmssd: ref.rmssd,
                rmssdSD: Self.windowShrink * max(ref.rmssdSD, Self.minRMSSDShare * (ref.rmssd ?? 0)))
            guard let s = DaytimeStress.score(meanHR: hr, rmssd: rmssd, against: floored) else { return nil }
            return (min(100, max(0, s / 3 * 100)), rmssd != nil, active)
        }
        if let b = hrvBaseline, let v = Self.level(rr: rr, hrvBaseline: b, minBeats: HRVAnalyzer.minBeats) {
            return (v, true, active)
        }
        guard let r = restingHR else { return nil }
        return (Self.heartRateEstimate(hr: hr, restingHR: r), false, active)
    }

    /// Stress, 0-100, from the most recent beats (up to the last 120): RMSSD against an awake reference
    /// (`awakeShare` of the nightly average). At the reference it reads about 12; at 40% of the nightly
    /// value about 60.
    static func level(rr: [Int], hrvBaseline: Double, minBeats: Int = 20) -> Double? {
        let clean = Array(rr.suffix(120).filter { $0 >= 300 && $0 <= 2000 })
        guard clean.count >= minBeats else { return nil }
        var diffs: [Double] = []
        for i in 1..<clean.count {
            let d = Double(clean[i] - clean[i - 1])
            if abs(d) < 200 { diffs.append(d * d) }
        }
        guard diffs.count >= max(8, minBeats - 5) else { return nil }
        let rmssd = sqrt(diffs.reduce(0, +) / Double(diffs.count))
        let ratio = rmssd / max(hrvBaseline * awakeShare, 1)
        return min(100, max(0, (1.1 - ratio) / 0.8 * 100))
    }

    /// A first read from heart rate alone while beats arrive: about 20 at resting, ~1.8 per bpm above.
    static func heartRateEstimate(hr: Double, restingHR: Double) -> Double {
        min(100, max(0, 20 + (hr - restingHR) * 1.8))
    }

    /// The Stress screen's bands and colours, on its 0-3 scale: Low under 1, Medium under 2, High above.
    static func band(_ v: Double) -> StressBand { StressBand(score: v / 100 * 3) }

    /// The band's own colour, as on the Stress screen's pills: green Low, amber Medium, red High.
    static func color(_ v: Double) -> Color { band(v).tone.color }

    /// "Live", "Measured 11:58", "This morning's score".
    static func label(_ k: Kind) -> String {
        switch k {
        case .live: return String(localized: "Live")
        case .estimate: return String(localized: "From heart rate")
        case .measured(let at): return String(localized: "Measured \(at.formatted(date: .omitted, time: .shortened))")
        case .today: return String(localized: "This morning's score")
        }
    }
}

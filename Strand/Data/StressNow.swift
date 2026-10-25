import Foundation
import Combine
import SwiftUI
import StrandAnalytics
import WhoopStore

/// The one place stress "right now" comes from, shared by the Today dial, the Stress screen and the Lock
/// Screen, so they can't disagree. Every reading carries its kind and its time, and only a reading from
/// beats arriving now is ever called live.
///
/// Live readings are scored on the SAME curve as the Stress screen's hours: the last two minutes' mean
/// heart rate and RMSSD against the reference today's hours were scored with (`DaytimeStress.score`),
/// so the ring and the timeline can't tell different stories. Before today has a scored hour to give a
/// reference, live falls back to RMSSD against an awake share of your nightly HRV.
///
/// In order, the first that exists wins:
///   1. Live: a measurement in progress, or beats streaming in the last 15 s.
///   2. Estimate: a measurement just started, before there are enough beats for HRV: heart rate alone.
///   3. Measured: the result of a measurement in the last 30 minutes.
///   4. This hour: today's daytime stress curve, when its latest scored hour ended under 2 hours ago.
///   5. Today: the daily score from last night's resting heart rate and HRV against your baseline (the
///      Stress screen's main number).
/// All are on the Stress screen's 0-100 scale (its 0-3 score times 33.3) and its Low / Medium / High bands.
@MainActor
final class StressNow: ObservableObject {
    static let shared = StressNow()

    enum Kind: Equatable {
        case live, estimate
        case measured(Date)
        case hour(Date)
        case today
    }

    struct Reading: Equatable {
        /// 0-100.
        let value: Double
        let kind: Kind
        /// Heart rate is up from moving, where HRV says nothing about stress.
        var active = false
    }

    static let measureSeconds: TimeInterval = 60
    /// Awake, still RMSSD as a share of the nightly average: the calm reference for live stress.
    static let awakeShare = 0.65

    @Published private(set) var measureEnd: Date?
    @Published private(set) var measured: (value: Double, at: Date)?
    /// Bumped on each beat packet, so views showing live values redraw.
    @Published private(set) var beatTick = 0
    @Published private(set) var hourly: (value: Double, end: Date)?
    @Published private(set) var daily: Double?
    /// What today's hours were scored against, for scoring the live window on the same curve.
    private(set) var reference: DaytimeStress.Reference?

    private var beats: [(t: Date, ms: Int)] = []
    private var heartRates: [(t: Date, bpm: Int)] = []
    private weak var model: AppModel?
    private var cancellables: Set<AnyCancellable> = []
    private var endTask: Task<Void, Never>?

    private init() {}

    func attach(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        model.live.$rrSeq
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak model] _ in
                guard let self, let model else { return }
                let now = Date()
                for ms in model.live.rr where ms >= 300 && ms <= 2000 { self.beats.append((now, ms)) }
                if let f = self.beats.first, now.timeIntervalSince(f.t) > 150 {
                    self.beats.removeAll { now.timeIntervalSince($0.t) > 150 }
                }
                self.beatTick &+= 1
            }
            .store(in: &cancellables)
        model.live.$heartRate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bpm in
                guard let self, let bpm, bpm >= 30, bpm <= 230 else { return }
                let now = Date()
                self.heartRates.append((now, bpm))
                if let f = self.heartRates.first, now.timeIntervalSince(f.t) > 150 {
                    self.heartRates.removeAll { now.timeIntervalSince($0.t) > 150 }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: Measuring

    var measuring: Bool { measureEnd.map { $0 > Date() } ?? false }

    private var measureStartedAt: Date? { measureEnd.map { $0.addingTimeInterval(-Self.measureSeconds) } }

    /// Beats from the last two minutes, or since the tap while measuring.
    var freshBeats: [Int] {
        let from = max(Date().addingTimeInterval(-120), measureStartedAt ?? .distantPast)
        return beats.filter { $0.t >= from }.map(\.ms)
    }

    /// Mean heart rate over the same window as `freshBeats`, from at least 10 readings.
    var freshMeanHR: Double? {
        let from = max(Date().addingTimeInterval(-120), measureStartedAt ?? .distantPast)
        let v = heartRates.filter { $0.t >= from }.map(\.bpm)
        return v.count >= 10 ? Double(v.reduce(0, +)) / Double(v.count) : nil
    }

    /// The last beat arrived in the last 15 seconds.
    var streaming: Bool { beats.last.map { Date().timeIntervalSince($0.t) < 15 } ?? false }

    func toggleMeasure() {
        if measureEnd != nil { finish() } else { start() }
    }

    func start() {
        guard let model, measureEnd == nil else { return }
        beats = []
        heartRates = []
        model.startRealtimeHR()
        let end = Date().addingTimeInterval(Self.measureSeconds)
        measureEnd = end
        endTask?.cancel()
        endTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.measureSeconds * 1_000_000_000))
            guard !Task.isCancelled, self?.measureEnd == end else { return }
            self?.finish()
        }
    }

    func finish() {
        guard measureEnd != nil else { return }
        if let v = liveValue(minBeats: 12), v.withHRV {
            measured = (v.value, Date())
        }
        measureEnd = nil
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
        // The same lens the Stress screen scores its hours with, so the latest hour matches its timeline.
        let day = await StressDayCurve.today(repo: repo,
                                             personalBaseline: PuffinExperiment.stressPersonalBaselineEnabled)
        reference = day?.result.reference
        if let h = day?.result.hours.last(where: { $0.level != nil }), let l = h.level {
            hourly = (min(100, max(0, l / 3 * 100)), Date(timeIntervalSince1970: TimeInterval(h.startTs + 3600)))
        } else {
            hourly = nil
        }
        let series = await repo.series(key: "stress", source: "my-whoop")
        daily = StressModel(days: repo.days, stored: series).map { min(100, max(0, $0.score / 3 * 100)) }
    }

    // MARK: The reading

    /// The reading to show now. See the type's notes for the order.
    func reading() -> Reading? {
        let hr = model?.live.heartRate.map(Double.init)
        let fresh = streaming || measureEnd != nil
        let active = fresh && (hr.map { h in restingHR.map { h > $0 + 35 } ?? (h > 110) } ?? false)
        if fresh, let v = liveValue(minBeats: measureEnd != nil ? 12 : 20) {
            if v.withHRV { return Reading(value: v.value, kind: .live, active: active) }
            if measureEnd != nil { return Reading(value: v.value, kind: .estimate, active: active) }
        }
        if measureEnd != nil, reference == nil, let h = hr, let r = restingHR {
            return Reading(value: Self.heartRateEstimate(hr: h, restingHR: r), kind: .estimate, active: active)
        }
        if let m = measured, Date().timeIntervalSince(m.at) < 1800 {
            return Reading(value: m.value, kind: .measured(m.at))
        }
        if let h = hourly, Date().timeIntervalSince(h.end) < 2 * 3600 {
            return Reading(value: h.value, kind: .hour(h.end))
        }
        if let d = daily { return Reading(value: d, kind: .today) }
        return nil
    }

    // MARK: Maths

    /// Stress (0-100) from the live window. On today's curve when there's a reference: mean heart rate
    /// and, with enough clean beats, RMSSD (`withHRV`). Without a reference, RMSSD against the awake
    /// share of your nightly HRV.
    private func liveValue(minBeats: Int) -> (value: Double, withHRV: Bool)? {
        let rr = freshBeats
        if let ref = reference, ref.heartRate != nil {
            let rmssd = rr.count >= minBeats ? HRVAnalyzer.analyze(rawRR: rr.map(Double.init)).rmssd : nil
            guard let s = DaytimeStress.score(meanHR: freshMeanHR, rmssd: rmssd, against: ref) else { return nil }
            return (min(100, max(0, s / 3 * 100)), rmssd != nil)
        }
        guard let b = hrvBaseline, let v = Self.level(rr: rr, hrvBaseline: b, minBeats: minBeats) else { return nil }
        return (v, true)
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

    static func color(_ v: Double) -> Color { StressRamp.color(v / 100 * 3) }

    /// "Live", "Measured 11:58", "This hour", "This morning's score".
    static func label(_ k: Kind) -> String {
        switch k {
        case .live: return String(localized: "Live")
        case .estimate: return String(localized: "From heart rate")
        case .measured(let at): return String(localized: "Measured \(at.formatted(date: .omitted, time: .shortened))")
        case .hour(let end):
            return Date().timeIntervalSince(end) < 0
                ? String(localized: "This hour")
                : String(localized: "Up to \(end.formatted(date: .omitted, time: .shortened))")
        case .today: return String(localized: "This morning's score")
        }
    }
}

import SwiftUI
import StrandDesign
import WhoopStore

/// How Effort is keeping pace with Charge, each compared with your own recent normal.
///
/// Short term: the last 3 days against the 11 before. Long term: the last 7 days against the 4 weeks
/// before. The overall read leans on the long term once there's enough history for it (70/30), and uses
/// the short term alone until then.
enum PacingMath {
    struct Pacing: Equatable {
        var chargeRecent: Double
        var chargeUsual: Double
        var effortRecent: Double
        var effortUsual: Double
        /// Stress (0-3 scale) recent minus usual, when stress is known.
        var stressDelta: Double?
        /// -1 = Charge far ahead, 0 = in step, +1 = Effort far ahead.
        var balance: Double
    }

    enum State { case recovering, balanced, overreaching }

    static let band = 0.25

    static func state(_ balance: Double) -> State {
        balance <= -band ? .recovering : (balance >= band ? .overreaching : .balanced)
    }

    struct Window {
        let recentDays: Int
        let usualDays: Int
        let minRecent: Int
        let minUsual: Int
        static let short = Window(recentDays: 3, usualDays: 11, minRecent: 2, minUsual: 5)
        static let long = Window(recentDays: 7, usualDays: 28, minRecent: 4, minUsual: 10)
    }

    /// The change in Effort beyond the change in Charge (log ratios), so a 20% rise in Effort with Charge
    /// flat reads the same as Effort flat with Charge down 20%. ±0.35 fills the dial.
    static func pacing(days: [DailyMetric], todayKey: String, window w: Window,
                       stressByDay: [String: Double] = [:]) -> Pacing? {
        let span = w.recentDays - 1 + w.usualDays
        let past = RestDayRules.pastDayKeys(count: span, todayKey: todayKey)
        guard past.count == span else { return nil }
        let recentKeys = Set([todayKey] + past.prefix(w.recentDays - 1))
        let usualKeys = Set(past.dropFirst(w.recentDays - 1))
        var cR: [Double] = [], cU: [Double] = [], eR: [Double] = [], eU: [Double] = []
        var sR: [Double] = [], sU: [Double] = []
        for d in days {
            if recentKeys.contains(d.day) {
                if let c = d.recovery { cR.append(c) }
                if let e = d.strain { eR.append(e) }
                if let st = stressByDay[d.day] { sR.append(st) }
            } else if usualKeys.contains(d.day) {
                if let c = d.recovery { cU.append(c) }
                if let e = d.strain { eU.append(e) }
                if let st = stressByDay[d.day] { sU.append(st) }
            }
        }
        guard cR.count >= w.minRecent, eR.count >= w.minRecent, cU.count >= w.minUsual, eU.count >= w.minUsual
        else { return nil }
        func mean(_ a: [Double]) -> Double { a.reduce(0, +) / Double(a.count) }
        let p = (mean(cR), mean(cU), mean(eR), mean(eU))
        guard p.0 > 0, p.1 > 0 else { return nil }
        // +5 keeps a near-zero Effort stretch from swinging the ratio wildly.
        var s = log((p.2 + 5) / (p.3 + 5)) - log(p.0 / p.1)
        // Stress (0-3) above your usual adds load the way extra Effort does: one point counts like ~15%
        // more Effort.
        var stressDelta: Double?
        if !sR.isEmpty, sU.count >= max(3, w.minUsual / 2) {
            let d = mean(sR) - mean(sU)
            stressDelta = d
            s += 0.15 * d
        }
        return Pacing(chargeRecent: p.0, chargeUsual: p.1, effortRecent: p.2, effortUsual: p.3,
                      stressDelta: stressDelta, balance: min(1, max(-1, s / 0.35)))
    }

    /// Long term weighted 70/30 over short term when it exists, else the short term alone.
    static func overall(short: Pacing?, long: Pacing?) -> Double? {
        if let long { return 0.7 * long.balance + 0.3 * (short?.balance ?? long.balance) }
        return short?.balance
    }
}

/// Pace and stress side by side: how Effort is keeping up with Charge and stress (long term weighted
/// more once there's enough history, short term until then), and a live stress reading from heart-rate
/// variability, like a Garmin stress gauge. Today and Performance show the same card.
struct PacingDialCard: View {
    enum Mode { case short, both }

    let days: [DailyMetric]
    let effortScale: EffortScale
    var mode: Mode = .both
    /// Tapping the pace side (not the stress gauge, which starts a live measurement) calls this.
    var onOpen: (() -> Void)? = nil

    /// Daily stress (0-3) from resting HR and HRV against your own baseline, plus any imported values.
    private var stressByDay: [String: Double] {
        guard let m = StressModel(days: days, stored: []) else { return [:] }
        return Dictionary(m.fullTrend.map { (Self.utcDay.string(from: $0.date), $0.value) },
                          uniquingKeysWith: { _, last in last })
    }

    private static let utcDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Your usual overnight HRV, the live stress gauge's reference.
    private var hrvBaseline: Double? {
        let v = days.suffix(30).compactMap(\.avgHrv).filter { $0 > 0 }
        return v.count >= 3 ? v.sorted()[v.count / 2] : nil
    }

    private var restingHR: Double? {
        let v = days.suffix(14).compactMap(\.restingHr)
        return v.isEmpty ? nil : Double(v.sorted()[v.count / 2])
    }

    var body: some View {
        let today = Repository.localDayKey(Date())
        let stress = stressByDay
        let short = PacingMath.pacing(days: days, todayKey: today, window: .short, stressByDay: stress)
        let long = PacingMath.pacing(days: days, todayKey: today, window: .long, stressByDay: stress)
        let overall = PacingMath.overall(short: short, long: long)
        let shown = long ?? short
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(alignment: .top, spacing: NoopMetrics.space3) {
                    gaugeColumn(title: String(localized: "Pace"),
                                sub: long == nil ? String(localized: "3 days") : String(localized: "7 vs 28 days")) {
                        PacingDial(balance: overall ?? 0, compact: true, showsLabels: false)
                            .opacity(overall == nil ? 0.3 : 1)
                    } chip: {
                        if let overall { chip(Self.stateWord(overall), Self.stateColor(overall)) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen?() }
                    Divider().frame(height: 70).overlay(StrandPalette.hairline.opacity(0.5))
                    LiveStressGauge(hrvBaseline: hrvBaseline, restingHR: restingHR)
                }
                if let overall {
                    Text(Self.compactLine(overall))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let p = shown {
                    Text(Self.detail(p, effortScale: effortScale))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Pace needs about 2 weeks of Charge and Effort.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func gaugeColumn<G: View, C: View>(title: String, sub: String, @ViewBuilder gauge: () -> G,
                                               @ViewBuilder chip: () -> C) -> some View {
        VStack(spacing: 4) {
            gauge().frame(width: 96, height: 54)
            HStack(spacing: 4) {
                Text(title).font(StrandFont.subhead.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                chip()
            }
            Text(sub).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(StrandFont.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
            .lineLimit(1)
    }

    static func detail(_ p: PacingMath.Pacing, effortScale: EffortScale) -> String {
        var parts = [
            String(localized: "Effort \(UnitFormatter.effortDisplay(p.effortRecent, scale: effortScale)) vs \(UnitFormatter.effortDisplay(p.effortUsual, scale: effortScale))"),
            String(localized: "Charge \(Int(p.chargeRecent.rounded())) vs \(Int(p.chargeUsual.rounded()))"),
        ]
        if let d = p.stressDelta, abs(d) >= 0.2 {
            parts.append(d > 0 ? String(localized: "stress up") : String(localized: "stress down"))
        }
        return parts.joined(separator: " · ")
    }

    static func stateWord(_ balance: Double) -> String {
        switch PacingMath.state(balance) {
        case .recovering: return String(localized: "Under")
        case .balanced: return String(localized: "On pace")
        case .overreaching: return String(localized: "Too hard")
        }
    }

    /// Green at the easy end, red at the hard end, on the same ramp as the dial.
    static func stateColor(_ balance: Double) -> Color {
        StrandPalette.recoveryColor((1 - (balance + 1) / 2) * 100)
    }

    static func compactLine(_ balance: Double) -> String {
        switch PacingMath.state(balance) {
        case .recovering: return String(localized: "You're recovering faster than you're loading. Room to push.")
        case .balanced: return String(localized: "Load matches what your Charge and stress can carry.")
        case .overreaching: return String(localized: "Load is outrunning recovery. Ease off for a day or two.")
        }
    }
}

/// Live stress, 0-100, from the last minute of beat-to-beat intervals against your usual overnight HRV:
/// rest (0-25), low, medium, high (76-100), as Garmin bands it. Updates as heart rate streams; shows
/// "Active" when heart rate is up from moving, where HRV says nothing about stress.
struct LiveStressGauge: View {
    let hrvBaseline: Double?
    let restingHR: Double?
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var model: AppModel
    /// Today's latest scored hour (0-100) from the stored heart rate, shown when nothing is streaming live.
    @State private var stored: (value: Double, at: Date)?
    /// A tap-started live measurement: the strap streams beat-to-beat intervals until `measureEnd`.
    @State private var measureEnd: Date?
    /// The result of the last measurement, shown for half an hour after it ends.
    @State private var measured: (value: Double, at: Date)?
    /// Beats as they arrive, each with its time, so only recent ones are read. The strap-side buffer keeps
    /// old beats until the link drops, which is how an hours-old "live" number used to stay up.
    @State private var beats: [(t: Date, ms: Int)] = []

    /// Beats from the last two minutes (since the tap, while measuring).
    private var freshBeats: [Int] {
        let from = max(Date().addingTimeInterval(-120), measureStartedAt ?? .distantPast)
        return beats.filter { $0.t >= from }.map(\.ms)
    }

    private var measureStartedAt: Date? { measureEnd.map { $0.addingTimeInterval(-Self.measureSeconds) } }

    /// The last beat arrived in the last 15 seconds.
    private var streaming: Bool { beats.last.map { Date().timeIntervalSince($0.t) < 15 } ?? false }

    static let measureSeconds: TimeInterval = 60
    /// Awake, still RMSSD as a share of the nightly average: the calm reference for live stress.
    static let awakeShare = 0.65

    /// The newest scored hour of today's stress curve, rescaled from the shared 0-3 axis to 0-100.
    private func loadStored() async {
        guard let day = await StressDayCurve.today(repo: repo),
              let h = day.result.hours.last(where: { $0.level != nil }), let l = h.level else {
            stored = nil
            return
        }
        stored = (min(100, max(0, l / 3 * 100)), Date(timeIntervalSince1970: TimeInterval(h.startTs)))
    }

    /// Stress from the most recent beats (up to the last 120, about two minutes). `minBeats` is lower
    /// while a tap-started measurement is running, so a first reading comes within about 10 seconds and
    /// then firms up as beats arrive.
    static func level(rr: [Int], hrvBaseline: Double, minBeats: Int = 20) -> Double? {
        let clean = rr.suffix(120).filter { $0 >= 300 && $0 <= 2000 }
        guard clean.count >= minBeats else { return nil }
        var diffs: [Double] = []
        for i in 1..<clean.count {
            let d = Double(clean[clean.startIndex + i] - clean[clean.startIndex + i - 1])
            if abs(d) < 200 { diffs.append(d * d) }
        }
        guard diffs.count >= max(8, minBeats - 5) else { return nil }
        let rmssd = sqrt(diffs.reduce(0, +) / Double(diffs.count))
        // Awake HRV runs well below the overnight value even when calm, so the reference is an awake
        // level: about 65% of your nightly HRV. At that level stress reads about 12 (rest); at 40% of the
        // nightly value it reads about 60 (medium).
        let ratio = rmssd / max(hrvBaseline * Self.awakeShare, 1)
        return min(100, max(0, (1.1 - ratio) / 0.8 * 100))
    }

    private var measuring: Bool { measureEnd.map { $0 > Date() } ?? false }

    /// An instant first read from heart rate alone, while beats for the HRV reading are still arriving:
    /// at resting heart rate about 20 (rest), rising ~1.8 per bpm above it. Rough, and replaced as soon
    /// as there are enough beats.
    static func heartRateEstimate(hr: Double, restingHR: Double) -> Double {
        min(100, max(0, 20 + (hr - restingHR) * 1.8))
    }

    private func toggleMeasure() {
        if measureEnd != nil {
            finishMeasure(keep: true)
        } else {
            // Start clean: only beats from now on count.
            beats = []
            model.startRealtimeHR()
            measureEnd = Date().addingTimeInterval(Self.measureSeconds)
        }
    }

    private func finishMeasure(keep: Bool) {
        guard measureEnd != nil else { return }
        if keep, let b = hrvBaseline, let v = Self.level(rr: freshBeats, hrvBaseline: b, minBeats: 12) {
            measured = (v, Date())
        }
        measureEnd = nil
        model.stopRealtimeHR()
    }

    var body: some View {
        let hr = live.heartRate.map(Double.init)
        let active = (streaming || measureEnd != nil)
            && (hr.map { h in restingHR.map { h > $0 + 35 } ?? (h > 110) } ?? false)
        // Live only from beats that are actually arriving now.
        let liveValue: Double? = streaming ? hrvBaseline.flatMap {
            Self.level(rr: freshBeats, hrvBaseline: $0, minBeats: measureEnd != nil ? 12 : 20)
        } : nil
        // Measuring but no HRV reading yet: heart rate gives a first number at once.
        let hrGuess: Double? = (measureEnd != nil && liveValue == nil)
            ? hr.flatMap { h in restingHR.map { Self.heartRateEstimate(hr: h, restingHR: $0) } } : nil
        let recent = measured.flatMap { Date().timeIntervalSince($0.at) < 1800 ? $0 : nil }
        // Live while measuring (or whenever beats stream), then the last measurement, then the stored hour.
        let value = liveValue ?? hrGuess ?? recent?.value ?? stored?.value
        // Showing a stored hour from more than 90 minutes ago: dim it, so an old number never passes as now.
        let stale = liveValue == nil && hrGuess == nil && recent == nil
            && (stored.map { Date().timeIntervalSince($0.at) > 90 * 60 } ?? false)
        Button(action: toggleMeasure) {
            VStack(spacing: 4) {
                StressArc(value: active ? nil : value.map { $0 / 100 })
                    .frame(width: 96, height: 54)
                    .opacity(stale ? 0.4 : 1)
                    .overlay(alignment: .bottom) {
                        Text(active ? "–" : value.map { "\(Int($0.rounded()))" } ?? "–")
                            .font(StrandFont.number(18))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .offset(y: 2)
                    }
                HStack(spacing: 4) {
                    Text("Stress").font(StrandFont.subhead.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                    Text(active ? String(localized: "Active") : value.map(Self.band) ?? String(localized: "No data yet"))
                        .font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(value.map(Self.color) ?? StrandPalette.textTertiary)
                        .lineLimit(1)
                }
                caption(liveValue: liveValue, estimating: hrGuess != nil, recent: recent, active: active)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(measureEnd != nil ? "Stops the live measurement" : "Measures stress live for a minute"))
        // Re-read when new data lands (a sync), so the stored value moves on without forcing one.
        .task(id: repo.refreshSeq) { await loadStored() }
        // Collect each packet's beats with the time they arrived; keep two and a half minutes.
        .onChangeCompat(of: live.rrSeq) { _ in
            let now = Date()
            for ms in live.rr where ms >= 300 && ms <= 2000 { beats.append((now, ms)) }
            if let f = beats.first, now.timeIntervalSince(f.t) > 150 { beats.removeAll { now.timeIntervalSince($0.t) > 150 } }
        }
        // End the measurement on its own after 90 seconds.
        .task(id: measureEnd) {
            guard let end = measureEnd else { return }
            let wait = max(0, end.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            if !Task.isCancelled, measureEnd == end { finishMeasure(keep: true) }
        }
        .onDisappear { finishMeasure(keep: true) }
    }

    @ViewBuilder
    private func caption(liveValue: Double?, estimating: Bool, recent: (value: Double, at: Date)?,
                         active: Bool) -> some View {
        if let end = measureEnd {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = max(0, Int(end.timeIntervalSince(ctx.date).rounded()))
                Text(liveValue != nil
                     ? String(localized: "Live HRV · refining \(left)s")
                     : estimating
                     ? String(localized: "From heart rate · HRV in a moment")
                     : String(localized: "Waiting for heart rate…"))
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.accent)
                    .monospacedDigit()
            }
        } else if liveValue != nil || active {
            Text("live").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        } else if let r = recent {
            (Text("measured ") + Text(r.at, style: .time) + Text(" · tap to redo"))
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        } else if let at = stored?.at {
            (Text(Date().timeIntervalSince(at) > 90 * 60 ? "last scored " : "as of ") + Text(at, style: .time)
                + Text(" · tap to measure"))
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        } else {
            Text("Tap to measure").font(StrandFont.caption).foregroundStyle(StrandPalette.accent)
        }
    }

    static func band(_ v: Double) -> String {
        switch v {
        case ..<26: return String(localized: "Rest")
        case ..<51: return String(localized: "Low")
        case ..<76: return String(localized: "Medium")
        default: return String(localized: "High")
        }
    }

    static func color(_ v: Double) -> Color { StressArc.color(v / 100) }
}

/// Half-circle stress gauge: blue at rest through amber to red at high stress.
struct StressArc: View {
    /// 0...1, nil = no reading.
    let value: Double?

    static func color(_ t: Double) -> Color {
        let stops: [(Double, (Double, Double, Double))] = [
            (0, (0.25, 0.60, 0.95)), (0.35, (0.55, 0.75, 0.95)), (0.55, (0.98, 0.72, 0.25)), (1, (0.92, 0.30, 0.22)),
        ]
        let x = min(1, max(0, t))
        for i in 1..<stops.count where x <= stops[i].0 {
            let (a, ca) = stops[i - 1], (b, cb) = stops[i]
            let f = (x - a) / max(b - a, 0.0001)
            return Color(red: ca.0 + (cb.0 - ca.0) * f, green: ca.1 + (cb.1 - ca.1) * f, blue: ca.2 + (cb.2 - ca.2) * f)
        }
        return Color(red: 0.92, green: 0.30, blue: 0.22)
    }

    var body: some View {
        Canvas { ctx, size in
            let lineWidth: CGFloat = 9
            let radius = min(size.width / 2, size.height) - lineWidth / 2 - 2
            let center = CGPoint(x: size.width / 2, y: size.height - 4)
            func point(_ a: Double, _ r: CGFloat) -> CGPoint {
                CGPoint(x: center.x + CGFloat(cos(a)) * r, y: center.y + CGFloat(sin(a)) * r)
            }
            let segments = 40
            for i in 0..<segments {
                let a0 = Double.pi + Double.pi * Double(i) / Double(segments)
                let a1 = Double.pi + Double.pi * Double(i + 1) / Double(segments)
                var path = Path()
                path.move(to: point(a0, radius))
                path.addLine(to: point(min(2 * Double.pi, a1 + 0.004), radius))
                let t = Double(i) / Double(segments - 1)
                ctx.stroke(path, with: .color(Self.color(t).opacity(value == nil ? 0.3 : 1)),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            }
            if let v = value {
                let a = Double.pi + Double.pi * min(1, max(0, v))
                let dot = point(a, radius)
                ctx.fill(Path(ellipseIn: CGRect(x: dot.x - 6, y: dot.y - 6, width: 12, height: 12)),
                         with: .color(StrandPalette.textPrimary))
                ctx.fill(Path(ellipseIn: CGRect(x: dot.x - 3.5, y: dot.y - 3.5, width: 7, height: 7)),
                         with: .color(Self.color(v)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A speedometer: half circle from green (left) to red (right) with ticks and a needle at `balance`
/// (-1...1).
struct PacingDial: View {
    let balance: Double
    var leftLabel: LocalizedStringKey = "Recovering"
    var rightLabel: LocalizedStringKey = "Overreaching"
    var compact = false
    var showsLabels = true

    var body: some View {
        Canvas { ctx, size in
            let lineWidth: CGFloat = compact ? 9 : 14
            let radius = min(size.width / 2, size.height) - lineWidth / 2 - 2
            let center = CGPoint(x: size.width / 2, y: size.height - 4)
            let segments = 48
            func point(_ a: Double, _ r: CGFloat) -> CGPoint {
                CGPoint(x: center.x + CGFloat(cos(a)) * r, y: center.y + CGFloat(sin(a)) * r)
            }
            // Angles run from pi (left) over the top to 2 pi (right); y grows downward, so the sine is
            // negative across the top half.
            for i in 0..<segments {
                let a0 = Double.pi + Double.pi * Double(i) / Double(segments)
                let a1 = Double.pi + Double.pi * Double(i + 1) / Double(segments)
                var path = Path()
                path.move(to: point(a0, radius))
                path.addLine(to: point((a0 + a1) / 2, radius))
                path.addLine(to: point(min(2 * Double.pi, a1 + 0.004), radius))
                // Left end = full Charge colour (green), right end = depleted (red).
                let t = 1 - Double(i) / Double(segments - 1)
                ctx.stroke(path, with: .color(StrandPalette.recoveryColor(t * 100)),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            }
            // Speedometer ticks inside the arc, a longer one at the middle.
            let tickCount = compact ? 4 : 10
            for i in 0...tickCount {
                let a = Double.pi + Double.pi * Double(i) / Double(tickCount)
                let isMid = i * 2 == tickCount
                let inner = radius - lineWidth / 2 - (isMid ? (compact ? 6 : 11) : (compact ? 3 : 6))
                var tick = Path()
                tick.move(to: point(a, radius - lineWidth / 2 - 1))
                tick.addLine(to: point(a, inner))
                ctx.stroke(tick, with: .color(StrandPalette.textTertiary), lineWidth: isMid ? 2 : 1)
            }
            let angle = Double.pi + Double.pi * (balance + 1) / 2
            var needle = Path()
            needle.move(to: center)
            needle.addLine(to: point(angle, radius - lineWidth / 2 - 2))
            ctx.stroke(needle, with: .color(StrandPalette.textPrimary),
                       style: StrokeStyle(lineWidth: compact ? 2 : 3, lineCap: .round))
            let hubR: CGFloat = compact ? 4 : 6
            ctx.fill(Path(ellipseIn: CGRect(x: center.x - hubR, y: center.y - hubR, width: hubR * 2, height: hubR * 2)),
                     with: .color(StrandPalette.textPrimary))
        }
        .overlay(alignment: .bottomLeading) {
            if showsLabels {
                Text(leftLabel).font(compact ? .system(size: 9) : StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showsLabels {
                Text(rightLabel).font(compact ? .system(size: 9) : StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .accessibilityLabel(Text("Pacing dial"))
        .accessibilityValue(Text(PacingMath.state(balance) == .recovering ? leftLabel
                                 : PacingMath.state(balance) == .overreaching ? rightLabel : "On pace"))
    }
}

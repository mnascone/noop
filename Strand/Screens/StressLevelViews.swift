import SwiftUI
import StrandDesign
import StrandAnalytics

/// "6h 12m", "45m".
func stressDuration(_ seconds: Int) -> String {
    let m = seconds / 60
    return m >= 60 ? String(localized: "\(m / 60)h \(m % 60)m") : String(localized: "\(m)m")
}

/// A day of the stress level as Garmin draws it: one bar per 3 minutes, as tall as the level and coloured
/// by its band (blue rest, oranges for low, medium, high), activity in grey, sleep shaded, gaps empty.
/// Press and hold, then slide, to read any 3 minutes.
struct StressDayChart: View {
    let day: StressLevelDay
    /// Unix seconds of the day's local midnight.
    let dayStart: Int
    @State private var scrub: Int?

    private var dayEnd: Int { dayStart + 86_400 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                Canvas { ctx, size in draw(&ctx, size) }
                    .contentShape(Rectangle())
                    .gesture(LongPressGesture(minimumDuration: 0.2, maximumDistance: 10)
                        .sequenced(before: DragGesture(minimumDistance: 0))
                        .onChanged { v in
                            guard case .second(true, let drag) = v, let drag else { return }
                            let f = Swift.min(1, Swift.max(0, drag.location.x / Swift.max(1, w - 22)))
                            scrub = dayStart + Int(f * 86_400)
                        }
                        .onEnded { _ in scrub = nil })
                    .overlay(alignment: .topLeading) {
                        if let t = scrub { scrubLabel(t, w: w, h: h) }
                    }
            }
            .frame(height: 150)
            // Midnight to midnight, every six hours, in the device's own clock style.
            HStack {
                ForEach(0..<5, id: \.self) { i in
                    Text(Self.hourLabel(i * 6))
                        .font(.system(size: 9))
                        .foregroundStyle(StrandPalette.textTertiary)
                    if i < 4 { Spacer(minLength: 0) }
                }
            }
            .padding(.trailing, 22)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Stress level through the day"))
        .accessibilityValue(Text(day.summary.average.map { String(localized: "Average \($0)") } ?? String(localized: "No readings")))
    }

    static func hourLabel(_ h: Int) -> String {
        let d = Calendar.current.date(bySettingHour: h % 24, minute: 0, second: 0, of: Date()) ?? Date()
        return d.formatted(.dateTime.hour())
    }

    private func x(_ ts: Int, _ w: CGFloat) -> CGFloat {
        CGFloat(ts - dayStart) / 86_400 * (w - 22)
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height - 2
        let barW = Swift.max(1, (w - 22) * CGFloat(StressLevel.epochSeconds) / 86_400)
        // Sleep, shaded.
        var sleepRun: (Int, Int)?
        func flushSleep() {
            if let r = sleepRun {
                ctx.fill(Path(CGRect(x: x(r.0, w), y: 0, width: x(r.1, w) - x(r.0, w), height: h)),
                         with: .color(StrandPalette.effortColor.opacity(0.07)))
            }
            sleepRun = nil
        }
        for e in day.epochs {
            if e.asleep {
                if let r = sleepRun, r.1 >= e.start { sleepRun = (r.0, e.start + StressLevel.epochSeconds) }
                else { flushSleep(); sleepRun = (e.start, e.start + StressLevel.epochSeconds) }
            }
        }
        flushSleep()
        // Band guides at 25, 50, 75.
        for v in [25, 50, 75] {
            let y = h - CGFloat(v) / 100 * h
            var p = Path()
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: w - 22, y: y))
            ctx.stroke(p, with: .color(StrandPalette.hairline), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
            ctx.draw(Text("\(v)").font(.system(size: 9)).foregroundColor(StrandPalette.textTertiary),
                     at: CGPoint(x: w - 2, y: y), anchor: .trailing)
        }
        // Bars.
        for e in day.epochs {
            let bx = x(e.start, w)
            switch e.state {
            case .measured:
                guard let l = e.level else { continue }
                let bh = Swift.max(2, CGFloat(l) / 100 * h)
                ctx.fill(Path(CGRect(x: bx, y: h - bh, width: barW, height: bh)),
                         with: .color(StressLevel.Band(level: l).color))
            case .active, .afterActivity:
                ctx.fill(Path(CGRect(x: bx, y: h - h * 0.35, width: barW, height: h * 0.35)),
                         with: .color(StrandPalette.textTertiary.opacity(e.state == .active ? 0.45 : 0.25)))
            case .noData:
                continue
            }
        }
        // Now.
        let now = Int(Date().timeIntervalSince1970)
        if now < dayEnd, now > dayStart {
            var p = Path()
            p.move(to: CGPoint(x: x(now, w), y: 0))
            p.addLine(to: CGPoint(x: x(now, w), y: h))
            ctx.stroke(p, with: .color(StrandPalette.textTertiary.opacity(0.6)), lineWidth: 1)
        }
        if let t = scrub {
            var p = Path()
            p.move(to: CGPoint(x: x(t, w), y: 0))
            p.addLine(to: CGPoint(x: x(t, w), y: h))
            ctx.stroke(p, with: .color(StrandPalette.textPrimary), lineWidth: 1)
        }
    }

    private func scrubLabel(_ t: Int, w: CGFloat, h: CGFloat) -> some View {
        let e = day.epochs.last { $0.start <= t && t < $0.start + StressLevel.epochSeconds }
        let time = Date(timeIntervalSince1970: TimeInterval(t)).formatted(date: .omitted, time: .shortened)
        let what: String
        let color: Color
        switch e?.state {
        case .measured?:
            let l = e?.level ?? 0
            what = "\(l) " + StressLevel.Band(level: l).title.capitalized
            color = StressLevel.Band(level: l).color
        case .active?: what = String(localized: "Active"); color = StrandPalette.textSecondary
        case .afterActivity?: what = String(localized: "After activity"); color = StrandPalette.textSecondary
        default: what = String(localized: "No reading"); color = StrandPalette.textTertiary
        }
        let px = Swift.min(w - 130, Swift.max(0, x(t, w) - 55))
        return VStack(alignment: .leading, spacing: 1) {
            Text(what).font(StrandFont.subhead.weight(.bold)).foregroundStyle(color)
            Text(time + ((e?.asleep ?? false) ? " · " + String(localized: "asleep") : ""))
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(StrandPalette.surfaceOverlay))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(StrandPalette.hairline, lineWidth: 1))
        .offset(x: px, y: 0)
        .allowsHitTesting(false)
    }
}

/// The day's numbers: average (awake and overall), the highest stretch, and time in each band, moving
/// and unmeasured, as one stacked bar and a legend.
struct StressDaySummary: View {
    let day: StressLevelDay

    var body: some View {
        let s = day.summary
        let bands = StressLevel.Band.allCases
        let measuredSeconds = bands.map { s.seconds[$0] ?? 0 }.reduce(0, +)
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space4) {
                stat(String(localized: "Average"), s.average.map(String.init) ?? "–", s.average.map { StressLevel.Band(level: $0).color })
                stat(String(localized: "Awake"), s.awakeAverage.map(String.init) ?? "–", s.awakeAverage.map { StressLevel.Band(level: $0).color })
                if let hi = s.highest, let l = hi.level {
                    stat(String(localized: "Highest"), "\(l)", StressLevel.Band(level: l).color,
                         sub: Date(timeIntervalSince1970: TimeInterval(hi.start)).formatted(date: .omitted, time: .shortened))
                }
                Spacer(minLength: 0)
            }
            if measuredSeconds > 0 {
                GeometryReader { g in
                    HStack(spacing: 2) {
                        ForEach(bands, id: \.self) { b in
                            let sec = s.seconds[b] ?? 0
                            if sec > 0 {
                                Rectangle().fill(b.color)
                                    .frame(width: Swift.max(2, g.size.width * CGFloat(sec) / CGFloat(measuredSeconds) - 2))
                            }
                        }
                    }
                }
                .frame(height: 10)
                .clipShape(Capsule())
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                ForEach(bands, id: \.self) { b in
                    legend(b.color, b.title.capitalized, b.range, s.seconds[b] ?? 0)
                }
                legend(StrandPalette.textTertiary.opacity(0.5), String(localized: "Active"), nil, s.activeSeconds)
                legend(StrandPalette.surfaceInset, String(localized: "No reading"), nil, s.unmeasuredSeconds)
            }
        }
    }

    private func stat(_ label: String, _ value: String, _ color: Color?, sub: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            Text(value).font(StrandFont.number(22)).foregroundStyle(color ?? StrandPalette.textPrimary)
            if let sub { Text(sub).font(.system(size: 10)).foregroundStyle(StrandPalette.textTertiary) }
        }
    }

    private func legend(_ color: Color, _ title: String, _ range: String?, _ seconds: Int) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(title).font(StrandFont.caption.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
            if let range { Text(range).font(.system(size: 10)).foregroundStyle(StrandPalette.textTertiary) }
            Spacer(minLength: 2)
            Text(stressDuration(seconds)).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
        }
    }
}

/// The last seven days' average stress level, one bar each, coloured by band. Tap a day to show it above.
struct StressWeekBars: View {
    /// Oldest first, ending today.
    let days: [StressLevelDay]
    @Binding var selected: String

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(days, id: \.day) { d in
                let avg = d.summary.average
                let on = d.day == selected
                Button { selected = d.day } label: {
                    VStack(spacing: 4) {
                        Text(avg.map(String.init) ?? "–")
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(on ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(avg.map { StressLevel.Band(level: $0).color } ?? StrandPalette.surfaceInset)
                            .opacity(on ? 1 : 0.7)
                            .frame(height: Swift.max(4, CGFloat(avg ?? 0) / 100 * 70))
                        Text(Self.weekday(d.day))
                            .font(.system(size: 10, weight: on ? .bold : .regular))
                            .foregroundStyle(on ? StrandPalette.accent : StrandPalette.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 110, alignment: .bottom)
    }

    static func weekday(_ key: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: key) else { return key }
        return d.formatted(.dateTime.weekday(.narrow))
    }
}

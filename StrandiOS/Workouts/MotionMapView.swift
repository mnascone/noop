import SwiftUI
import StrandDesign
import StrandAnalytics

/// The wrist's motion along the set's main line, as the rep counter sees it: the filtered signal over the
/// last 30 seconds, a filled dot on each swing it counted as a rep, and a grey cross on each it left out.
struct MotionMapView: View {
    let analysis: RepCounter.Analysis
    @State private var showRules = false

    static let windowS = 30.0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Motion").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                Text(summary)
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer()
                Button { showRules = true } label: {
                    Image(systemName: "info.circle").font(StrandFont.footnote).foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("What counts as a rep")
            }
            Canvas { ctx, size in draw(ctx, size) }
                .frame(height: 64)
                .background(RoundedRectangle(cornerRadius: 8).fill(StrandPalette.surfaceInset.opacity(0.6)))
                .accessibilityLabel(Text("\(analysis.counted.count) reps counted, \(analysis.rejected.count) swings left out"))
            HStack(spacing: 10) {
                legend(Circle().fill(StrandPalette.statusPositive).frame(width: 7, height: 7), "Rep")
                legend(Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(StrandPalette.textTertiary), "Left out")
                Spacer()
            }
        }
        .sheet(isPresented: $showRules) { RepRulesSheet() }
    }

    private var summary: String {
        var parts: [String] = []
        switch analysis.movement {
        case .vertical: parts.append(String(localized: "up and down"))
        case .horizontal: parts.append(String(localized: "across"))
        case .unknown: break
        }
        parts.append(String(localized: "\(analysis.counted.count) reps"))
        if let t = analysis.tempoS { parts.append(String(format: String(localized: "%.1f s each"), t)) }
        return parts.joined(separator: " · ")
    }

    private func legend<V: View>(_ mark: V, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            mark
            Text(label).font(.system(size: 10)).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let trace = analysis.trace
        guard trace.count >= 2 else { return }
        let rate = RepCounter.rateHz
        let end = analysis.t0 + Double(trace.count - 1) / rate
        let start = max(analysis.t0, end - Self.windowS)
        let from = max(0, Int(((start - analysis.t0) * rate).rounded()))
        let slice = Array(trace[from...])
        let peak = max(0.05, slice.map(abs).max() ?? 0.05)
        let midY = size.height / 2
        func x(_ t: Double) -> CGFloat { CGFloat((t - start) / max(1, end - start)) * size.width }
        func y(_ v: Double) -> CGFloat { midY - CGFloat(v / peak) * (size.height / 2 - 6) }
        func value(at t: Double) -> Double {
            let i = Int(((t - analysis.t0) * rate).rounded())
            return trace[min(trace.count - 1, max(0, i))]
        }

        var mid = Path()
        mid.move(to: CGPoint(x: 0, y: midY))
        mid.addLine(to: CGPoint(x: size.width, y: midY))
        ctx.stroke(mid, with: .color(StrandPalette.hairline), lineWidth: 1)

        // Thin the line to about two points per pixel.
        let step = max(1, slice.count / max(1, Int(size.width * 2)))
        var line = Path()
        for (k, i) in stride(from: 0, to: slice.count, by: step).enumerated() {
            let t = start + Double(i) / rate
            let p = CGPoint(x: x(t), y: y(slice[i]))
            if k == 0 { line.move(to: p) } else { line.addLine(to: p) }
        }
        ctx.stroke(line, with: .color(StrandPalette.accent.opacity(0.8)), lineWidth: 1.5)

        for t in analysis.rejected where t >= start {
            let c = CGPoint(x: x(t), y: y(value(at: t)))
            var cross = Path()
            cross.move(to: CGPoint(x: c.x - 3, y: c.y - 3)); cross.addLine(to: CGPoint(x: c.x + 3, y: c.y + 3))
            cross.move(to: CGPoint(x: c.x - 3, y: c.y + 3)); cross.addLine(to: CGPoint(x: c.x + 3, y: c.y - 3))
            ctx.stroke(cross, with: .color(StrandPalette.textTertiary), lineWidth: 1.5)
        }
        for t in analysis.counted where t >= start {
            let c = CGPoint(x: x(t), y: y(value(at: t)))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)),
                     with: .color(StrandPalette.statusPositive))
        }
    }
}

/// What the rep counter counts, and what it leaves out.
struct RepRulesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("One full out-and-back movement of your wrist along the set's main line: out past the middle, then back past the other side. Each one takes between 0.8 and 8 seconds, is at least 40% of the set's usual size, and keeps pace with the reps around it. You need 3 or more in a row, and your heart rate has to rise with the set (6 bpm or more) for it to count.")
                } header: { Text("A rep is") }
                Section {
                    Label("Presses: bench, overhead, push-ups, dips", systemImage: "checkmark.circle")
                    Label("Curls and raises", systemImage: "checkmark.circle")
                    Label("Rows, pull-ups and pulldowns", systemImage: "checkmark.circle")
                    Label("Squats, lunges and deadlifts holding the weight", systemImage: "checkmark.circle")
                } header: { Text("Counts (your wrist moves with the weight)") }
                Section {
                    Label("Walking between stations: steps are too quick and don't move along one line", systemImage: "xmark.circle")
                    Label("Racking, unracking, loading plates, adjusting a seat: single swings out of step", systemImage: "xmark.circle")
                    Label("Small fidgets: under 40% of a rep's size", systemImage: "xmark.circle")
                    Label("Holds and carries: no out-and-back movement", systemImage: "xmark.circle")
                    Label("Leg press, leg extension, leg curl, calf raises: your hands stay still", systemImage: "xmark.circle")
                } header: { Text("Doesn't count") }
                Section {
                    Text("The motion map shows what the counter saw over the last 30 seconds. Green dots are counted reps, grey crosses are swings it left out. \"Up and down\" means the movement ran within about 45 degrees of vertical, like a press or squat. \"Across\" means rows, flyes or cable work.")
                } header: { Text("Reading the map") }
            }
            .navigationTitle("What counts as a rep")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

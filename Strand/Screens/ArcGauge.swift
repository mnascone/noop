import SwiftUI
import StrandDesign

/// A 240-degree open ring in the style of the Today hero rings: a faint full track, one flat solid arc
/// with round caps, and whatever the caller puts in the centre. The gap sits at the bottom.
///
/// `from` and `to` are 0...1 along the ring, left end to right end. A plain fill is `from: 0`; a
/// two-sided reading such as pace fills out from the middle (`from: 0.5`) in either direction.
struct ArcGauge<Center: View>: View {
    var from: Double = 0
    var to: Double
    var color: Color
    var diameter: CGFloat = 84
    var lineWidth: CGFloat = 8
    /// A small mark across the track at this point, such as "on pace" at the top.
    var tick: Double? = nil
    @ViewBuilder var center: () -> Center

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The ring covers two thirds of the circle, starting at the lower left.
    private static var span: CGFloat { 2.0 / 3.0 }
    private static var startAngle: Angle { .degrees(150) }

    private var lo: CGFloat { CGFloat(min(max(Swift.min(from, to), 0), 1)) * Self.span }
    private var hi: CGFloat { CGFloat(min(max(Swift.max(from, to), 0), 1)) * Self.span }

    var body: some View {
        ZStack {
            Circle()
                .inset(by: lineWidth / 2)
                .trim(from: 0, to: Self.span)
                .stroke(StrandPalette.textPrimary.opacity(0.10),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(Self.startAngle)
            Circle()
                .inset(by: lineWidth / 2)
                .trim(from: lo, to: Swift.max(hi, lo + 0.004))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(Self.startAngle)
                .animation(reduceMotion ? nil : .spring(response: 0.8, dampingFraction: 0.85), value: hi)
                .animation(reduceMotion ? nil : .spring(response: 0.8, dampingFraction: 0.85), value: lo)
            if let tick {
                tickMark(tick)
            }
            center()
                .padding(.horizontal, lineWidth + 4)
        }
        .frame(width: diameter, height: diameter)
    }

    /// A short line across the track, so the reference point is visible whatever the fill.
    private func tickMark(_ t: Double) -> some View {
        let degrees = 150.0 + 240.0 * min(max(t, 0), 1)
        let c = diameter / 2
        let r = diameter / 2 - lineWidth / 2
        let radians = degrees * Double.pi / 180
        let x: CGFloat = c + CGFloat(cos(radians)) * r
        let y: CGFloat = c + CGFloat(sin(radians)) * r
        return Capsule()
            .fill(StrandPalette.textPrimary.opacity(0.35))
            .frame(width: 2, height: lineWidth + 4)
            .rotationEffect(.degrees(degrees + 90))
            .position(x: x, y: y)
    }
}

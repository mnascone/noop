import SwiftUI
import StrandDesign

/// The Performance tab: Trends and the AI Coach behind one switch at the top. Coach only appears when its
/// master switch is on; otherwise this is just Trends.
struct PerformanceView: View {
    static let segmentKey = "noop.performanceSegment"

    enum Segment: String, CaseIterable, Identifiable {
        case trends, coach
        var id: String { rawValue }
        var title: LocalizedStringKey { self == .trends ? "Trends" : "Coach" }
    }

    @AppStorage(segmentKey) private var segmentRaw = Segment.trends.rawValue
    @AppStorage("noop.coachEnabled") private var coachEnabled = true
    /// Coach is built the first time it's opened, then kept, so switching back and forth is instant and the
    /// chat keeps its place.
    @State private var coachOpened = false

    private var segment: Segment {
        coachEnabled ? (Segment(rawValue: segmentRaw) ?? .trends) : .trends
    }

    var body: some View {
        VStack(spacing: 0) {
            if coachEnabled {
                Picker("Show", selection: $segmentRaw) {
                    ForEach(Segment.allCases) { s in
                        Text(s.title).tag(s.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, NoopMetrics.space4)
                .padding(.top, NoopMetrics.space2)
                .padding(.bottom, NoopMetrics.space1)
            }
            ZStack {
                TrendsView()
                    .opacity(segment == .trends ? 1 : 0)
                    .allowsHitTesting(segment == .trends)
                    .accessibilityHidden(segment != .trends)
                if coachEnabled && (coachOpened || segment == .coach) {
                    CoachView()
                        .opacity(segment == .coach ? 1 : 0)
                        .allowsHitTesting(segment == .coach)
                        .accessibilityHidden(segment != .coach)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: segment)
        .onChange(of: segmentRaw) { _, raw in
            if raw == Segment.coach.rawValue { coachOpened = true }
        }
        .onAppear { if segment == .coach { coachOpened = true } }
    }
}

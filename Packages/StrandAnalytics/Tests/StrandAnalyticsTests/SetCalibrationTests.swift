import XCTest
@testable import StrandAnalytics

final class SetCalibrationTests: XCTestCase {
    typealias C = SetCalibration

    func testErrorsPairSetsByOverlap() {
        let truth = [C.Span(start: 0, end: 40), C.Span(start: 100, end: 140)]
        XCTAssertEqual(C.errors(truth, truth).count, 0)
        XCTAssertEqual(C.errors([C.Span(start: 0, end: 140)], truth).count, 1, "two sets read as one")
        XCTAssertEqual(C.errors(truth + [C.Span(start: 200, end: 230)], truth).count, 1, "one extra")
    }

    // MARK: Editing helpers

    /// Heart rate as a function of time, one sample a second.
    private func hr(_ from: Int, _ to: Int, _ f: (Int) -> Int) -> [C.HRSampleTS] {
        (from..<to).map { C.HRSampleTS(ts: $0, bpm: f($0)) }
    }

    /// "+" mid-workout: the set runs from where heart rate left its low to now, not a fixed 45 s.
    func testSetEndingNowFollowsTheRise() {
        // Resting at 95 until 1300, then climbing to 128 by 1360 (now).
        let h = hr(1000, 1361) { t in t < 1300 ? 95 : 95 + (t - 1300) * 33 / 60 }
        let s = C.setEndingNow(hr: h, after: 1000, now: 1360, typicalWork: 40)!
        XCTAssertEqual(Double(s.start), 1300, accuracy: 4)
        XCTAssertEqual(s.end, 1360)
        // Flat heart rate: as long as your typical set.
        let flat = hr(1000, 1361) { _ in 95 }
        XCTAssertEqual(C.setEndingNow(hr: flat, after: 1000, now: 1360, typicalWork: 40), C.Span(start: 1320, end: 1360))
    }

    /// Suggestions come from heart rate against your tuning: a "set" heart rate didn't rise for, and a
    /// break it didn't come down in.
    func testSuggestionsFromHeartRate() {
        let sets = [C.Span(start: 100, end: 140), C.Span(start: 165, end: 200),   // break: HR stays up
                    C.Span(start: 400, end: 440), C.Span(start: 600, end: 606),   // 606: a blip
                    C.Span(start: 800, end: 840)]
        let h = hr(0, 1000) { t in
            switch t {
            case 100...220: return 128
            case 400...460, 800...860: return 128
            default: return 95
            }
        }
        let sug = C.suggestions(sets, hr: h, tuning: StrengthTuning())
        XCTAssertTrue(sug.contains { if case .join(index: 0, _, _) = $0 { return true }; return false })
        XCTAssertTrue(sug.contains { if case .delete(index: 3, _, _) = $0 { return true }; return false })
        XCTAssertFalse(sug.contains { if case .delete(index: 2, _, _) = $0 { return true }; return false })
        XCTAssertFalse(sug.contains { if case .join(index: 1, _, _) = $0 { return true }; return false })
    }

    /// A dragged start lands where heart rate leaves its low; an end on its high.
    func testSnapToHeartRate() {
        let h = hr(0, 200) { t in t < 100 ? 95 : (t < 140 ? 95 + (t - 100) : 135 - (t - 140) / 2) }
        XCTAssertEqual(Double(C.snap(106, isStart: true, hr: h)), 99, accuracy: 3)
        XCTAssertEqual(Double(C.snap(133, isStart: false, hr: h)), 140, accuracy: 3)
    }
}

import XCTest
@testable import StrandAnalytics

final class SleepArchitectureTests: XCTestCase {
    typealias S = SleepArchitecture.Segment

    /// Builds a night from (stage, minutes) runs starting at 0.
    private func night(_ runs: [(SleepArchitecture.Stage, Double)]) -> [S] {
        var t = 0.0
        return runs.map { stage, m in
            defer { t += m * 60 }
            return S(stage: stage, start: t, end: t + m * 60)
        }
    }

    /// Five textbook cycles, REM lengthening toward morning.
    func testTypicalNightCountsFiveCyclesAndBuildingRem() throws {
        let segs = night([
            (.wake, 10),
            (.light, 20), (.deep, 50), (.light, 10), (.rem, 8),
            (.light, 30), (.deep, 30), (.light, 15), (.rem, 15),
            (.light, 45), (.deep, 10), (.light, 10), (.rem, 22),
            (.light, 55), (.rem, 28),
            (.light, 50), (.rem, 32),
            (.wake, 10),
        ])
        let r = try XCTUnwrap(SleepArchitecture.analyze(segs))
        XCTAssertEqual(r.cycles, 5)
        XCTAssertEqual(r.remEpisodes.count, 5)
        XCTAssertEqual(r.remLatencyMinutes ?? 0, 80, accuracy: 0.01)
        XCTAssertEqual(r.longestRemMinutes ?? 0, 32, accuracy: 0.01)
        XCTAssertGreaterThan(r.remSecondHalfShare ?? 0, 0.6)
        XCTAssertGreaterThan(r.deepFirstThirdShare ?? 0, 0.6)
        XCTAssertEqual(r.patterns, [.typical])
        XCTAssertEqual(r.awakenings, 0)
    }

    /// REM split by a 2-minute light blip is one episode; a 1-minute REM sliver is not an episode.
    func testShortGapsMergeAndSliversDrop() throws {
        let segs = night([
            (.light, 30), (.deep, 40), (.light, 20),
            (.rem, 6), (.light, 2), (.rem, 6),
            (.light, 60), (.rem, 1),
            (.light, 40), (.rem, 20),
        ])
        let r = try XCTUnwrap(SleepArchitecture.analyze(segs))
        XCTAssertEqual(r.remEpisodes.count, 2)
        XCTAssertEqual(r.remEpisodes[0].minutes, 14, accuracy: 0.01)
        XCTAssertEqual(r.cycles, 2)
    }

    func testLateRemAndAwakenings() throws {
        let segs = night([
            (.light, 60), (.deep, 50), (.wake, 5), (.light, 30), (.rem, 10),
            (.light, 60), (.wake, 3), (.light, 20), (.rem, 20),
            (.light, 40), (.rem, 25),
        ])
        let r = try XCTUnwrap(SleepArchitecture.analyze(segs))
        XCTAssertTrue(r.patterns.contains(.lateRem))
        XCTAssertEqual(r.awakenings, 2)
        XCTAssertEqual(r.wasoMinutes, 8, accuracy: 0.01)
        // Longest unbroken stretch: from falling asleep to the first wake.
        XCTAssertEqual(r.longestStretchMinutes, 110, accuracy: 0.01)
    }

    func testTooShortReturnsNil() {
        XCTAssertNil(SleepArchitecture.analyze(night([(.light, 30), (.rem, 10)])))
    }
}
